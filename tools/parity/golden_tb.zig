//! Build the Syzygy goldens: the load report, the WDL and DTZ probes, the root DTZ ranking,
//! and the in-search Step-6 node counts on both the 3-man and the 5-man cursed set.
//!
//! Every value here is adjudicated against the upstream oracle at the pinned sha, never
//! against this engine. `tb-cursed` reads a set the fetch step does not install, so it is
//! LOCAL-ONLY and outside `parity` -- which means its golden ages silently; re-derive it by
//! hand on every upstream sync.

const std = @import("std");
const Io = std.Io;
const run = @import("run.zig");
const session = @import("session.zig");
const structured_diff = @import("structured_diff.zig");

const runEngine = run.runEngine;
const lines = run.lines;
const startsWith = run.startsWith;
const startsWithIgnoreCase = run.startsWithIgnoreCase;
const removeField = run.removeField;
const trimCR = run.trimCR;
const isDivideLine = run.isDivideLine;
const fail = run.fail;
const Interactive = session.Interactive;
const InfoLine = structured_diff.InfoLine;
const BestmoveLine = structured_diff.BestmoveLine;
const parseInfoLine = structured_diff.parseInfoLine;
const parseBestmove = structured_diff.parseBestmove;

// tb-init: capture the Syzygy load report. Point SyzygyPath at the fetched 3-man set (syzygy/,
// relative to the resources/ cwd) and pin the `info string Found N WDL and N DTZ tablebase files (up to
// M-man)` line -- the discovery half of the Syzygy port, matched to the upstream oracle. Find the
// message on stdout (printInfoString). Synchronous, so the feed-all-then-quit path is safe.
pub fn buildTbInit(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    var cap = try runEngine(gpa, io, bin, &.{}, "setoption name SyzygyPath value syzygy\nquit\n");
    defer cap.deinit(gpa);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var found = false;
    var li = lines(cap.stdout);
    while (li.next()) |line| {
        if (std.mem.find(u8, line, "Found") != null and std.mem.find(u8, line, "tablebase") != null) {
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
            found = true;
        }
    }
    if (!found) fail("tb-init: no 'Found ... tablebase' line (SyzygyPath init failed / syzygy/ missing?)", .{});
    return out.toOwnedSlice(gpa);
}

// Curate the 3-man probe battery, shared by tb-wdl and tb-dtz: all five
// piece types (Q/R/B/N/P), win/loss/draw, white/black to move, the pawn + blackStronger (lead pawn
// is black) flip paths, and -- via the last two -- the search<false> capture recursion (the lone
// king captures the piece into a KvK draw). KQvK-btm also exercises the DTZ CHANGE_STM 1-ply path.
const tb_probe_runs = [_]struct { label: []const u8, fen: []const u8 }{
    .{ .label = "KQvK-wtm (win)  ", .fen = "4k3/8/8/8/3QK3/8/8/8 w - - 0 1" },
    .{ .label = "KQvK-btm (loss) ", .fen = "4k3/8/8/8/3QK3/8/8/8 b - - 0 1" },
    .{ .label = "KPvK-wtm (win)  ", .fen = "8/8/8/8/8/3K4/3P4/3k4 w - - 0 1" },
    .{ .label = "KPvK-btm (draw) ", .fen = "8/8/8/8/8/k7/p7/K7 b - - 0 1" },
    .{ .label = "KRvK-wtm (win)  ", .fen = "8/8/8/8/8/3k4/8/R2K4 w - - 0 1" },
    .{ .label = "KNvK-wtm (draw) ", .fen = "8/8/8/8/8/3k4/8/N2K4 w - - 0 1" },
    .{ .label = "KBvK-wtm (draw) ", .fen = "8/8/8/8/8/3k4/8/B2K4 w - - 0 1" },
    .{ .label = "KQvK cap->draw  ", .fen = "8/8/8/8/8/1Qk5/8/K7 b - - 0 1" },
    .{ .label = "KRvK cap->draw  ", .fen = "8/8/8/8/8/1Rk5/8/K7 b - - 0 1" },
};

