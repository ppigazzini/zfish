//! Run the gates that assert a RELATION between two runs, not a fixed value: reset
//! determinism, Skill Level's determinism and its randomness, a repeated `go`, a truncated
//! FEN, `flip` under Chess960, and the ponder handshake.
//!
//! Metamorphic by construction -- each drives the engine twice (or twelve times) and compares
//! the runs to each other, so none of them owns a golden. That is what lets them cover the
//! paths a fixed fingerprint cannot: state that must survive a reset, and a move that must
//! legitimately vary.

const std = @import("std");
const Io = std.Io;
const run = @import("run.zig");
const session = @import("session.zig");
const structured_diff = @import("structured_diff.zig");

const runEngine = run.runEngine;
const lines = run.lines;
const startsWith = run.startsWith;
const trimCR = run.trimCR;
const isDivideLine = run.isDivideLine;
const fail = run.fail;
const Interactive = session.Interactive;
const Outcome = session.Outcome;
const scanInfo = session.scanInfo;
const wellFormedMove = session.wellFormedMove;
const runSearch = session.runSearch;
const ScoreKind = structured_diff.ScoreKind;
const optEql = structured_diff.optEql;
const parseInfoLine = structured_diff.parseInfoLine;
const parseBestmove = structured_diff.parseBestmove;

// reset-determinism: run a metamorphic gate for TT/history reset. A stale-state bleed (a
// ucinewgame that fails to clear the TT/histories, or a Clear Hash that no-ops) is invisible
// to every golden -- those run one clean process. Here, in ONE process, run the SAME fixed-node
// single-thread search several times and assert three relations no snapshot can:
//   R1 reuse-live: a second identical search WITHOUT a reset changes the node count (the TT is
//                  actually being consulted -- else it would repeat the same count).
//   R2 clear-hash: after `setoption Clear Hash`, the search no longer gets the reuse discount
//                  (its node count differs from the reuse run). Compared against the REUSE run,
//                  not the clean run, on purpose: Clear Hash empties only the TT, not the
//                  histories, so it need not reproduce the clean count exactly -- only lose the
//                  TT-reuse speedup.
//   R3 full-reset: `ucinewgame` restores the EXACT clean search (depth/score/nodes/bestmove/
//                  ponder), proving it clears both the TT and the histories with no bleed.
const ResetFp = struct {
    depth: ?i64 = null,
    kind: ScoreKind = .none,
    val: ?i64 = null,
    nodes: ?i64 = null,
    bm_buf: [8]u8 = undefined,
    bm_len: usize = 0,
    pd_buf: [8]u8 = undefined,
    pd_len: usize = 0,
    fn bm(self: *const ResetFp) []const u8 {
        return self.bm_buf[0..self.bm_len];
    }
    fn pd(self: *const ResetFp) []const u8 {
        return self.pd_buf[0..self.pd_len];
    }
    fn eql(x: ResetFp, y: ResetFp) bool {
        return optEql(x.depth, y.depth) and x.kind == y.kind and optEql(x.val, y.val) and
            optEql(x.nodes, y.nodes) and std.mem.eql(u8, x.bm(), y.bm()) and std.mem.eql(u8, x.pd(), y.pd());
    }
};

// Run one startpos depth-14 search in the shared session (optionally preceded by `pre`, e.g.
// ucinewgame / Clear Hash) and fingerprint its final scored info line + bestmove. Parse only
// the output since the previous search (the buffer grows; `mark` is a stable offset).
fn resetSearch(s: *Interactive, pre: []const u8) ResetFp {
    const mark = s.buffered().len;
    if (pre.len != 0) s.send(pre);
    s.send("position startpos\ngo depth 14\n");
    _ = s.fillUntil("\nbestmove");
    var fp = ResetFp{};
    var li = lines(s.buffered()[mark..]);
    while (li.next()) |raw| {
        const line = trimCR(raw);
        if (parseInfoLine(line)) |i| {
            if (i.nodes != null and i.score_kind != .none) {
                fp.depth = i.depth;
                fp.kind = i.score_kind;
                fp.val = i.score_val;
                fp.nodes = i.nodes;
            }
        } else if (parseBestmove(line)) |b| {
            const n = @min(b.bestmove.len, fp.bm_buf.len);
            @memcpy(fp.bm_buf[0..n], b.bestmove[0..n]);
            fp.bm_len = n;
            const m = @min(b.ponder.len, fp.pd_buf.len);
            @memcpy(fp.pd_buf[0..m], b.ponder[0..m]);
            fp.pd_len = m;
        }
    }
    return fp;
}

