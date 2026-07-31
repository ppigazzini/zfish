//! Report what the coverage-guided fuzzer actually EXECUTED, and gate on it.
//!
//! WHY THIS EXISTS. `zig build fuzz --fuzz` exits 0 whether it executed five hundred million
//! inputs or three. The nightly lane read that exit code and reported success either way, so a
//! fuzz job that had silently stopped fuzzing was indistinguishable from one that found nothing
//! -- and "found nothing" is the result we actually want to publish. The sibling port hit the
//! live version of this: its search fuzzer was managing three inputs per ninety seconds while
//! its lane stayed green (mcfish 05914e99, where libFuzzer's symbolizer was eating the budget).
//! zfish's fuzzer output is three lines and none of them is a count, so the same failure here
//! would have been invisible for as long as nobody looked.
//!
//! WHAT IT READS. The Zig fuzzer memory-maps one coverage file per test artifact under
//! `<cache>/v/<coverage-id>`, headed by `std.Build.abi.fuzz.SeenPcsHeader`: three usizes,
//! `n_runs`, `unique_runs`, `pcs_len`. `n_runs` is the execution counter the fuzzer bumps per
//! input. Read it directly rather than parsing the fuzzer's stdout, which prints no total.
//!
//! WHY PER ARTIFACT, NOT A SUM. `zig build fuzz` builds several test artifacts (the board/eval/
//! search targets and the Syzygy file parse), each with its own coverage file, all sharing one
//! wall-clock budget. A total hides the case this gate is for: one artifact soaking the whole
//! budget while another never runs. So the check counts how many artifacts each cleared the
//! floor ON THEIR OWN and requires at least `expect` of them.
//!
//! Counting the ones that cleared, rather than requiring every file to clear, is what makes this
//! robust to a dirty cache: `<cache>/v` accumulates a file per artifact BUILD, so a tree that has
//! built several variants holds coverage files no current target writes to. Those sit at delta 0
//! and are reported, but they cannot fail the gate -- while a real target going idle still drops
//! the cleared count below `expect` and does.
//!
//! WHY A BASELINE. The counters are cumulative across runs. Snapshot before the run and diff
//! after, so the gate measures THIS run. A file absent from the baseline counts in full (it is
//! new), a file that vanished is ignored, and an absent baseline file means "count everything",
//! which is the right reading for a fresh CI checkout.
//!
//! Usage:
//!   fuzz_report.zig <cache-dir> report
//!   fuzz_report.zig <cache-dir> snapshot <baseline-file>
//!   fuzz_report.zig <cache-dir> check <baseline-file> <min-runs-each> <expect-artifacts>
//!
//! Exit 0 when every artifact cleared the floor, 1 when one did not, 2 on a usage or I/O error
//! -- distinct, so a broken invocation cannot read as a fuzzing verdict.

const std = @import("std");
const Io = std.Io;

/// Mirror `std.Build.abi.fuzz.SeenPcsHeader`'s leading fields. Only the first three usizes are
/// read; the seen-PC bitmap and the PC addresses follow and are not needed here.
const Header = extern struct {
    n_runs: usize,
    unique_runs: usize,
    pcs_len: usize,
};

const Entry = struct {
    id: []const u8,
    n_runs: u64,
    unique_runs: u64,
    pcs_len: u64,
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fuzz-report: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

/// Read every coverage file under `<cache_dir>/v`; ordering is not required.
fn collect(gpa: std.mem.Allocator, io: Io, cache_dir: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(gpa);

    const v_path = try std.fs.path.join(gpa, &.{ cache_dir, "v" });
    defer gpa.free(v_path);

    var dir = Io.Dir.cwd().openDir(io, v_path, .{ .iterate = true }) catch |err| switch (err) {
        // No directory at all means no fuzzer instance ever started. That is a finding, not an
        // error: return empty and let `check` decide, so the caller sees "0 artifacts" rather
        // than a usage failure.
        error.FileNotFound => return out.toOwnedSlice(gpa),
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |ent| {
        if (ent.kind != .file) continue;
        const body = dir.readFileAlloc(io, ent.path, gpa, .limited(@sizeOf(Header))) catch |err| switch (err) {
            // A coverage file is far larger than the header; a short read means this is not one.
            error.StreamTooLong => blk: {
                break :blk dir.readFileAlloc(io, ent.path, gpa, .unlimited) catch continue;
            },
            else => continue,
        };
        defer gpa.free(body);
        if (body.len < @sizeOf(Header)) continue;
        const h: *const Header = @ptrCast(@alignCast(body.ptr));
        try out.append(gpa, .{
            .id = try gpa.dupe(u8, ent.path),
            .n_runs = h.n_runs,
            .unique_runs = h.unique_runs,
            .pcs_len = h.pcs_len,
        });
    }
    return out.toOwnedSlice(gpa);
}

/// Serialize `<id> <n_runs>` per line.
fn writeSnapshot(gpa: std.mem.Allocator, io: Io, path: []const u8, entries: []const Entry) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (entries) |e| try body.print(gpa, "{s} {d}\n", .{ e.id, e.n_runs });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.items });
}