// Run the `d`-command probe battery, pinning the `Tablebases <prefix>: N (state)` line ==
// upstream oracle for each position. Operate in resources/ cwd so "syzygy" resolves to the fetch dir.
fn buildTbProbe(gpa: std.mem.Allocator, io: Io, bin: []const u8, prefix: []const u8, tag: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (tb_probe_runs) |r| {
        const input = try std.fmt.allocPrint(gpa, "setoption name SyzygyPath value syzygy\nposition fen {s}\nd\nquit\n", .{r.fen});
        defer gpa.free(input);
        var cap = try runEngine(gpa, io, bin, &.{}, input);
        defer cap.deinit(gpa);
        var found: ?[]const u8 = null;
        var li = lines(cap.stdout);
        while (li.next()) |line| {
            if (startsWithIgnoreCase(line, prefix)) found = line;
        }
        const line = found orelse fail("{s}: {s}: no '{s}' line (probe unavailable / syzygy/ missing?)", .{ tag, r.label, prefix });
        try out.print(gpa, "{s} | {s}\n", .{ r.label, line });
    }
    return out.toOwnedSlice(gpa);
}

pub fn buildTbWdl(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    return buildTbProbe(gpa, io, bin, "Tablebases WDL:", "tb-wdl");
}

pub fn buildTbDtz(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    return buildTbProbe(gpa, io, bin, "Tablebases DTZ:", "tb-dtz");
}

