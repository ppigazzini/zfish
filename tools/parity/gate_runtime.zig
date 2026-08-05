//! Run the gates that need real concurrency and a real wall clock: the multi-thread score
//! band, the go/stop storm, the time-management budgets, and the bench signature.
//!
//! These decide pass or fail themselves (`noreturn`) rather than returning a fingerprint --
//! a thread count and a clock are not byte-comparable, so each asserts a PROPERTY. They are
//! the only gates that exercise the sync primitives and the ported steady clock at all; the
//! single-threaded goldens cannot reach either.

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

const MtPos = struct { name: []const u8, cmds: []const u8 };
const mt_positions = [_]MtPos{
    .{ .name = "startpos", .cmds = "position startpos" },
    .{ .name = "open", .cmds = "position startpos moves e2e4 e7e5 g1f3 b8c6 f1b5 a7a6" },
    .{ .name = "endgame", .cmds = "position fen 8/5k2/4p3/4P3/5K2/8/8/8 w - - 0 1" },
    .{ .name = "queens", .cmds = "position startpos moves d2d4 d7d5 c2c4 e7e6 b1c3 g8f6" },
};
const mt_depth = 12;
const mt_band = 150;

// mt-sanity: run a two-layer TT/search gate. (1) A bit-exact single-thread RE-ANCHOR: Threads=1
// must reproduce the golden's score+nodes+bestmove EXACTLY (depth-limited, so deterministic)
// -- an exact floor that catches a single-thread regression the band would mask. (2) The
// non-deterministic Lazy-SMP band: Threads {2,4} must complete with a well-formed bestmove and
// a score of the same kind/sign and within BAND cp of that single-thread reference -- catching
// garbled result aggregation (wrong voting, dropped PV, sign flips) that no snapshot can.
pub fn runMtSanity(gpa: std.mem.Allocator, io: Io, bin: []const u8, golden: []const u8, mode: []const u8) noreturn {
    if (std.mem.eql(u8, mode, "update")) {
        var out: std.ArrayList(u8) = .empty;
        for (mt_positions) |p| {
            const cmds = std.fmt.allocPrint(gpa, "setoption name Threads value 1\n{s}\ngo depth {d}\n", .{ p.cmds, mt_depth }) catch fail("mt-sanity: oom", .{});
            defer gpa.free(cmds);
            const o = runSearch(io, gpa, bin, cmds) catch fail("mt-sanity: engine run failed", .{});
            if (!o.got_bestmove) fail("mt-sanity: {s} single-thread produced no bestmove", .{p.name});
            const kind = if (o.kind == .mate) "mate" else "cp";
            out.print(gpa, "{s:<10} score {s} {d} nodes {?d} bestmove {s}\n", .{ p.name, kind, o.val, o.nodes, o.bestmove() }) catch fail("mt-sanity: oom", .{});
        }
        Io.Dir.cwd().writeFile(io, .{ .sub_path = golden, .data = out.items }) catch fail("mt-sanity: cannot write {s}", .{golden});
        std.debug.print("mt-sanity: wrote golden ({d} positions, depth {d})\n", .{ mt_positions.len, mt_depth });
        std.process.exit(0);
    }

    const raw_golden = Io.Dir.cwd().readFileAlloc(io, golden, gpa, .unlimited) catch
        fail("mt-sanity: golden missing: {s} (run update first)", .{golden});
    defer gpa.free(raw_golden);

    for (mt_positions) |p| {
        // Find this position's single-thread reference score in the golden.
        var ref = Outcome{};
        var found = false;
        var gl = lines(raw_golden);
        while (gl.next()) |line_raw| {
            const line = trimCR(line_raw);
            var toks = std.mem.tokenizeScalar(u8, line, ' ');
            const name = toks.next() orelse continue;
            if (!std.mem.eql(u8, name, p.name)) continue;
            scanInfo(&ref, line);
            found = true;
            break;
        }
        if (!found or ref.kind == .none) fail("mt-sanity: golden has no score for {s} (regenerate)", .{p.name});

        // Bit-exact single-thread RE-ANCHOR: Threads=1 must reproduce the golden EXACTLY
        // (score kind+value, node count, bestmove). go depth 12 is depth-limited, so it is
        // bit-exact like bench (arch/OS/build-mode-invariant). A single-thread regression that
        // still lands inside the multi-thread band below would slip past the band check; this
        // exact floor under the band catches it.
        {
            const cmds1 = std.fmt.allocPrint(gpa, "setoption name Threads value 1\n{s}\ngo depth {d}\n", .{ p.cmds, mt_depth }) catch fail("mt-sanity: oom", .{});
            defer gpa.free(cmds1);
            const o1 = runSearch(io, gpa, bin, cmds1) catch fail("mt-sanity: engine run failed", .{});
            if (o1.kind != ref.kind or o1.val != ref.val or !optEql(o1.nodes, ref.nodes) or !std.mem.eql(u8, o1.bestmove(), ref.bestmove()))
                fail("mt-sanity: {s} Threads=1 does not reproduce the golden ({s} {d} nodes {?d} bm {s} vs golden {s} {d} nodes {?d} bm {s}) -- single-thread regression", .{ p.name, @tagName(o1.kind), o1.val, o1.nodes, o1.bestmove(), @tagName(ref.kind), ref.val, ref.nodes, ref.bestmove() });
        }

        for ([_]u8{ 2, 4 }) |tc| {
            const cmds = std.fmt.allocPrint(gpa, "setoption name Threads value {d}\n{s}\ngo depth {d}\n", .{ tc, p.cmds, mt_depth }) catch fail("mt-sanity: oom", .{});
            defer gpa.free(cmds);
            const o = runSearch(io, gpa, bin, cmds) catch fail("mt-sanity: engine run failed", .{});
            if (!o.got_bestmove or !wellFormedMove(o.bestmove())) fail("mt-sanity: {s} Threads={d}: no/garbled bestmove", .{ p.name, tc });
            if (o.kind == .none) fail("mt-sanity: {s} Threads={d}: no score emitted", .{ p.name, tc });
            if (o.kind != ref.kind) fail("mt-sanity: {s} Threads={d}: score kind differs from single-thread", .{ p.name, tc });
            if (ref.kind == .mate) {
                if ((ref.val < 0) != (o.val < 0)) fail("mt-sanity: {s} Threads={d}: mate sign flipped ({d} vs {d})", .{ p.name, tc, o.val, ref.val });
            } else {
                const diff = if (o.val > ref.val) o.val - ref.val else ref.val - o.val;
                if (diff > mt_band) fail("mt-sanity: {s} Threads={d}: cp {d} vs st {d} exceeds band {d}", .{ p.name, tc, o.val, ref.val, mt_band });
            }
        }
    }
    std.debug.print("mt-sanity: OK ({d} positions, Threads=1 reproduces golden bit-exact + Threads {{2,4}} within band {d}, depth {d})\n", .{ mt_positions.len, mt_band, mt_depth });
    std.process.exit(0);
}