pub fn runResetDeterminism(gpa: std.mem.Allocator, io: Io, bin: []const u8) noreturn {
    var s: Interactive = undefined;
    s.init(io, gpa, bin) catch fail("reset-determinism: spawn failed", .{});
    const a = resetSearch(&s, "ucinewgame\n"); // clean reference
    const b = resetSearch(&s, ""); // no reset -> TT reuse
    const f = resetSearch(&s, "setoption name Clear Hash\n"); // clears TT only
    const c = resetSearch(&s, "ucinewgame\n"); // full reset
    _ = s.finish();

    if (a.nodes == null or b.nodes == null or f.nodes == null or c.nodes == null)
        fail("reset-determinism: a search produced no node count (truncated?)", .{});
    if (a.nodes.? == b.nodes.?)
        fail("reset-determinism: TT reuse not observable -- second search matched the first ({d} nodes); TT unused?", .{a.nodes.?});
    if (f.nodes.? == b.nodes.?)
        fail("reset-determinism: Clear Hash did NOT clear the TT -- still reusing ({d} nodes)", .{b.nodes.?});
    if (!ResetFp.eql(a, c))
        fail("reset-determinism: ucinewgame did NOT restore the clean search (state bleed) -- A nodes={?d} score={s} {?d} bm={s} | C nodes={?d} score={s} {?d} bm={s}", .{ a.nodes, @tagName(a.kind), a.val, a.bm(), c.nodes, @tagName(c.kind), c.val, c.bm() });

    std.debug.print("reset-determinism: OK (ucinewgame A==C exact nodes={?d}; TT reuse {?d}->{?d} live; Clear Hash clears TT -> {?d})\n", .{ a.nodes, a.nodes, b.nodes, f.nodes });
    std.process.exit(0);
}

// skill: treat Skill Level as a NON-deterministic path (a wall-clock-seeded PRNG biases the move
// pick, search_id.zig), so no snapshot is possible. Assert the metamorphic relations a snapshot
// cannot: (1) at Skill 20 the handicap is disabled (skill_enabled=0), so repeated searches are
// DETERMINISTIC -- one distinct move; (2) at Skill 0 the PRNG is active, so repeated searches
// VARY -- >= 2 distinct moves, every one legal. The PRNG seeds once per process and advances per
// pick (it is not reset by ucinewgame), so K searches in ONE process give variance without the
// cross-process same-millisecond seed collision a multi-process loop risks. Robustness measured:
// over 25 process-seeds, K=12 skill-0 cardinality was min 3 (never near the >=2 floor).
const MoveSet = struct {
    moves: [24][8]u8 = undefined,
    lens: [24]usize = undefined,
    count: usize = 0,
    fn add(self: *MoveSet, m: []const u8) void {
        var j: usize = 0;
        while (j < self.count) : (j += 1) {
            if (std.mem.eql(u8, self.moves[j][0..self.lens[j]], m)) return; // already seen
        }
        if (self.count >= self.moves.len) return; // cap (24 distinct is far beyond any real case)
        const n = @min(m.len, self.moves[self.count].len);
        @memcpy(self.moves[self.count][0..n], m[0..n]);
        self.lens[self.count] = n;
        self.count += 1;
    }
};

const skill_depth = 10;
const skill_det_runs = 6; // Skill 20: must stay a single move (deterministic)
const skill_live_runs = 12; // Skill 0: must vary (>= 2 distinct)