// tb-root: capture the Syzygy root DTZ ranking. With the DTZ probe live, `go` on a TB win ranks
// the root moves via rankRootMovesDtz; the emit shows the exact tbScore (not the search score) and
// tbHits == pool hits + rootMoves.size(). Pin score + tbhits == the upstream oracle -- this
// first-validates the formerly-dead root-ranking formula end to end (it surfaced three real
// discrepancies: the missing +rootMoves.size tbHits term, the missing tbScore emit override, and
// the hardcoded max_dtz-dtz rank ignoring rankDTZ/dtz_is_dtm).
//
// NOT gated here: the exact bestmove + nodes. The oracle early-returns (nodes 0) on a rootInTB
// decisive win and plays rootMoves[0] (the DTZ tie-break order); zfish still runs the search, so
// among equally-optimal TB moves it can pick a different (also-winning) move. That rootInTB
// search early-exit is in-search behaviour, so gating zfish's divergent bestmove as a
// golden would be fake parity. score + tbhits are robust to it (both engines do 0 in-tree probes
// and both override the shown score with tbScore). Threads=1; Interactive read-to-bestmove.
pub fn buildTbRoot(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    const rows = [_]struct { label: []const u8, fen: []const u8, depth: u8 }{
        .{ .label = "KQvK-wtm ", .fen = "4k3/8/8/8/3QK3/8/8/8 w - - 0 1", .depth = 6 },
        .{ .label = "KRvK-wtm ", .fen = "8/8/8/8/8/3k4/8/R2K4 w - - 0 1", .depth = 8 },
        .{ .label = "KPvK-win ", .fen = "8/8/8/8/8/3K4/3P4/3k4 w - - 0 1", .depth = 8 },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (rows) |r| {
        var s: Interactive = undefined;
        try s.init(io, gpa, bin);
        s.send("setoption name SyzygyPath value syzygy\nsetoption name Threads value 1\n");
        var cmdbuf: [256]u8 = undefined;
        s.send(std.fmt.bufPrint(&cmdbuf, "position fen {s}\ngo depth {d}\n", .{ r.fen, r.depth }) catch fail("golden_tb: command buffer too small for the case table", .{}));
        _ = s.fillUntil("\nbestmove");
        const buf = s.buffered();

        var score: ?InfoLine = null;
        var li = lines(buf);
        while (li.next()) |raw| {
            const line = trimCR(raw);
            if (parseInfoLine(line)) |info| {
                if (info.score_kind != .none) score = info;
            }
        }
        const sc = score orelse fail("tb-root: {s}: no scored info line (root probe failed?)", .{r.label});
        try out.print(gpa, "{s} score={s} {?d} tbhits={?d}\n", .{
            r.label, @tagName(sc.score_kind), sc.score_val, sc.tbhits,
        });
        _ = s.finish();
    }

    // --- The WDL FALLBACK ranking, which only runs when DTZ is unavailable, under both settings
    // of Syzygy50MoveRule.
    //
    // rankRootMovesWdl once tested `isDraw` without the option, so with the rule off -- the
    // setting whose whole meaning is that the halfmove clock does not end the game -- every root
    // move became a draw once that clock crossed 99, rankMovesAt zeroed the cardinality, and the
    // search stopped probing. Nothing above can see it: with DTZ present the fallback never runs,
    // and at the default setting the two draw tests agree.
    //
    // Stage a WDL-ONLY corpus to force the fallback. The stems are the 3-man set the fetch
    // installs, the same five tb-init pins the count of -- if that set ever changes, tb-init
    // reddens before this does. Copied rather than linked so the path is a plain directory on
    // every filesystem the gate runs on.
    {
        const wdl_dir = "tb_root_wdlonly_tmp";
        const stems = [_][]const u8{ "KBvK", "KNvK", "KPvK", "KQvK", "KRvK" };
        defer Io.Dir.cwd().deleteTree(io, wdl_dir) catch {};
        Io.Dir.cwd().deleteTree(io, wdl_dir) catch {};
        try Io.Dir.cwd().createDirPath(io, wdl_dir);
        var dest = try Io.Dir.cwd().openDir(io, wdl_dir, .{});
        defer dest.close(io);
        var src = try Io.Dir.cwd().openDir(io, "syzygy", .{});
        defer src.close(io);
        for (stems) |stem| {
            var nb: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&nb, "{s}.rtbw", .{stem}) catch unreachable;
            src.copyFile(name, dest, name, io, .{}) catch
                fail("tb-root: staging {s} into {s} failed (is resources/syzygy fetched?)", .{ name, wdl_dir });
        }

        // A KRvK win with the halfmove clock at 99. The reported SCORE does not move -- the
        // search's own isDraw applies the fifty-move rule whatever the tablebase says -- so pin
        // the NODE COUNT, which is where the zeroed cardinality shows.
        const rule50_cases = [_]struct { label: []const u8, value: []const u8 }{
            .{ .label = "wdl-only-rule50-on ", .value = "true" },
            .{ .label = "wdl-only-rule50-off", .value = "false" },
        };
        for (rule50_cases) |c| {
            var s: Interactive = undefined;
            try s.init(io, gpa, bin);
            var setup: [256]u8 = undefined;
            s.send(std.fmt.bufPrint(&setup, "setoption name SyzygyPath value {s}\nsetoption name Threads value 1\nsetoption name Syzygy50MoveRule value {s}\n", .{ wdl_dir, c.value }) catch unreachable);
            s.send("position fen 8/8/8/8/8/8/4k3/K6R w - - 99 100\ngo depth 12\n");
            _ = s.fillUntil("\nbestmove");
            var last: ?InfoLine = null;
            var li2 = lines(s.buffered());
            while (li2.next()) |raw| {
                const line = trimCR(raw);
                if (parseInfoLine(line)) |info| {
                    if (info.nodes != null) last = info;
                }
            }
            const got = last orelse fail("tb-root: {s}: no info line with nodes", .{c.label});
            try out.print(gpa, "{s} nodes={?d} tbhits={?d}\n", .{ c.label, got.nodes, got.tbhits });
            _ = s.finish();
        }
    }

    return out.toOwnedSlice(gpa);
}

