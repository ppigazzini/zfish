//! Decide whether a tablebase gate can run: its tables are present, or they are absent and the
//! gate says why.
//!
//! The tables are a download, not part of the tree, and the mirror they come from is not this
//! project's to be held hostage by. So under ZFISH_TB_BEST_EFFORT -- which CI sets, beside a fetch
//! step that may fail without failing the lane -- a gate whose set is absent SKIPS, loudly and
//! with exit 0: it has narrowed to nothing, and it says so rather than claiming a pass. Without
//! the variable an absent set is a refusal, which is what a developer at the keyboard needs: a
//! gate that quietly skips on a machine that merely never fetched has retired its question.
//!
//! The file lists are tools/fetch_tb.zig's, the one owner of what each set is.

const std = @import("std");
const Io = std.Io;
const fetch_tb = @import("../fetch_tb.zig");
const run = @import("run.zig");

const fail = run.fail;

/// Name the checks that read a set: the 3-man one, and tb-cursed, which reads the 5-man set on
/// top of it (its SyzygyPath is `syzygy5:syzygy`).
fn needs(check: []const u8) struct { three: bool, five: bool } {
    const three_man_checks = [_][]const u8{ "tb-init", "tb-wdl", "tb-dtz", "tb-root", "tb-search", "tb-cursed" };
    var three = false;
    for (three_man_checks) |c| three = three or std.mem.eql(u8, c, check);
    return .{ .three = three, .five = std.mem.eql(u8, check, "tb-cursed") };
}

/// Return the first file of `names` absent from `dir`, as a path relative to the cwd.
fn firstMissing(gpa: std.mem.Allocator, io: Io, dir: []const u8, names: []const []const u8) !?[]u8 {
    for (names) |name| {
        for (fetch_tb.kinds) |kind| {
            const path = try gpa.print("{s}/{s}{s}", .{ dir, name, kind.ext });
            if (Io.Dir.cwd().access(io, path, .{})) |_| {
                gpa.free(path);
            } else |_| return path;
        }
    }
    return null;
}

/// Return when `check` reads no tables or has them all. Otherwise SKIP under best effort, and
/// refuse without it -- and always refuse in update mode, where a skip would report a golden
/// that was never written.
pub fn requireOrSkip(gpa: std.mem.Allocator, io: Io, environ: std.process.Environ, check: []const u8, mode: []const u8) void {
    const want = needs(check);
    var missing: ?[]u8 = null;
    if (want.three) missing = firstMissing(gpa, io, fetch_tb.three_man_dir, &fetch_tb.three_man) catch null;
    if (missing == null and want.five) missing = firstMissing(gpa, io, fetch_tb.five_man_dir, &fetch_tb.five_man) catch null;
    const path = missing orelse return;
    defer gpa.free(path);

    const fetch_step = if (std.mem.startsWith(u8, path, fetch_tb.five_man_dir)) "tb5" else "tb";
    const best_effort = environ.containsUnempty(gpa, fetch_tb.best_effort_env) catch false;
    if (best_effort and !std.mem.eql(u8, mode, "update")) {
        std.debug.print(
            "{s}: SKIPPED -- {s} is absent and {s} is set: the tablebase download failed, so this gate narrows to nothing rather than failing (NOT a pass)\n",
            .{ check, path, fetch_tb.best_effort_env },
        );
        std.process.exit(0);
    }
    fail("{s}: {s} is absent -- fetch the set with `zig build {s}` first", .{ check, path, fetch_step });
}
