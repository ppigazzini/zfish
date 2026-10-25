// Fetch the Syzygy tablebases the gates read, in pure Zig (mirrors fetch_net.zig) -- no sh/curl.
//
// Two sets, WDL (.rtbw) + DTZ (.rtbz) each, from lichess's mirror of the standard tables, into
// directories under the cwd (build.zig runs this with cwd = resources/):
//   * no argument -- the 3-man set into syzygy/, ~26 KB. tb-init, tb-wdl, tb-dtz, tb-root,
//     tb-search and parity-malformed read it.
//   * `5` -- the 5-man cursed-win set into syzygy5/, ~24 MB: the tables tb-cursed's golden was
//     derived under, and ONLY those. A probe reads every table on its SyzygyPath, so a golden
//     pinned at one set is a different probe stream at another; add a table here and the golden
//     has to be re-derived from the oracle with it in place.
// Never commit the tables (see .gitignore); fetch and cache them like the NNUE net. Verify each
// file's Syzygy magic so a mirror error page can't masquerade as a table, and skip files already
// present.
//
// BEST EFFORT when ZFISH_TB_BEST_EFFORT is set, as CI sets it. A tablebase mirror is not this
// project's dependency to be held hostage by: a file that cannot be fetched is reported and
// skipped, the run exits 0, and the gates that read the set then SKIP, loudly, rather than fail
// (tools/parity/tb_tables.zig). Without it a failure exits 1, which is what a developer at the
// keyboard wants to see.

const std = @import("std");
const Io = std.Io;

/// Name the 3-man set, fetched into `three_man_dir`.
pub const three_man = [_][]const u8{ "KPvK", "KNvK", "KBvK", "KRvK", "KQvK" };
pub const three_man_dir = "syzygy";

/// Name the 5-man set tb-cursed reads, fetched into `five_man_dir` -- ../mcfish's `tb-fetch 5`,
/// ~24 MB. KNNvKP is the cursed win itself; KNNvK and KNvKP are the two children its DTZ walk
/// recurses into, by capturing the pawn or a knight. KNNvKP alone is NOT enough: without the
/// child a cursed win probes as a plain draw rather than as an error, so a missing table looks
/// like a correct answer.
pub const five_man = [_][]const u8{ "KNNvKP", "KNNvK", "KNvKP" };
pub const five_man_dir = "syzygy5";

/// Name the variable that turns a failed download into a skipped file.
pub const best_effort_env = "ZFISH_TB_BEST_EFFORT";

/// Pair each file kind with its extension, its mirror directory and its Syzygy magic (SF `Magics`).
pub const Kind = struct { ext: []const u8, dir: []const u8, magic: [4]u8 };
pub const kinds = [_]Kind{
    .{ .ext = ".rtbw", .dir = "3-4-5-wdl", .magic = .{ 0x71, 0xE8, 0x23, 0x5D } },
    .{ .ext = ".rtbz", .dir = "3-4-5-dtz", .magic = .{ 0xD7, 0x66, 0x0C, 0xA5 } },
};

const base = "https://tablebase.lichess.ovh/tables/standard";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next(); // argv0
    const five = if (arg_it.next()) |a| std.mem.eql(u8, a, "5") else false;
    const names: []const []const u8 = if (five) &five_man else &three_man;
    const dir_name = if (five) five_man_dir else three_man_dir;
    const label = if (five) "5-man cursed-win" else "3-man";
    const best_effort = init.minimal.environ.containsUnempty(gpa, best_effort_env) catch false;

    // Ensure the directory exists (Io.Dir has no makeDir; libc mkdir, ignore EEXIST).
    _ = std.c.mkdir(if (five) five_man_dir else three_man_dir, 0o755);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var fetched: usize = 0;
    var failed: usize = 0;
    for (names) |name| {
        for (kinds) |kind| {
            const dst = try gpa.print("{s}/{s}{s}", .{ dir_name, name, kind.ext });
            defer gpa.free(dst);

            if (Io.Dir.cwd().access(io, dst, .{})) |_| {
                continue; // already present
            } else |_| {}

            const url = try gpa.print("{s}/{s}/{s}{s}", .{ base, kind.dir, name, kind.ext });
            defer gpa.free(url);
            if (fetchOne(gpa, io, &client, url, dst, kind.magic)) |_| {
                fetched += 1;
            } else |_| {
                if (!best_effort) std.process.exit(1);
                failed += 1;
            }
        }
    }
    if (failed != 0) {
        std.debug.print(
            "fetch_tb: BEST EFFORT -- {d} {s} file(s) not fetched ({s} is set); the gates that read {s}/ SKIP\n",
            .{ failed, label, best_effort_env, dir_name },
        );
        return;
    }
    std.debug.print("fetch_tb: {s} set ready in {s}/ ({d} downloaded, {d} total)\n", .{ label, dir_name, fetched, names.len * kinds.len });
}

/// Download one file and write it only once it is whole and carries its magic, so a failure never
/// leaves a partial file that the next run would take for a table. Report why on failure.
fn fetchOne(gpa: std.mem.Allocator, io: Io, client: *std.http.Client, url: []const u8, dst: []const u8, magic: [4]u8) error{Failed}!void {
    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const res = client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer }) catch |e| {
        std.debug.print("fetch_tb: download failed {s} ({s})\n", .{ url, @errorName(e) });
        return error.Failed;
    };
    if (res.status != .ok) {
        std.debug.print("fetch_tb: download failed {s} (HTTP {d})\n", .{ url, @backingInt(res.status) });
        return error.Failed;
    }
    const bytes = body.written();
    if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], &magic)) {
        std.debug.print("fetch_tb: bad magic for {s} ({d} bytes) -- not a Syzygy file\n", .{ url, bytes.len });
        return error.Failed;
    }
    Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = bytes }) catch |e| {
        std.debug.print("fetch_tb: cannot write {s} ({s})\n", .{ dst, @errorName(e) });
        return error.Failed;
    };
}