// tb-search: exercise the in-search Step 6 WDL probe. Bench a small 4-man EPD (each position
// bigger than the 3-man tables, so the root is searched normally and Step 6 probes the 3-man
// nodes reached in the tree). Pin the node count WITH SyzygyPath (Step 6 cutting the tree) and
// WITHOUT (Step 6 off) both == the upstream oracle -- bit-exact node-count parity. bench writes the
// count to stderr; the EPD is written transiently into the resources/ cwd. Both counts are deterministic.
fn benchNodes(gpa: std.mem.Allocator, io: Io, bin: []const u8, input: []const u8) !u64 {
    var cap = try runEngine(gpa, io, bin, &.{}, input);
    defer cap.deinit(gpa);
    var nodes: ?u64 = null;
    var li = lines(cap.stderr);
    while (li.next()) |line| {
        if (startsWith(line, "Nodes searched")) {
            var toks = std.mem.tokenizeScalar(u8, line, ' ');
            var last: []const u8 = "";
            while (toks.next()) |t| last = t;
            nodes = std.fmt.parseInt(u64, last, 10) catch null;
        }
    }
    return nodes orelse fail("tb-search: no 'Nodes searched' line (bench crashed / bad EPD?)", .{});
}

pub fn buildTbSearch(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    // Each position has more pieces than the 3-man tables, so the root searches normally and the
    // in-tree Step 6 probe fires at the 3-man nodes captures reach. Bench ONE per file (a
    // multi-position bench carries the TT between positions), so both the no-tb baseline and the
    // Step 6 delta are per-position bit-exact vs the oracle. Both draws (KNNvK, KRvKR).
    //
    // The third column pins the check-time CADENCE, not just the tree: every TB probe zeroes the
    // time-check counter (upstream search.cpp:917), so a node-limited stop lands on a different
    // node when that reset is missing. Use N >= 524288 so the counter reseeds the full 512 and
    // the reset is the only cadence input; a depth-limited bench is blind to this whole axis.
    const rows = [_]struct { label: []const u8, fen: []const u8 }{
        .{ .label = "KNNvK", .fen = "8/8/8/8/3k4/8/1N1NK3/8 w - - 0 1" },
        .{ .label = "KNvKN", .fen = "8/8/8/8/3k4/8/1N1nK3/8 w - - 0 1" },
        .{ .label = "KPvKN", .fen = "8/8/8/8/3k4/8/1P1nK3/8 w - - 0 1" },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    // Remove the scratch EPD on the way out. `export_net`'s builder already did this for its
    // temp; these two did not, so every run left a file behind in the engine's own runtime
    // directory -- where the next `bench <file>` reads whatever an interrupted run left.
    //
    // The name is fixed, so two of THIS gate running at once in one checkout would race it.
    // Left fixed on purpose: `zig build` already serialises a step against itself, and two
    // concurrent builds in one tree collide on .zig-cache long before they reach here.
    defer Io.Dir.cwd().deleteFile(io, "tb_search_tmp.epd") catch {};
    for (rows) |r| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = "tb_search_tmp.epd", .data = r.fen });
        const with_tb = try benchNodes(gpa, io, bin, "setoption name SyzygyPath value syzygy\nbench 16 1 10 tb_search_tmp.epd depth\nquit\n");
        const no_tb = try benchNodes(gpa, io, bin, "bench 16 1 10 tb_search_tmp.epd depth\nquit\n");
        const nodes_tb = try benchNodes(gpa, io, bin, "setoption name SyzygyPath value syzygy\nbench 16 1 600000 tb_search_tmp.epd nodes\nquit\n");
        try out.print(gpa, "{s} no-tb={d} with-tb={d} nodes-tb={d}\n", .{ r.label, no_tb, with_tb, nodes_tb });
    }
    return out.toOwnedSlice(gpa);
}