// Run one startpos depth-`skill_depth` search in the shared session (fresh TT via ucinewgame; the
// skill PRNG persists across it) -> the bestmove (a slice into s.buffered(), valid until finish).
fn skillMove(s: *Interactive) []const u8 {
    const mark = s.buffered().len;
    s.send("ucinewgame\nposition startpos\ngo depth 10\n");
    _ = s.fillUntil("\nbestmove");
    var li = lines(s.buffered()[mark..]);
    while (li.next()) |raw| {
        const line = trimCR(raw);
        if (startsWith(line, "bestmove")) {
            var t = std.mem.tokenizeScalar(u8, line, ' ');
            _ = t.next();
            return t.next() orelse "";
        }
    }
    return "";
}

// repeat-go: drive consecutive `go` commands with NO intervening `position`, the most ordinary
// sequence a GUI issues (analyse, stop, analyse again). Upstream guards the setup-state transfer
// -- `if (states.get()) setupStates = std::move(states)` (thread.cpp:316-321) -- so the pool
// reuses the list it already owns when the engine's slot is empty. zfish freed that list and
// stored null instead, so the SECOND `go` panicked and dumped core in the shipped ReleaseFast
// binary. Every other gate re-sends `position` before each `go`, which is precisely why a
// process-killing defect was invisible to all of them.
//
// Liveness, not a snapshot: N `go`s must produce N well-formed bestmoves and a clean exit.
pub fn runRepeatGo(gpa: std.mem.Allocator, io: Io, bin: []const u8) noreturn {
    const rounds = 4;

    var s: Interactive = undefined;
    s.init(io, gpa, bin) catch fail("repeat-go: spawn failed", .{});

    s.send("position startpos\n");
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        s.send("go depth 6\n");
        if (!s.fillUntil("bestmove"))
            fail("repeat-go: `go` #{d} produced no bestmove -- the engine died on a repeated go with no intervening `position` (setup-state handoff)", .{i + 1});
    }
    // Scan BEFORE finish(): finish() calls mr.deinit(), which frees the buffer `buffered()`
    // returns. Reading it afterwards is a use-after-free that happens to survive on some hosts.
    var seen: usize = 0;
    var li = lines(s.buffered());
    while (li.next()) |raw| {
        const line = trimCR(raw);
        if (parseBestmove(line)) |b| {
            if (!wellFormedMove(b.bestmove))
                fail("repeat-go: malformed bestmove '{s}' on go #{d}", .{ b.bestmove, seen + 1 });
            seen += 1;
        }
    }
    if (seen != rounds)
        fail("repeat-go: expected {d} bestmoves from {d} consecutive `go`s, got {d}", .{ rounds, rounds, seen });
    const clean_exit = s.finish();
    if (!clean_exit)
        fail("repeat-go: engine did not exit cleanly after {d} consecutive `go`s -- a panic/abort here kills the process for any GUI", .{rounds});

    std.debug.print("repeat-go: OK ({d} consecutive `go` with no intervening `position`, {d} legal bestmoves, clean exit)\n", .{ rounds, seen });
    std.process.exit(0);
}

// fen-truncated: a FEN missing trailing fields must SET, not fail. Upstream reads them with
// `ss >> token`, so an exhausted stream leaves the castling loop unentered, the en-passant char at
// its '-' initializer, and `ss >> rule50 >> gamePly` failing into 0/0. A malformed halfmove field
// puts the stream in fail state, so the fullmove field cannot be read into rule50 either.
//
// The expectations are LITERAL, not a regenerable golden: each was verified against the pristine
// upstream oracle at the tracked sha. A golden here could be regenerated green over a defect,
// which is the failure mode this gate exists to prevent.
const FenCase = struct { fen: []const u8, want: []const u8 };
const fen_truncated_cases = [_]FenCase{
    // Stops after the side to move: castling, ep and both counters default.
    .{ .fen = "8/8/8/8/8/4k3/8/R3K3 w", .want = "8/8/8/8/8/4k3/8/R3K3 w - - 0 1" },
    // Stops after castling.
    .{ .fen = "8/8/8/8/8/4k3/8/R3K3 w -", .want = "8/8/8/8/8/4k3/8/R3K3 w - - 0 1" },
    // `-` where the halfmove belongs: the stream fails, so the trailing 7 is NOT read as rule50.
    // `KQ` drops to `Q` because no rook stands on h1.
    .{ .fen = "8/8/8/8/8/4k3/8/R3K3 w KQ - - 7", .want = "8/8/8/8/8/4k3/8/R3K3 w Q - 0 1" },
};