const stress_cycles = 24;
const stress_churn = 12;

// stress: assert liveness for the thread runtime. In Phase A, hammer ONE process with
// go/stop cycles across thread counts {1,2,4,8} (a third use the go-infinite -> stop handshake,
// which exercises the futex/RtlWaitOnAddress/__ulock wakeup); in Phase B, churn fresh engine graphs.
// A hang trips the CI job timeout; every search must yield a well-formed bestmove and every
// process must exit cleanly. Not a determinism gate.
pub fn runStress(gpa: std.mem.Allocator, io: Io, bin: []const u8) noreturn {
    const threads = [_]u8{ 1, 2, 4, 8 };
    std.debug.print("stress: phase A -- {d} go/stop cycles across threads {{1,2,4,8}}\n", .{stress_cycles});

    var s: Interactive = undefined;
    s.init(io, gpa, bin) catch fail("stress: spawn failed", .{});
    // No uciok/readyok barriers: those protocol replies go to stderr (discarded here), and
    // the engine processes commands in order regardless. Synchronize on the stdout markers
    // the search itself emits -- `info depth` (spun up) and `bestmove` (done).
    s.send("setoption name Hash value 16\n");
    var buf: [128]u8 = undefined;
    for (0..stress_cycles) |i| {
        const tc = threads[i % threads.len];
        s.send(std.fmt.bufPrint(&buf, "setoption name Threads value {d}\nucinewgame\n", .{tc}) catch fail("gate_runtime: command buffer too small for the case table", .{}));
        if (i % 3 == 0) {
            // stop-handshake path: start an unbounded search, wait for it to actually spin up,
            // then stop -- this is what exercises the sync-primitive wakeup under contention.
            s.send("position startpos\ngo infinite\n");
            if (!s.fillUntil("\ninfo depth")) fail("stress: phase A cycle {d} -- infinite search never started", .{i});
            s.send("stop\n");
        } else {
            s.send("position startpos moves e2e4 e7e5\ngo depth 10\n");
        }
        // Use the cursor to wait for THIS cycle's bestmove (not an earlier one).
        if (!s.fillUntil("\nbestmove")) fail("stress: phase A cycle {d} -- no bestmove (lost search?)", .{i});
    }
    const got = std.mem.count(u8, s.buffered(), "\nbestmove");
    const clean = s.finish();
    if (!clean) fail("stress: phase A process did not exit cleanly (crash/abort)", .{});
    if (got != stress_cycles) fail("stress: phase A produced {d} bestmoves, expected {d}", .{ got, stress_cycles });

    std.debug.print("stress: phase B -- {d} construct/destroy iterations\n", .{stress_churn});
    for (0..stress_churn) |j| {
        const tc = threads[j % threads.len];
        const cmds = std.fmt.bufPrint(&buf, "setoption name Threads value {d}\nucinewgame\nposition startpos\ngo depth 8\n", .{tc}) catch fail("gate_runtime: command buffer too small for the case table", .{});
        const o = runSearch(io, gpa, bin, cmds) catch fail("stress: phase B iter {d} spawn/run failed", .{j});
        if (!o.got_bestmove) fail("stress: phase B iter {d} (Threads={d}) produced no bestmove", .{ j, tc });
        if (!o.exited_clean) fail("stress: phase B iter {d} (Threads={d}) did not exit cleanly", .{ j, tc });
    }
    std.debug.print("stress: OK (phase A {d} cycles + phase B {d} churns, no hang/crash)\n", .{ stress_cycles, stress_churn });
    std.process.exit(0);
}