// tb-cursed (LOCAL ONLY): validate the cursed-win / blessed-loss / 50-move logic on real
// DTZ>100 positions, which need 4-5-man tables the 3-man CI set never contains. Pin the `d`-command
// WDL + DTZ == the upstream oracle for a KNNvKP cursed win (WDL +1, DTZ 122 -- a win that is a draw
// under the 50-move rule) and its blessed-loss mirror (WDL -1, DTZ -115). Exercise the cursed
// branches of map_score<DTZ> (x2 plies) and probe_dtz (the dtz+100*cursed*sign arithmetic). NOT in
// the `parity` aggregate: it requires ~40 MB of 5-man tables staged into resources/syzygy5/ locally,
// e.g. (from resources/):  for t in KNNvKP KNNvK KNNvKQ KNNvKR KNNvKB KNNvKN KNvKP KNvKQ KNvKR KNvKB KNvKN
//   KPvKN KQvKN KRvKN KBvKN; do for e in wdl:rtbw dtz:rtbz; do curl -s -o syzygy5/$t.${e#*:} \
//   https://tablebase.lichess.ovh/tables/standard/3-4-5-${e%:*}/$t.${e#*:}; done; done
pub fn buildTbCursed(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    const runs = [_]struct { label: []const u8, fen: []const u8 }{
        .{ .label = "cursed-win  ", .fen = "8/8/8/3k4/p7/8/2N5/N3K3 w - - 0 1" },
        .{ .label = "blessed-loss", .fen = "n3k3/2n5/8/3K4/P7/8/8/8 w - - 0 1" },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (runs) |r| {
        const input = try std.fmt.allocPrint(gpa, "setoption name SyzygyPath value syzygy5:syzygy\nposition fen {s}\nd\nquit\n", .{r.fen});
        defer gpa.free(input);
        var cap = try runEngine(gpa, io, bin, &.{}, input);
        defer cap.deinit(gpa);
        var wdl_line: ?[]const u8 = null;
        var dtz_line: ?[]const u8 = null;
        var li = lines(cap.stdout);
        while (li.next()) |line| {
            if (startsWithIgnoreCase(line, "Tablebases WDL:")) wdl_line = line;
            if (startsWithIgnoreCase(line, "Tablebases DTZ:")) dtz_line = line;
        }
        const wl = wdl_line orelse fail("tb-cursed: {s}: no WDL line (5-man tables missing from resources/syzygy5/? see the fn comment)", .{r.label});
        const dl = dtz_line orelse fail("tb-cursed: {s}: no DTZ line (5-man tables missing?)", .{r.label});
        try out.print(gpa, "{s} | {s} | {s}\n", .{ r.label, wl, dl });
    }
    // Node-limited legs at the SAME dual-path config: pin the search total where
    // 5-man probes (cursed-win rule50 semantics included) fire mid-search. Only a
    // node-limited run can see the per-probe time-check reset (upstream
    // search.cpp:917) on this table set -- the display legs above are static and
    // the tb-search legs probe the 3-man path only. Non-round limits land the
    // stop mid-reseed-phase, sharpening the discriminator. Derive golden values
    // from the oracle UNDER THIS EXACT SyzygyPath: a golden derived at a
    // different path config pins a different probe stream (paid for in mcfish).
    const node_runs = [_]struct { label: []const u8, limit: u32, fen: []const u8 }{
        .{ .label = "nodes-tb-cursed-win  ", .limit = 123457, .fen = "8/8/8/3k4/p7/8/2N5/N3K3 w - - 0 1" },
        .{ .label = "nodes-tb-blessed-loss", .limit = 234567, .fen = "n3k3/2n5/8/3K4/P7/8/8/8 w - - 0 1" },
    };
    defer Io.Dir.cwd().deleteFile(io, "tb_cursed_tmp.epd") catch {};
    for (node_runs) |r| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = "tb_cursed_tmp.epd", .data = r.fen });
        const input = try std.fmt.allocPrint(gpa, "setoption name SyzygyPath value syzygy5:syzygy\nbench 16 1 {d} tb_cursed_tmp.epd nodes\nquit\n", .{r.limit});
        defer gpa.free(input);
        const nodes_tb = try benchNodes(gpa, io, bin, input);
        try out.print(gpa, "{s} nodes-tb={d}\n", .{ r.label, nodes_tb });
    }
    return out.toOwnedSlice(gpa);
}