pub fn runFenTruncated(gpa: std.mem.Allocator, io: Io, bin: []const u8) noreturn {
    var s: Interactive = undefined;
    s.init(io, gpa, bin) catch fail("fen-truncated: spawn failed", .{});

    for (fen_truncated_cases) |tc| {
        s.send("position fen ");
        s.send(tc.fen);
        s.send("\nd\n");
        if (!s.fillUntil("Checkers:"))
            fail("fen-truncated: `position fen {s}` produced no board -- a FEN missing trailing fields must set, not fail", .{tc.fen});
    }
    // Scan BEFORE finish(): finish() deinits the reader and frees this buffer.
    var idx: usize = 0;
    var li = lines(s.buffered());
    while (li.next()) |raw| {
        const line = trimCR(raw);
        if (!startsWith(line, "Fen: ")) continue;
        if (idx >= fen_truncated_cases.len) break;
        const got = std.mem.trim(u8, line["Fen: ".len..], " ");
        const tc = fen_truncated_cases[idx];
        if (!std.mem.eql(u8, got, tc.want))
            fail("fen-truncated: `{s}`\n  want: {s}\n  got : {s}", .{ tc.fen, tc.want, got });
        idx += 1;
    }
    _ = s.finish();
    if (idx != fen_truncated_cases.len)
        fail("fen-truncated: {d} of {d} cases produced a Fen line", .{ idx, fen_truncated_cases.len });

    std.debug.print("fen-truncated: OK ({d} truncated/malformed FENs set with upstream's defaults)\n", .{idx});
    std.process.exit(0);
}

// flip-chess960: `flip` re-sets the board from its own FEN, and must re-parse it under the
// variant the board already has. Upstream ends Position::flip with `set(f, is_chess960(), st)`
// (position.cpp:1626), so toggling UCI_Chess960 between `position` and `flip` cannot reinterpret
// castling rights that were parsed under the other variant.
//
// Both directions are pinned: a 960 board keeps its file-letter rights after the option is turned
// OFF, and a standard board still reports KQkq. Expectations are LITERAL, each verified against
// the pristine oracle -- a regenerable golden could be rewritten green over the defect.
const FlipCase = struct { setup: []const u8, want: []const u8 };
const flip_cases = [_]FlipCase{
    .{
        .setup = "setoption name UCI_Chess960 value true\nposition fen bqnbnrkr/pppppppp/8/8/8/8/PPPPPPPP/BQNBNRKR w HFhf - 0 1\nsetoption name UCI_Chess960 value false\nflip\nd\n",
        .want = "bqnbnrkr/pppppppp/8/8/8/8/PPPPPPPP/BQNBNRKR b HFhf - 0 1",
    },
    .{
        .setup = "setoption name UCI_Chess960 value false\nposition startpos\nflip\nd\n",
        .want = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1",
    },
};

pub fn runFlipChess960(gpa: std.mem.Allocator, io: Io, bin: []const u8) noreturn {
    var s: Interactive = undefined;
    s.init(io, gpa, bin) catch fail("flip-chess960: spawn failed", .{});

    for (flip_cases) |fc| {
        s.send(fc.setup);
        if (!s.fillUntil("Checkers:"))
            fail("flip-chess960: `flip` produced no board", .{});
    }
    // Scan BEFORE finish(): finish() deinits the reader and frees this buffer.
    var idx: usize = 0;
    var li = lines(s.buffered());
    while (li.next()) |raw| {
        const line = trimCR(raw);
        if (!startsWith(line, "Fen: ")) continue;
        if (idx >= flip_cases.len) break;
        const got = std.mem.trim(u8, line["Fen: ".len..], " ");
        if (!std.mem.eql(u8, got, flip_cases[idx].want))
            fail("flip-chess960: case {d}\n  want: {s}\n  got : {s}\n  -- flip re-parsed the board under the live UCI_Chess960 option instead of the board's own variant", .{ idx, flip_cases[idx].want, got });
        idx += 1;
    }
    _ = s.finish();
    if (idx != flip_cases.len)
        fail("flip-chess960: {d} of {d} cases produced a Fen line", .{ idx, flip_cases.len });

    std.debug.print("flip-chess960: OK ({d} flips re-parsed under the board's own variant)\n", .{idx});
    std.process.exit(0);
}