// async: assert the two interrupted-search invariants nothing else in this battery reaches.
//
// NO GOLDEN CAN COVER THIS PATH. A command that lands inside a running search ends it
// wherever the clock got to, so the final `info` line's node count moves run to run and
// there is no value to photograph. These are properties of the UCI contract instead --
// which is also why they carry no expectation authored here: the legal move list below is
// read out of the engine's own `go perft 1`, and reading anything but the start position's
// 20 root moves is a rig fault rather than a verdict.
//
// Two of the four ways a search is interrupted ARE already gated, and are deliberately not
// repeated here: `stop` ending a live search is `parity-stress` phase A (a third of its 24
// cycles are go-infinite -> stop), and `ponderhit` / `stop` during a ponder is
// `parity-ponder`, which also checks the move it yields is legal. The other two had never
// been driven at all.
//
// NO WATCHDOG, deliberately, for session.zig's reason: a deadline turns a slow runner into
// a red gate, and a flaky gate is not evidence. An engine that ignores `quit` wedges here
// until the CI job's own timeout, exactly as everywhere else in this battery -- the hang is
// attributed from the other side, by `parity-stress`.
pub fn runAsync(gpa: std.mem.Allocator, io: Io, bin: []const u8) noreturn {
    // 1. A `stop` with NO search running answers nothing, and leaves the engine up.
    //
    // The stray stop is the FIRST command of the session, so the engine is provably idle
    // when it arrives, and the UCI loop reads commands in order: any answer it made must
    // therefore already be on stdout by the time the search below reports a depth. That
    // makes the count at THAT moment the assertion, with no timing in it.
    var s: Interactive = undefined;
    s.init(io, gpa, bin) catch fail("async: spawn failed", .{});
    s.send("stop\n");
    s.send("position startpos\ngo depth 8\n");
    if (!s.fillUntil("\ninfo depth"))
        fail("async: no search started after a stray `stop` -- the engine did not stay up", .{});
    const stray = std.mem.count(u8, s.buffered(), "bestmove");
    if (stray != 0)
        fail("async: a `stop` with no search running answered with {d} bestmove line(s)", .{stray});

    if (!s.fillUntil("\nbestmove"))
        fail("async: the search after a stray `stop` produced no bestmove", .{});
    var bm: [8]u8 = undefined;
    var bm_len: usize = 0;
    var pd: [8]u8 = undefined;
    var pd_len: usize = 0;
    if (!firstBestmove(s.buffered(), &bm, &bm_len, &pd, &pd_len))
        fail("async: could not parse the bestmove after a stray `stop`", .{});
    const idle_move = bm[0..bm_len];
    if (!wellFormedMove(idle_move))
        fail("async: malformed bestmove '{s}' after a stray `stop`", .{idle_move});
    if (!s.finish())
        fail("async: the engine did not exit cleanly after a stray `stop` + a search", .{});
    if (!moveIsLegal(gpa, io, bin, "position startpos", idle_move))
        fail("async: bestmove '{s}' after a stray `stop` is not legal from the start position", .{idle_move});

    // 2. A `quit` arriving INSIDE an unbounded search exits, and exits cleanly.
    //
    // `finish()` sends the quit, drains stdout to EOF and reaps, so a clean exit here is
    // exit code 0 and not a signal -- the failure this catches is a process that dies on
    // the way out, or one that never leaves. Nothing is asserted about a bestmove: whether
    // the interrupted search emits one on the way down is upstream's business, not an
    // invariant of the contract, and pinning it would be an expectation authored here.
    var q: Interactive = undefined;
    q.init(io, gpa, bin) catch fail("async: spawn failed for the quit-during-search case", .{});
    q.send("position startpos\ngo infinite\n");
    if (!q.fillUntil("\ninfo depth"))
        fail("async: the infinite search never started, so `quit` would not have landed inside one", .{});
    if (!q.finish())
        fail("async: `quit` during a running infinite search did not exit cleanly (signal or non-zero)", .{});

    std.debug.print("async: OK (2 of 2 invariants: a stray `stop` answers nothing and stays up -> {s}; `quit` inside an infinite search exits clean)\n", .{idle_move});
    std.process.exit(0);
}