/// Look `id` up in a snapshot body; absent means the artifact is new, so its whole count is this
/// run's.
fn baselineFor(body: []const u8, id: []const u8) u64 {
    var lines = std.mem.tokenizeScalar(u8, body, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const got = parts.next() orelse continue;
        const runs = parts.next() orelse continue;
        if (std.mem.eql(u8, got, id))
            return std.fmt.parseInt(u64, runs, 10) catch 0;
    }
    return 0;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Arena the whole run: this is a short-lived reporter, and freeing the entry ids and the
    // baseline body one by one buys nothing. init.gpa is a checking allocator, so the arena
    // must still be released -- it reports a leak otherwise, which is how this got written.
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    while (arg_it.next()) |a| try argv.append(gpa, a);
    const args = argv.items;

    if (args.len < 3) fail(
        "usage: fuzz_report.zig <cache-dir> report|snapshot <file>|check <file> <min-each> <expect>",
        .{},
    );
    const cache_dir = args[1];
    const mode = args[2];

    const entries = collect(gpa, io, cache_dir) catch |err|
        fail("cannot read {s}/v: {t}", .{ cache_dir, err });

    if (std.mem.eql(u8, mode, "snapshot")) {
        if (args.len < 4) fail("snapshot needs a baseline file", .{});
        writeSnapshot(gpa, io, args[3], entries) catch |err|
            fail("cannot write {s}: {t}", .{ args[3], err });
        std.debug.print("fuzz-report: snapshot {d} artifact(s) -> {s}\n", .{ entries.len, args[3] });
        return;
    }

    const is_check = std.mem.eql(u8, mode, "check");
    if (!is_check and !std.mem.eql(u8, mode, "report")) fail("unknown mode '{s}'", .{mode});

    var baseline: []const u8 = "";
    var min_each: u64 = 0;
    var expect: usize = 0;
    if (is_check) {
        if (args.len < 6) fail("check needs <baseline-file> <min-runs-each> <expect-artifacts>", .{});
        baseline = Io.Dir.cwd().readFileAlloc(io, args[3], gpa, .unlimited) catch "";
        min_each = std.fmt.parseInt(u64, args[4], 10) catch
            fail("min-runs-each '{s}' is not a number", .{args[4]});
        expect = std.fmt.parseInt(usize, args[5], 10) catch
            fail("expect-artifacts '{s}' is not a number", .{args[5]});
    }

    var cleared: usize = 0;
    var total: u64 = 0;
    std.debug.print("fuzz-report: {d} coverage artifact(s) under {s}/v\n", .{ entries.len, cache_dir });
    for (entries) |e| {
        const before = baselineFor(baseline, e.id);
        // A counter that went backwards means the file was recreated; treat it as all-new.
        const delta = if (e.n_runs >= before) e.n_runs - before else e.n_runs;
        total += delta;
        const ok = delta >= min_each;
        if (is_check and ok) cleared += 1;
        const verdict = if (!is_check) "" else if (ok) "  OK" else "  idle this run";
        std.debug.print(
            "  {s}  runs={d:>14}  this-run={d:>14}  new-coverage={d:>7}  pcs={d:>7}{s}\n",
            .{ e.id, e.n_runs, delta, e.unique_runs, e.pcs_len, verdict },
        );
    }

    if (!is_check) return;

    if (cleared < expect) {
        std.debug.print(
            "fuzz-report: FAIL -- {d} of {d} artifact(s) executed at least {d} inputs this run, " ++
                "expected {d}. A green fuzz step that executed nothing is not a clean run, it is " ++
                "an idle one -- and a target that failed to build leaves no coverage file at all.\n",
            .{ cleared, entries.len, min_each, expect },
        );
        std.process.exit(1);
    }
    std.debug.print(
        "fuzz-report: OK -- {d} artifact(s) cleared {d} inputs each, {d} executed this run\n",
        .{ cleared, min_each, total },
    );
}
