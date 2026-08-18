//! Build the goldens that pin what the SEARCH and the board compute: per-position search
//! fingerprints, perft divides, the NNUE eval trace, the nodestime budget, `go mate N`,
//! Chess960, and the non-default bench configurations.
//!
//! Each builder returns an owned fingerprint the root diffs against a committed golden. These
//! are the numeric gates: a drift here is a moved node count or a moved score, which is what
//! the bench signature cannot localise on its own.

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

// search-parity: build a per-position (depth, score, nodes, bestmove) fingerprint + TOTAL. bench
// info/bestmove are on stdout (51 blocks ending in `bestmove`); `Position:` + `Nodes
// searched` are on stderr. Pair the K-th Position with the K-th stdout block by index.
pub fn buildSearchParity(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    var cap = try runEngine(gpa, io, bin, &.{"bench"}, null);
    defer cap.deinit(gpa);

    // Read off stderr the ordered Position fields (the "N/51" token) + the final total.
    var positions: std.ArrayList([]const u8) = .empty;
    defer positions.deinit(gpa);
    var total: ?[]const u8 = null;
    var eli = lines(cap.stderr);
    while (eli.next()) |line| {
        if (startsWith(line, "Position: ")) {
            var toks = std.mem.tokenizeScalar(u8, line, ' ');
            _ = toks.next(); // "Position:"
            if (toks.next()) |p| try positions.append(gpa, p);
        } else if (startsWith(line, "Nodes searched")) {
            var toks = std.mem.tokenizeScalar(u8, line, ' ');
            var last: []const u8 = "";
            while (toks.next()) |t| last = t;
            total = last;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    // Split stdout into blocks at each `bestmove`, keeping the last `info depth` line.
    var block: usize = 0;
    var last_info: ?[]const u8 = null;
    var sli = lines(cap.stdout);
    while (sli.next()) |line| {
        if (startsWith(line, "info depth")) {
            last_info = line;
        } else if (startsWith(line, "bestmove")) {
            const pos = if (block < positions.items.len) positions.items[block] else "";
            var d: []const u8 = "";
            var nd: []const u8 = "";
            var sc: [32]u8 = undefined;
            var sc_len: usize = 0;
            if (last_info) |info| {
                var t = std.mem.tokenizeScalar(u8, info, ' ');
                var prev: []const u8 = "";
                while (t.next()) |tok| {
                    if (std.mem.eql(u8, prev, "depth")) d = tok;
                    if (std.mem.eql(u8, prev, "nodes")) nd = tok;
                    if (std.mem.eql(u8, prev, "score")) {
                        const kind = tok;
                        const val = t.next() orelse "";
                        if (std.fmt.bufPrint(&sc, "{s} {s}", .{ kind, val })) |printed| {
                            sc_len = printed.len;
                        } else |_| {}
                    }
                    prev = tok;
                }
            }
            var bm_toks = std.mem.tokenizeScalar(u8, line, ' ');
            _ = bm_toks.next(); // "bestmove"
            const bm = bm_toks.next() orelse "";
            try out.print(gpa, "{s:<6} depth={s:<3} score={s:<9} nodes={s:<9} bestmove={s}\n", .{ pos, d, sc[0..sc_len], nd, bm });
            block += 1;
            last_info = null;
        }
    }
    if (total) |t| {
        try out.print(gpa, "TOTAL nodes={s}\n", .{t});
    } else {
        fail("search-parity: could not parse bench output (engine crashed?)", .{});
    }
    return out.toOwnedSlice(gpa);
}

// perft: emit a `== label ==` header, then SORTED divide lines (byte order == C locale), then the
// `Nodes searched` total, per position. Divide + total are on stdout.
pub fn buildPerft(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    const sp = "position startpos";
    const kiwi = "position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";
    const pos3 = "position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1";
    const pos4 = "position fen r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1";
    const pos5 = "position fen rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8";
    const pos6 = "position fen r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10";
    const frc = "position fen nrkrbbqn/pppppppp/8/8/8/8/PPPPPPPP/NRKRBBQN w KQkq - 0 1";
    const runs = [_]struct { label: []const u8, seq: []const u8 }{
        .{ .label = "== startpos d5 ==", .seq = sp ++ "\ngo perft 5" },
        .{ .label = "== kiwipete d4 ==", .seq = kiwi ++ "\ngo perft 4" },
        .{ .label = "== pos3 d6 ==", .seq = pos3 ++ "\ngo perft 6" },
        .{ .label = "== pos4 d4 ==", .seq = pos4 ++ "\ngo perft 4" },
        .{ .label = "== pos5 d4 ==", .seq = pos5 ++ "\ngo perft 4" },
        .{ .label = "== pos6 d4 ==", .seq = pos6 ++ "\ngo perft 4" },
        .{ .label = "== frc960 d4 ==", .seq = "setoption name UCI_Chess960 value true\n" ++ frc ++ "\ngo perft 4" },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var totals: usize = 0;
    for (runs) |r| {
        try out.print(gpa, "{s}\n", .{r.label});
        const input = try std.fmt.allocPrint(gpa, "{s}\nquit\n", .{r.seq});
        defer gpa.free(input);
        var cap = try runEngine(gpa, io, bin, &.{}, input);
        defer cap.deinit(gpa);

        var divides: std.ArrayList([]const u8) = .empty;
        defer divides.deinit(gpa);
        var nodes_line: ?[]const u8 = null;
        var li = lines(cap.stdout);
        while (li.next()) |line| {
            if (isDivideLine(line)) {
                try divides.append(gpa, line);
            } else if (startsWith(line, "Nodes searched")) {
                nodes_line = line;
            }
        }
        std.mem.sort([]const u8, divides.items, {}, lessThanBytes);
        for (divides.items) |d| try out.print(gpa, "{s}\n", .{d});
        if (nodes_line) |nl| {
            try out.print(gpa, "{s}\n", .{nl});
            totals += 1;
        }
    }
    if (totals != 7) fail("perft: expected 7 totals, got {d} (engine crashed?)", .{totals});
    return out.toOwnedSlice(gpa);
}

fn lessThanBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// eval: capture the NNUE trace block from `NNUE network contributions` through `Final evaluation`
// (inclusive), per position. Read the trace from stderr.
pub fn buildEval(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    const sp = "position startpos";
    const kiwi = "position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";
    const end = "position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1";
    const mid = "position fen r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/3P1N2/PPP2PPP/RNBQK2R w KQkq - 0 5";
    const runs = [_]struct { label: []const u8, pos: []const u8 }{
        .{ .label = "== startpos ==", .pos = sp },
        .{ .label = "== kiwipete ==", .pos = kiwi },
        .{ .label = "== endgame ==", .pos = end },
        .{ .label = "== midgame ==", .pos = mid },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var finals: usize = 0;
    for (runs) |r| {
        try out.print(gpa, "{s}\n", .{r.label});
        const input = try std.fmt.allocPrint(gpa, "{s}\neval\nquit\n", .{r.pos});
        defer gpa.free(input);
        var cap = try runEngine(gpa, io, bin, &.{}, input);
        defer cap.deinit(gpa);
        // Range-filter over stderr (trace) then stdout, sharing state (block is contiguous).
        var f = false;
        inline for (.{ cap.stderr, cap.stdout }) |buf| {
            var li = lines(buf);
            while (li.next()) |line| {
                if (std.mem.find(u8, line, "NNUE network contributions") != null) f = true;
                if (f) {
                    try out.appendSlice(gpa, line);
                    try out.append(gpa, '\n');
                }
                if (startsWith(line, "Final evaluation")) {
                    if (f) finals += 1;
                    f = false;
                }
            }
        }
    }
    if (finals != 4) fail("eval: expected 4 'Final evaluation' lines, got {d} (crash?)", .{finals});
    return out.toOwnedSlice(gpa);
}

// bench-matrix: collect bench node counts for non-default configs (hash size / shallow depth
// / node limit / bench-perft), each a distinct deterministic code path the default bench
// (16/1/depth-13, whose count `signature` owns) never exercises. Verify equal to the pristine oracle
// and bit-exact across build modes (the node-limited config needed the conthistDelta i32-wrap
// fix -- deep searches otherwise overflow under ReleaseSafe). Use the feed-all-then-quit path
// safely -- `bench` is synchronous. Regenerate on an upstream/net bump, like the signature.
const bench_matrix_configs = [_][]const u8{
    "16 1 8", // shallow depth
    "128 1 13", // hash size (a different count from the default depth-13 run -> the TT-sizing path)
    "16 1 200000 default nodes", // node-limit path
    "16 1 3 default perft", // bench-perft path
};
pub fn buildBenchMatrix(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (bench_matrix_configs) |args| {
        const input = try std.fmt.allocPrint(gpa, "bench {s}\nquit\n", .{args});
        defer gpa.free(input);
        var cap = try runEngine(gpa, io, bin, &.{}, input);
        defer cap.deinit(gpa);
        var nodes: ?[]const u8 = null;
        var li = lines(cap.stderr);
        while (li.next()) |line| {
            if (startsWith(line, "Nodes searched")) {
                var toks = std.mem.tokenizeScalar(u8, line, ' ');
                var last: []const u8 = "";
                while (toks.next()) |t| last = t;
                nodes = last;
            }
        }
        const n = nodes orelse fail("bench-matrix: `bench {s}` produced no node count (panic?)", .{args});
        try out.print(gpa, "bench {s} nodes={s}\n", .{ args, n });
    }
    return out.toOwnedSlice(gpa);
}

// nodestime: with `nodestime` set, wall-clock budgets convert to a NODE budget
// (timeman.zig `npmsec`), so the otherwise non-deterministic time-management path becomes
// BIT-EXACT -- the `time-mgmt` gate can only band-check the reported ms. Pin the
// allocation arithmetic across its distinct branches (sudden-death wtime/btime, movestogo,
// increment, and the movetime hard limit) by the deterministic depth/score/nodes/bestmove
// the budget yields; the volatile `time`/`nps` fields are dropped. Single thread + node
// budget -> arch/OS-invariant. Drive the engine via the Interactive read-to-bestmove
// path since this is an async search -- a feed-all-then-quit pipe would truncate it (the
// batch hazard the search-modes gate also avoids).
const NodestimeRow = struct { label: []const u8, cmds: []const u8 };
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
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (rows) |r| {
        var s: Interactive = undefined;
        try s.init(io, gpa, bin);
        s.send("setoption name Threads value 1\nsetoption name nodestime value 600\n");
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

// mate: exercise `go mate N` -- the mate-distance search mode, distinct from the node/depth
// modes in search-modes (it uses mate-distance pruning and reports `score mate N`). Pin the
// mate DISTANCE and the mating move+ponder in the fingerprint: a bestmove-only golden would
// pass an engine that plays the mating move but reports the wrong distance. Each position has a
// VERIFIED forced mate at <= N, so `go mate N` finds it and stops fast (single thread ->
// deterministic); a mate-finding regression would instead never emit bestmove and hang the
// gate to the CI job timeout -- still a failure, just a slower one. Async -> Interactive path.
const MateRow = struct { label: []const u8, fen: []const u8, n: u8 };
pub fn buildMate(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    const rows = [_]MateRow{
        .{ .label = "mate1-backrank   ", .fen = "6k1/5ppp/8/8/8/8/8/R6K w - - 0 1", .n = 1 },
        .{ .label = "mate2-tworooks   ", .fen = "6k1/8/8/8/8/8/1R6/R6K w - - 0 1", .n = 2 },
        .{ .label = "mate3-rook+bishop", .fen = "r5rk/5p1p/5R2/4B3/8/8/7P/7K w - - 0 1", .n = 3 },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (rows) |r| {
        var s: Interactive = undefined;
        try s.init(io, gpa, bin);
        s.send("setoption name Threads value 1\n");
        var cmdbuf: [256]u8 = undefined;
        s.send(std.fmt.bufPrint(&cmdbuf, "position fen {s}\ngo mate {d}\n", .{ r.fen, r.n }) catch fail("golden_search: command buffer too small for the case table", .{}));
        _ = s.fillUntil("\nbestmove");
        const buf = s.buffered();

        var score: ?InfoLine = null;
        var best: ?BestmoveLine = null;
        var li = lines(buf);
        while (li.next()) |raw| {
            const line = trimCR(raw);
            if (parseInfoLine(line)) |info| {
                if (info.score_kind != .none) score = info;
            } else if (parseBestmove(line)) |bm| {
                best = bm;
            }
        }
        // Print BEFORE finish: bm.bestmove/ponder point into s.buffered(), freed by finish.
        const sc = score orelse fail("mate: {s}: no scored info line (mate not found?)", .{r.label});
        const bm = best orelse fail("mate: {s}: no bestmove", .{r.label});
        try out.print(gpa, "{s} score={s} {?d} bestmove={s} ponder={s}\n", .{
            r.label, @tagName(sc.score_kind), sc.score_val, bm.bestmove, bm.ponder,
        });
        _ = s.finish();
    }
    return out.toOwnedSlice(gpa);
}

// chess960: cover UCI_Chess960 search + castling + eval. `perft` already covers FRC MOVEGEN
// counts; exercise what it cannot -- FRC castling make/unmake inside a real search,
// the FRC castling ENCODING (applying the king-to-rook-square move f1g1 = O-O and rendering
// the resulting position), and the NNUE eval on FRC king placements. Single thread + fixed
// node budget -> deterministic; FRC castling/eval are arch/OS-invariant. Searches are async
// (Interactive); `d`/`eval` are synchronous (runEngine batch).
const frc_start = "nrkrbbqn/pppppppp/8/8/8/8/PPPPPPPP/NRKRBBQN w KQkq - 0 1";
const frc_mid = "qbrnnkrb/pppppppp/8/8/8/8/PPPPPPPP/QBRNNKRB w KGkg - 0 1";
pub fn buildChess960(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    // --- FRC searches (Interactive, node-limited): make/unmake FRC castling in the tree.
    const positions = [_]struct { label: []const u8, fen: []const u8 }{
        .{ .label = "frc-start", .fen = frc_start },
        .{ .label = "frc-mid  ", .fen = frc_mid },
    };
    for (positions) |p| {
        var s: Interactive = undefined;
        try s.init(io, gpa, bin);
        s.send("setoption name Threads value 1\nsetoption name UCI_Chess960 value true\n");
        var cb: [160]u8 = undefined;
        s.send(std.fmt.bufPrint(&cb, "position fen {s}\ngo nodes 300000\n", .{p.fen}) catch fail("golden_search: command buffer too small for the case table", .{}));
        _ = s.fillUntil("\nbestmove");
        const buf = s.buffered();
        var info: ?InfoLine = null;
        var best: ?BestmoveLine = null;
        var li = lines(buf);
        while (li.next()) |raw| {
            const line = trimCR(raw);
            if (parseInfoLine(line)) |i| {
                if (i.nodes != null and i.score_kind != .none) info = i;
            } else if (parseBestmove(line)) |bm| {
                best = bm;
            }
        }
        // Print BEFORE finish: bm.bestmove points into s.buffered(), freed by finish.
        const i = info orelse fail("chess960: {s}: no scored info", .{p.label});
        const bm = best orelse fail("chess960: {s}: no bestmove", .{p.label});
        try out.print(gpa, "search {s} depth={?d} score={s} {?d} nodes={?d} bestmove={s}\n", .{ p.label, i.depth, @tagName(i.score_kind), i.score_val, i.nodes, bm.bestmove });
        _ = s.finish();
    }

    // --- FRC castling applied: f1g1 is O-O in this setup (king f1 and its rook g1 are adjacent,
    // so O-O -- king onto its own rook's square -- is legal from the start). Apply it and dump
    // `d`: the resulting Fen must show the king on g1 and the rook on f1 (they swap), white's
    // castling rights cleared. Pin that the FRC castling move parses, applies, and renders
    // -- perft never plays/renders a castling move.
    {
        const input = "setoption name UCI_Chess960 value true\nposition fen " ++ frc_mid ++ " moves f1g1\nd\nquit\n";
        var cap = try runEngine(gpa, io, bin, &.{}, input);
        defer cap.deinit(gpa);
        var found = false;
        var li = lines(cap.stdout);
        while (li.next()) |line| {
            if (startsWithIgnoreCase(line, "Fen:") or startsWithIgnoreCase(line, "Key:")) {
                try out.print(gpa, "castle-OO {s}\n", .{line});
                found = true;
            }
        }
        if (!found) fail("chess960: castling `d` produced no Fen/Key (castling move rejected?)", .{});
    }

    // --- FRC eval: capture the NNUE eval on FRC king placements (Final evaluation line).
    for (positions) |p| {
        const input = try std.fmt.allocPrint(gpa, "setoption name UCI_Chess960 value true\nposition fen {s}\neval\nquit\n", .{p.fen});
        defer gpa.free(input);
        var cap = try runEngine(gpa, io, bin, &.{}, input);
        defer cap.deinit(gpa);
        var final_line: ?[]const u8 = null;
        inline for (.{ cap.stderr, cap.stdout }) |stream| {
            var li = lines(stream);
            while (li.next()) |line| {
                if (startsWith(line, "Final evaluation") and final_line == null) final_line = line;
            }
        }
        const fl = final_line orelse fail("chess960: {s}: no Final evaluation", .{p.label});
        try out.print(gpa, "eval {s} {s}\n", .{ p.label, std.mem.trim(u8, fl, " ") });
    }

    // --- A sloppy castling FIELD, at both settings of the option. `set` does not require the
    // castling token to agree with the pieces: for a `Q` it walks inward from the corner and
    // adopts the first rook it meets, so this board records a 960 geometry while the option
    // still says standard. `legal` must decide the castle on the ROOK'S geometry -- the rook on
    // b1 is the only thing between the king on e1 and the queen on a1, so castling exposes the
    // king and e1c1 is illegal. Gating that test on the option instead let it through, and
    // playing it reaches "King can be captured".
    //
    // Both arms are pinned because the bug was ASYMMETRIC: the 960 arm was always right, so a
    // golden covering only one of them cannot see the defect return. The counts must agree.
    {
        const sloppy = [_]struct { label: []const u8, setup: []const u8, fen: []const u8 }{
            .{ .label = "opt-off", .setup = "setoption name UCI_Chess960 value false\n", .fen = "4k3/8/8/8/8/8/8/qR2K3 w Q - 0 1" },
            .{ .label = "opt-on ", .setup = "setoption name UCI_Chess960 value true\n", .fen = "4k3/8/8/8/8/8/8/qR2K3 w B - 0 1" },
        };
        for (sloppy) |c| {
            const input = try std.fmt.allocPrint(gpa, "{s}position fen {s}\ngo perft 1\nquit\n", .{ c.setup, c.fen });
            defer gpa.free(input);
            var cap = try runEngine(gpa, io, bin, &.{}, input);
            defer cap.deinit(gpa);
            var total: ?[]const u8 = null;
            var saw_castle = false;
            var li = lines(cap.stdout);
            while (li.next()) |raw| {
                const line = trimCR(raw);
                if (startsWith(line, "Nodes searched:")) total = line;
                if (startsWith(line, "e1c1")) saw_castle = true;
            }
            const t = total orelse fail("chess960: sloppy-castling {s}: no perft total", .{c.label});
            try out.print(gpa, "sloppy-castling {s} {s} e1c1={}\n", .{ c.label, std.mem.trim(u8, t, " "), saw_castle });
        }
    }

    // --- Two castling tokens on the SAME side. `AB` puts both white rooks left of the king, so
    // both resolve to the same CastlingRights: the second `setCastlingRight` overwrote
    // castling_rook_square while the first rook kept its castling_rights_mask bit. doMove clears
    // the rights of whatever square a piece leaves, so moving the rook the position had already
    // DISCARDED destroyed the right the surviving rook owns. Pin both renderings -- the field as
    // parsed, and the field after the discarded rook moves.
    {
        const input = "setoption name UCI_Chess960 value true\n" ++
            "position fen 4k3/8/8/8/8/8/8/RR1K4 w AB - 0 1\nd\n" ++
            "position fen 4k3/8/8/8/8/8/8/RR1K4 w AB - 0 1 moves a1a2\nd\nquit\n";
        var cap = try runEngine(gpa, io, bin, &.{}, input);
        defer cap.deinit(gpa);
        var n: usize = 0;
        var li = lines(cap.stdout);
        while (li.next()) |raw| {
            const line = trimCR(raw);
            if (startsWithIgnoreCase(line, "Fen:")) {
                try out.print(gpa, "dup-castling-token {d} {s}\n", .{ n, line });
                n += 1;
            }
        }
        if (n != 2) fail("chess960: dup-castling-token: {d} of 2 Fen lines", .{n});
    }

    return out.toOwnedSlice(gpa);
}