// Report whether `move` is in the legal-move list of `position` (a "position ..." command),
// read from the engine's own `go perft 1` -- whose divide lines ("<move>: <count>") enumerate
// exactly the legal moves. The gate then holds no move list of its own to go stale.
fn moveIsLegal(gpa: std.mem.Allocator, io: Io, bin: []const u8, position: []const u8, move: []const u8) bool {
    const input = std.fmt.allocPrint(gpa, "{s}\ngo perft 1\nquit\n", .{position}) catch return false;
    defer gpa.free(input);
    var cap = runEngine(gpa, io, bin, &.{}, input) catch return false;
    defer cap.deinit(gpa);
    var li = lines(cap.stdout);
    while (li.next()) |raw| {
        const line = trimCR(raw);
        if (isDivideLine(line)) {
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (std.mem.eql(u8, line[0..colon], move)) return true;
        }
    }
    return false;
}

// Copy the move and ponder tokens out of the first `bestmove` line in `seg`.
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

// time-mgmt: assert wall-clock invariants no depth/node gate covers (the startTime=0 class of bug).
// BAND: `go movetime T` reports elapsed within [T/3, 3T+1500]. SCALE: it grows with the
// budget. ALLOC: `go wtime/btime` picks a sane sub-budget. Exercise the ported steady
// clock directly (QueryPerformanceCounter on Windows, CLOCK_MONOTONIC on POSIX).
pub fn runTimeMgmt(gpa: std.mem.Allocator, io: Io, bin: []const u8) noreturn {
    var reported: [2]i64 = .{ 0, 0 };
    const budgets = [_]i64{ 300, 900 };
    for (budgets, 0..) |t, idx| {
        var cmdbuf: [64]u8 = undefined;
        const cmds = std.fmt.bufPrint(&cmdbuf, "position startpos\ngo movetime {d}\n", .{t}) catch fail("gate_runtime: command buffer too small for the case table", .{});
        const o = runSearch(io, gpa, bin, cmds) catch fail("time-mgmt: engine run failed", .{});
        if (!o.got_bestmove or !wellFormedMove(o.bestmove())) fail("time-mgmt: movetime {d}: no legal bestmove", .{t});
        const n = o.time_ms orelse fail("time-mgmt: movetime {d}: engine reported no 'time' field", .{t});
        const lo = @divTrunc(t, 3);
        const hi = 3 * t + 1500;
        if (n < lo or n > hi) fail("time-mgmt: movetime {d}: reported {d}ms outside [{d},{d}] -- startTime/clock regression", .{ t, n, lo, hi });
        reported[idx] = n;
        std.debug.print("time-mgmt: movetime {d} -> reported {d}ms, bestmove ok\n", .{ t, n });
    }
    if (reported[1] - reported[0] < 200) fail("time-mgmt: reported time does not scale with budget (300->{d}, 900->{d}) -- frozen clock", .{ reported[0], reported[1] });

    const o = runSearch(io, gpa, bin, "position startpos\ngo wtime 3000 btime 3000\n") catch fail("time-mgmt: engine run failed", .{});
    if (!o.got_bestmove or !wellFormedMove(o.bestmove())) fail("time-mgmt: wtime/btime: no legal bestmove", .{});
    const w = o.time_ms orelse fail("time-mgmt: wtime/btime: engine reported no 'time' field", .{});
    if (w < 1 or w > 3000) fail("time-mgmt: wtime/btime: allocated {d}ms outside (0,3000] -- allocation regression", .{w});
    std.debug.print("time-mgmt: wtime/btime 3000 -> allocated {d}ms, bestmove ok\n", .{w});
    std.debug.print("time-mgmt: OK (movetime band+scale, wtime allocation)\n", .{});
    std.process.exit(0);
}

// Assert bench reports the node count the caller was given. The eval is integer-exact, so
// the count is arch- and OS-invariant; build.zig owns the reference, never a comment here.
pub fn runSignature(gpa: std.mem.Allocator, io: Io, bin: []const u8, expected: []const u8) noreturn {
    var cap = runEngine(gpa, io, bin, &.{"bench"}, null) catch fail("signature: engine run failed", .{});
    defer cap.deinit(gpa);
    var li = lines(cap.stderr);
    while (li.next()) |line| {
        if (startsWith(line, "Nodes searched")) {
            var toks = std.mem.tokenizeScalar(u8, line, ' ');
            var last: []const u8 = "";
            while (toks.next()) |t| last = t;
            if (std.mem.eql(u8, last, expected)) {
                std.debug.print("signature: OK -- bench == {s}\n", .{expected});
                std.process.exit(0);
            }
            std.debug.print("signature: FAIL -- bench {s} != {s}\n", .{ last, expected });
            std.process.exit(1);
        }
    }
    fail("signature: no 'Nodes searched' line (crash?)", .{});
}
