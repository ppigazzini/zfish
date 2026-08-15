// Replace the bash golden-diff scripts (output_parity_golden.sh / search_parity.sh /
// search_modes.sh / perft.sh / eval.sh / misc.sh) with this pure-Zig cross-platform
// harness. Drive the built stockfish binary over UCI, extract the same deterministic
// fingerprints those scripts did, and diff them against the same committed .golden files
// -- but with zero shell/coreutils dependency, so `zig build parity` runs identically on
// Linux, Windows, and macOS (the bash scripts relied on POSIX sh, GNU vs BSD
// sed/grep/sort, and process substitution, none of which hold across the three).
//
// Contract (matches the bash scripts, invoked by build.zig):
//   parity_harness <check> <stockfish-bin> <golden-path> [check|update]   (cwd = resources/)
//     check  (default): rebuild the live fingerprint, diff vs the golden, exit 1 on drift.
//     update:           (re)write the golden from the live run.
//   parity_harness signature <stockfish-bin> <expected-nodes>
//     run bench and assert `Nodes searched` == expected (the arch/OS invariant).
// Mirror the scripts' exit codes: 0 pass, 1 golden mismatch, 2 crash / parse failure / usage.
//
// Route the streams (empirically verified against upstream, identical on every OS because
// the engine's print paths are the same): the `uci` handshake, the `eval` NNUE trace, and
// the interactive `d`/`go perft`/`go`/bestmove lines go to STDOUT; only the bench
// `Position:`/`Nodes searched` banners go to STDERR -- upstream puts bench there too, so
// that one is faithful, not a bug. Capture both streams separately in each check and read
// the one(s) it needs, so no fragile stderr->stdout merge (bash `2>&1`) is reconstructed.
// Where a check reads a stream, it should PIN it: the handshake gate asserts stdout AND
// asserts stderr is clean, because reading the wrong stream is exactly how a real defect
// (the whole handshake on stderr) passed every gate here for months.
//
// This file is the DISPATCHER: it owns the check name -> builder mapping, the golden
// read/write/compare, and the one gate that must run from a cwd the build does not pin.
// Every builder and every interactive gate lives in tools/parity/ -- see parity/main.zig.

const std = @import("std");
const Io = std.Io;
const parity = @import("parity/main.zig");

const run = parity.run;
const stripCR = run.stripCR;
const fail = run.fail;
const printDiff = parity.structured_diff.printDiff;

const Check = enum { @"output-golden", @"driver-golden", @"search-parity", @"search-modes", @"fen-errors", perft, eval, misc, @"export-net", nodestime, @"uci-options", mate, chess960, @"bench-matrix", @"tb-init", @"tb-wdl", @"tb-dtz", @"tb-root", @"tb-search", @"tb-cursed" };