pub fn runSkill(gpa: std.mem.Allocator, io: Io, bin: []const u8) noreturn {
    var s: Interactive = undefined;
    s.init(io, gpa, bin) catch fail("skill: spawn failed", .{});

    // (1) Skill 20 -> handicap off -> deterministic (one distinct move).
    s.send("setoption name Skill Level value 20\n");
    var det: MoveSet = .{};
    var i: usize = 0;
    while (i < skill_det_runs) : (i += 1) {
        const m = skillMove(&s);
        if (!wellFormedMove(m)) fail("skill: Skill 20 emitted a malformed move '{s}'", .{m});
        det.add(m);
    }
    if (det.count != 1)
        fail("skill: Skill 20 is not deterministic ({d} distinct moves) -- the handicap is not disabled at max level", .{det.count});

    // (2) Skill 0 -> PRNG active -> varies (>= 2 distinct), every move legal.
    s.send("setoption name Skill Level value 0\n");
    var live: MoveSet = .{};
    i = 0;
    while (i < skill_live_runs) : (i += 1) {
        const m = skillMove(&s);
        if (!wellFormedMove(m)) fail("skill: Skill 0 emitted a malformed move '{s}'", .{m});
        live.add(m);
    }
    _ = s.finish();
    if (live.count < 2)
        fail("skill: Skill 0 produced no move variance ({d} distinct in {d} runs) -- the move-bias PRNG is dead", .{ live.count, skill_live_runs });

    std.debug.print("skill: OK (Skill 20 deterministic 1 move; Skill 0 random {d} distinct in {d}, all legal)\n", .{ live.count, skill_live_runs });
    std.process.exit(0);
}

// ponder: exercise the ponder handshake (N-time). `go ... ponder` searches the expected reply without
// the clock; `ponderhit` (opponent played it) converts to a timed search that must yield a
// bestmove; `stop` (opponent played otherwise) must also yield the best-so-far. Both must emit a
// well-formed, LEGAL move and the process must exit cleanly. Liveness + legality, not a snapshot
// (the timing/exact move is wall-clock-dependent). Drive the interactive session like `stress`.

// Copy the first `bestmove M [ponder P]` in `seg` into the caller's fixed buffers. Return
// false if the segment has no bestmove line.
fn firstBestmove(seg: []const u8, bm: []u8, bm_len: *usize, pd: []u8, pd_len: *usize) bool {
    var li = lines(seg);
    while (li.next()) |raw| {
        const line = trimCR(raw);
        if (parseBestmove(line)) |b| {
            const n = @min(b.bestmove.len, bm.len);
            @memcpy(bm[0..n], b.bestmove[0..n]);
            bm_len.* = n;
            const m = @min(b.ponder.len, pd.len);
            @memcpy(pd[0..m], b.ponder[0..m]);
            pd_len.* = m;
            return true;
        }
    }
    return false;
}

// Report whether `move` is in the legal-move list of `position` (a "position ..." command). Use
// `go perft 1`, whose divide lines ("<move>: <count>") enumerate exactly the legal moves.
fn ponderMoveLegal(gpa: std.mem.Allocator, io: Io, bin: []const u8, position: []const u8, move: []const u8) bool {
    const input = std.fmt.allocPrint(gpa, "{s}\ngo perft 1\nquit\n", .{position}) catch return false;
    defer gpa.free(input);
    var cap = runEngine(gpa, io, bin, &.{}, input) catch return false;
    defer cap.deinit(gpa);
    var li = lines(cap.stdout);
    while (li.next()) |line| {
        if (isDivideLine(line)) {
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (std.mem.eql(u8, line[0..colon], move)) return true;
        }
    }
    return false;
}

