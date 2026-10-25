//! Build the nodestime golden: wall-clock budgets converted to a NODE budget, so the
//! time-management path it pins is deterministic. Split from golden_search.zig on the
//! 500-line gate, along the one builder that drives a clock rather than a depth or a node
//! limit.

const std = @import("std");
const Io = std.Io;
const run = @import("run.zig");
const session = @import("session.zig");
const structured_diff = @import("structured_diff.zig");

const lines = run.lines;
const trimCR = run.trimCR;
const fail = run.fail;
const Interactive = session.Interactive;
const InfoLine = structured_diff.InfoLine;
const BestmoveLine = structured_diff.BestmoveLine;
const parseInfoLine = structured_diff.parseInfoLine;
const parseBestmove = structured_diff.parseBestmove;

/// nodestime: with `nodestime` set, wall-clock budgets convert to a NODE budget
/// (timeman.zig `npmsec`), so the otherwise non-deterministic time-management path becomes
/// BIT-EXACT -- the `time-mgmt` gate can only band-check the reported ms. Pin the
/// allocation arithmetic across its distinct branches (sudden-death wtime/btime, movestogo,
/// increment, and the movetime hard limit) by the deterministic depth/score/nodes/bestmove
/// the budget yields; the volatile `time`/`nps` fields are dropped. Single thread + node
/// budget -> arch/OS-invariant. Drive the engine via the Interactive read-to-bestmove
/// path since this is an async search -- a feed-all-then-quit pipe would truncate it (the
/// batch hazard the search-modes gate also avoids).
/// One nodestime row: `cmds` is the search the golden pins. `pre`, when set, is a search run
/// to its own bestmove first in the same process, for state one search leaves the next.
const NodestimeRow = struct { label: []const u8, cmds: []const u8, pre: []const u8 = "" };
pub fn buildNodestime(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    const sp = "position startpos";
    const end = "position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1";
    // Black to move, with the two clocks far apart: every row above is white to move, so
    // all of them read `wtime` and none of them can tell the side-selection apart from a
    // constant. An engine that always read wtime would pass the whole gate while playing
    // black on the wrong budget -- the deepest search here is the one with 60s on the
    // clock it must NOT be reading.
    const blk = "position fen rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1";
    const rows = [_]NodestimeRow{
        .{ .label = "sudden-death ", .cmds = sp ++ "\ngo wtime 10000 btime 10000" },
        .{ .label = "movestogo    ", .cmds = sp ++ "\ngo wtime 10000 btime 10000 movestogo 30" },
        .{ .label = "with-inc     ", .cmds = sp ++ "\ngo wtime 10000 btime 10000 winc 100 binc 100" },
        .{ .label = "endgame-sd   ", .cmds = end ++ "\ngo wtime 5000 btime 5000" },
        .{ .label = "movetime     ", .cmds = sp ++ "\ngo movetime 500" },
        .{ .label = "black-asym   ", .cmds = blk ++ "\ngo wtime 60000 btime 1000" },
        .{ .label = "white-asym   ", .cmds = sp ++ "\ngo wtime 1000 btime 60000" },
        .{ .label = "black-mtg    ", .cmds = blk ++ "\ngo wtime 60000 btime 2000 movestogo 5" },
        // movestogo 1 is the last move before the control, the branch that hands the whole
        // remaining budget to one search rather than dividing it.
        .{ .label = "movestogo-1  ", .cmds = sp ++ "\ngo wtime 10000 btime 10000 movestogo 1" },
        // A clocked search after one with no clock of its own. The node budget is initialised
        // on the first clocked search, so the depth search before it must leave it untouched:
        // advancing it from -1 to 0 made this search see an empty clock and move at depth 1.
        .{ .label = "after-depth  ", .pre = sp ++ "\ngo depth 5", .cmds = sp ++ " moves e2e4\ngo wtime 10000 btime 10000" },
        // One legal move. Its half-second cap is in milliseconds and has to be scaled into
        // nodes like the clock it caps; unscaled it capped the search at 500 nodes.
        .{ .label = "single-move  ", .cmds = "position fen 7k/8/8/8/8/r7/1N6/K7 w - - 0 1\ngo wtime 120000 btime 120000" },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (rows) |r| {
        var s: Interactive = undefined;
        try s.init(io, gpa, bin);
        s.send("setoption name Threads value 1\nsetoption name nodestime value 600\n");
        if (r.pre.len != 0) {
            s.send(r.pre);
            s.send("\n");
            if (!s.fillUntil("\nbestmove")) fail("nodestime: {s}: no bestmove from the first search", .{r.label});
        }
        s.send(r.cmds);
        s.send("\n");
        _ = s.fillUntil("\nbestmove");
        const buf = s.buffered();

        // Keep the last SCORED info line (the final iteration) + the bestmove; any
        // currmove line has no nodes/score and is skipped (the budget stays <10M anyway).
        var last_info: ?InfoLine = null;
        var best: ?BestmoveLine = null;
        var li = lines(buf);
        while (li.next()) |raw| {
            const line = trimCR(raw);
            if (parseInfoLine(line)) |info| {
                if (info.nodes != null and info.score_kind != .none) last_info = info;
            } else if (parseBestmove(line)) |bm| {
                best = bm;
            }
        }
        // Print BEFORE finish: bm.bestmove/ponder are slices into s.buffered(), which
        // s.finish() frees -- printing first copies the bytes into `out` (a
        // use-after-free here read as null bytes on macOS aarch64).
        const info = last_info orelse fail("nodestime: {s}: no scored info line (truncated?)", .{r.label});
        const bm = best orelse fail("nodestime: {s}: no bestmove", .{r.label});
        try out.print(gpa, "{s}depth={?d} score={s} {?d} nodes={?d} bestmove={s} ponder={s}\n", .{
            r.label, info.depth, @tagName(info.score_kind), info.score_val, info.nodes, bm.bestmove, bm.ponder,
        });
        _ = s.finish();
    }
    return out.toOwnedSlice(gpa);
}