// net-missing: exercise the ONLY gate that runs the installed binary from a cwd the build
// does not pin. Every other gate sets cwd to resources/ (build.zig `run.setCwd(b.path("resources"))`),
// which supplies the very precondition the binary must check -- so none of them can
// see a startup that fails without the net.
//
// Treat the net as a runtime input (NNUE_EMBEDDING_OFF): `network.load` searches the cwd and
// the binary directory and returns void on a miss. Unchecked, worker construction
// `orelse return`s on the null feature-transformer pointer, leaves the Worker zeroed,
// and the clear job null-unwraps on a worker thread -- a SIGSEGV naming nothing.
// Assert here a NAMED diagnostic and a clean non-zero exit, never a signal.
fn runNetMissing(gpa: std.mem.Allocator, io: Io, bin_arg: []const u8) noreturn {
    // Absolutize the binary path before spawning -- this gate sets cwd to a scratch dir
    // (every other gate keeps cwd = resources/), so a path relative to the harness's own cwd
    // would not resolve from there. Resolve a possibly-relative incoming arg against the
    // harness cwd.
    const bin: []const u8 = if (std.fs.path.isAbsolute(bin_arg))
        bin_arg
    else abs: {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        var threaded = std.Io.Threaded.init_single_threaded;
        const n = std.process.currentPath(threaded.io(), &cwd_buf) catch
            fail("net-missing: cannot resolve cwd to absolutize the binary path", .{});
        break :abs std.fs.path.resolve(gpa, &.{ cwd_buf[0..n], bin_arg }) catch
            fail("net-missing: cannot resolve the binary path", .{});
    };

    // Make a scratch cwd with no net in it. Deliberately not under resources/.
    const dir_path = "net_missing_tmp";
    Io.Dir.cwd().createDirPath(io, dir_path) catch
        fail("net-missing: cannot create scratch dir {s}", .{dir_path});
    defer Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    var child = std.process.spawn(io, .{
        .argv = &.{ bin, "bench" },
        .cwd = .{ .path = dir_path },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch fail("net-missing: spawn failed", .{});
    defer child.kill(io);

    var mr_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => fail("net-missing: read failed", .{}),
    }
    const term = child.wait(io) catch fail("net-missing: wait failed", .{});

    const out = mr.toOwnedSlice(0) catch fail("net-missing: stdout capture failed", .{});
    defer gpa.free(out);
    const err_out = mr.toOwnedSlice(1) catch fail("net-missing: stderr capture failed", .{});
    defer gpa.free(err_out);

    // 1. Assert a clean exit, not a signal. Recall the shipped regression: SIGSEGV (139).
    switch (term) {
        .exited => |code| if (code == 0)
            fail("net-missing: engine exited 0 without a net; it must fail", .{}),
        .signal => |sig| fail(
            "net-missing: engine died on signal {d} (a crash, not a diagnostic) -- " ++
                "this is the defect the gate exists to catch",
            .{@intFromEnum(sig)},
        ),
        else => fail("net-missing: engine terminated abnormally: {any}", .{term}),
    }

    // 2. Require the diagnostic to name the file sought. A non-zero exit that explains nothing
    //    is not the contract; the whole point is that the cause is visible.
    const said = if (std.mem.find(u8, err_out, "nn-") != null) err_out else out;
    if (std.mem.find(u8, said, "nn-") == null)
        fail("net-missing: exit was clean but no diagnostic named the net file", .{});
    if (std.mem.find(u8, said, dir_path) == null)
        fail("net-missing: diagnostic does not name the directory searched", .{});

    std.debug.print("net-missing: OK (no net in cwd -> named diagnostic + clean exit, no signal)\n", .{});
    std.process.exit(0);
}

// EXIT 1 MEANS "THE GOLDEN MOVED", AND NOTHING ELSE. A `!void` main hands an error to Zig's
// default handler, which prints `error: FileNotFound` and exits 1 -- the same status a real
// drift produces, from a harness that never reached the comparison. Catch here instead and
// route every failure through `fail`, which is exit 2: a caller can then tell "the engine's
// output changed" from "the harness could not run the engine at all", which is the whole
// point of having two statuses.
pub fn main(init: std.process.Init) void {
    fallibleMain(init) catch |err| fail(
        "parity_harness: {s} before any comparison -- a harness failure, not a golden mismatch",
        .{@errorName(err)},
    );
}

fn fallibleMain(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    while (arg_it.next()) |a| try args.append(gpa, a);

    if (args.items.len < 4) fail("usage: parity_harness <check> <stockfish-bin> <golden|expected> [check|update]", .{});
    const check_name = args.items[1];
    const bin = args.items[2];
    const golden = args.items[3];
    const mode = if (args.items.len >= 5) args.items[4] else "check";

    // Refuse BEFORE dispatching, so this covers every writer -- the golden-gate table below
    // and mt-sanity's own update arm, which writes through a different path. Refusing here
    // also refuses before the engine runs: there is nothing to learn from a capture that is
    // not going to be written.
    if (std.mem.eql(u8, mode, "update"))
        run.refuseSelfMadeGolden(gpa, init.minimal.environ, check_name, golden);

    if (std.mem.eql(u8, check_name, "signature")) parity.gate_runtime.runSignature(gpa, io, bin, golden);
    if (std.mem.eql(u8, check_name, "mt-sanity")) parity.gate_runtime.runMtSanity(gpa, io, bin, golden, mode);
    if (std.mem.eql(u8, check_name, "stress")) parity.gate_runtime.runStress(gpa, io, bin);
    if (std.mem.eql(u8, check_name, "time-mgmt")) parity.gate_runtime.runTimeMgmt(gpa, io, bin);
    if (std.mem.eql(u8, check_name, "reset-determinism")) parity.gate_state.runResetDeterminism(gpa, io, bin);
    if (std.mem.eql(u8, check_name, "skill")) parity.gate_state.runSkill(gpa, io, bin);
    if (std.mem.eql(u8, check_name, "fen-truncated")) parity.gate_state.runFenTruncated(gpa, io, bin);
    if (std.mem.eql(u8, check_name, "flip-chess960")) parity.gate_state.runFlipChess960(gpa, io, bin);
    if (std.mem.eql(u8, check_name, "repeat-go")) parity.gate_state.runRepeatGo(gpa, io, bin);
    if (std.mem.eql(u8, check_name, "ponder")) parity.gate_state.runPonder(gpa, io, bin);
    if (std.mem.eql(u8, check_name, "async")) parity.gate_runtime.runAsync(gpa, io, bin);
    if (std.mem.eql(u8, check_name, "malformed")) parity.gate_malformed.runMalformed(gpa, io, bin);
    if (std.mem.eql(u8, check_name, "net-missing")) runNetMissing(gpa, io, bin);

    const check = std.meta.stringToEnum(Check, check_name) orelse
        fail("parity_harness: unknown check '{s}'", .{check_name});

    const live = switch (check) {
        .@"output-golden" => try parity.golden_shell.buildOutputGolden(gpa, io, bin),
        .@"driver-golden" => try parity.golden_shell.buildDriverGolden(gpa, io, bin),
        .@"search-parity" => try parity.golden_search.buildSearchParity(gpa, io, bin),
        .@"search-modes" => try parity.golden_shell.buildSearchModes(gpa, io, bin),
        .@"fen-errors" => try parity.golden_shell.buildFenErrors(gpa, io, bin),
        .perft => try parity.golden_search.buildPerft(gpa, io, bin),
        .eval => try parity.golden_search.buildEval(gpa, io, bin),
        .misc => try parity.golden_shell.buildMisc(gpa, io, bin),
        .@"export-net" => try parity.golden_shell.buildExportNet(gpa, io, bin),
        .nodestime => try parity.golden_search.buildNodestime(gpa, io, bin),
        .@"uci-options" => try parity.golden_shell.buildUciOptions(gpa, io, bin),
        .mate => try parity.golden_search.buildMate(gpa, io, bin),
        .chess960 => try parity.golden_search.buildChess960(gpa, io, bin),
        .@"bench-matrix" => try parity.golden_search.buildBenchMatrix(gpa, io, bin),
        .@"tb-init" => try parity.golden_tb.buildTbInit(gpa, io, bin),
        .@"tb-wdl" => try parity.golden_tb.buildTbWdl(gpa, io, bin),
        .@"tb-dtz" => try parity.golden_tb.buildTbDtz(gpa, io, bin),
        .@"tb-root" => try parity.golden_tb.buildTbRoot(gpa, io, bin),
        .@"tb-search" => try parity.golden_tb.buildTbSearch(gpa, io, bin),
        .@"tb-cursed" => try parity.golden_tb.buildTbCursed(gpa, io, bin),
    };
    defer gpa.free(live);

    if (std.mem.eql(u8, mode, "update")) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = golden, .data = live });
        std.debug.print("{s}: wrote golden ({d} bytes)\n", .{ check_name, live.len });
        return;
    }

    const raw_golden = Io.Dir.cwd().readFileAlloc(io, golden, gpa, .unlimited) catch
        fail("{s}: golden missing or unreadable: {s} (run the update step first)", .{ check_name, golden });
    defer gpa.free(raw_golden);
    // Normalize the golden's line endings: git may check the committed LF golden out as
    // CRLF on Windows (core.autocrlf), and the live capture is already CR-stripped, so
    // compare CR-free on both sides. (A .gitattributes also pins the goldens to LF.)
    const golden_bytes = try stripCR(gpa, raw_golden);
    defer gpa.free(golden_bytes);

    if (std.mem.eql(u8, golden_bytes, live)) {
        std.debug.print("{s}: OK (matches golden)\n", .{check_name});
        return;
    }

    std.debug.print("{s}: MISMATCH vs golden (< golden, > live):\n", .{check_name});
    printDiff(golden_bytes, live);
    std.process.exit(1);
}