pub fn runPonder(gpa: std.mem.Allocator, io: Io, bin: []const u8) noreturn {
    var s: Interactive = undefined;
    s.init(io, gpa, bin) catch fail("ponder: spawn failed", .{});
    s.send("setoption name Ponder value true\n");

    // 1. bestmove X ponder Y from startpos (the move to play + the expected reply to ponder).
    var xb: [8]u8 = undefined;
    var xl: usize = 0;
    var yb: [8]u8 = undefined;
    var yl: usize = 0;
    {
        const mark = s.buffered().len;
        s.send("position startpos\ngo depth 10\n");
        _ = s.fillUntil("\nbestmove");
        if (!firstBestmove(s.buffered()[mark..], &xb, &xl, &yb, &yl) or yl == 0)
            fail("ponder: startpos search gave no 'bestmove X ponder Y'", .{});
    }
    const x = xb[0..xl];
    const y = yb[0..yl];

    // 2. ponderhit path: ponder the reply, then ponderhit -> a timed search must emit bestmove Z.
    var zb: [8]u8 = undefined;
    var zl: usize = 0;
    var zpd: [8]u8 = undefined;
    var zpl: usize = 0;
    {
        var cmdbuf: [96]u8 = undefined;
        const mark = s.buffered().len;
        s.send(std.fmt.bufPrint(&cmdbuf, "position startpos moves {s} {s}\ngo wtime 3000 btime 3000 ponder\n", .{ x, y }) catch fail("gate_state: command buffer too small for the case table", .{}));
        if (!s.fillUntil("\ninfo depth")) fail("ponder: ponder search never started (no info)", .{});
        s.send("ponderhit\n");
        if (!s.fillUntil("\nbestmove")) fail("ponder: ponderhit produced no bestmove (hang?)", .{});
        if (!firstBestmove(s.buffered()[mark..], &zb, &zl, &zpd, &zpl)) fail("ponder: could not parse the ponderhit bestmove", .{});
    }

    // 3. stop path: ponder, then stop (opponent deviated) -> the best-so-far must be emitted.
    var wb: [8]u8 = undefined;
    var wl: usize = 0;
    var wpd: [8]u8 = undefined;
    var wpl: usize = 0;
    {
        const mark = s.buffered().len;
        s.send("position startpos moves e2e4\ngo wtime 3000 btime 3000 ponder\n");
        if (!s.fillUntil("\ninfo depth")) fail("ponder: stop-path ponder never started", .{});
        s.send("stop\n");
        if (!s.fillUntil("\nbestmove")) fail("ponder: stop produced no bestmove", .{});
        if (!firstBestmove(s.buffered()[mark..], &wb, &wl, &wpd, &wpl)) fail("ponder: could not parse the stop bestmove", .{});
    }

    const clean = s.finish();
    if (!clean) fail("ponder: engine did not exit cleanly after the handshake", .{});

    // 4. both results must be well-formed AND legal in their position.
    const z = zb[0..zl];
    const w = wb[0..wl];
    if (!wellFormedMove(z)) fail("ponder: ponderhit bestmove '{s}' is malformed", .{z});
    if (!wellFormedMove(w)) fail("ponder: stop bestmove '{s}' is malformed", .{w});
    var posbuf: [96]u8 = undefined;
    const pos_xy = std.fmt.bufPrint(&posbuf, "position startpos moves {s} {s}", .{ x, y }) catch fail("gate_state: command buffer too small for the case table", .{});
    if (!ponderMoveLegal(gpa, io, bin, pos_xy, z)) fail("ponder: ponderhit move '{s}' is illegal after {s} {s}", .{ z, x, y });
    if (!ponderMoveLegal(gpa, io, bin, "position startpos moves e2e4", w)) fail("ponder: stop move '{s}' is illegal after e2e4", .{w});

    std.debug.print("ponder: OK (bestmove {s} ponder {s}; ponderhit -> {s} legal; stop -> {s} legal; clean exit)\n", .{ x, y, z, w });
    std.process.exit(0);
}
