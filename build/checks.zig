//! Own the liveness and metamorphic gates -- the ones with no golden to diff.
//!
//! Ten checks that assert a PROPERTY rather than a fingerprint: the runtime does not hang
//! under go/stop storms, a reset restores state, Skill Level 0 stays legal, a truncated FEN
//! still sets, an interrupted search still honours the protocol. They pass "-" where a golden
//! gate passes a file, because there is nothing to photograph -- the harness decides pass/fail
//! itself.
//!
//! Same table+loop treatment as build/gates.zig, and they are MORE uniform than the golden
//! gates were: one harness call, one step, no tablebase fetch, no per-gate argument. Every
//! one is in both aggregates today; the flags are kept per row so that stays a data change.

const std = @import("std");
const gates = @import("gates.zig");

pub const Check = struct {
    /// Name the parity harness dispatches on.
    check: []const u8,
    /// Build step a human types.
    step: []const u8,
    desc: []const u8,
    in_parity: bool = true,
    in_portable: bool = true,
};

pub const checks = [_]Check{
    // Stress the thread runtime for liveness.
    // Hammer (ucinewgame -> setoption Threads -> go/stop) cycles across thread
    // counts + a construct/destroy churn, under a wall-clock watchdog. Gate on liveness
    // (no hang / crash / lost search), not determinism. Keep it out
    // of the core `parity` aggregate (slower, wall-clock-timed); run explicitly
    // for any thread-runtime slice.
    .{ .check = "stress", .step = "parity-stress", .desc = "Thread-runtime stress/liveness: go/stop storms + construct/destroy churn" },
    // Check wall-clock time-management sanity: the ONLY gate over `go
    // movetime` / `go wtime` / TimeManagement.startTime -- the whole rest of the
    // battery is depth/node-limited and never consults the clock, which is how the
    // startTime=0 bug (fbcefd0d6) shipped. Base it on invariants (no golden): reported
    // elapsed must track the movetime budget and scale with it. Keep it its own step
    // (like parity-mt) since it is non-deterministic and sleep-paced, outside the core
    // deterministic `parity` aggregate; the CI workflow runs it explicitly.
    .{ .check = "time-mgmt", .step = "parity-time", .desc = "Wall-clock time management: go movetime/wtime budget + clock-scaling invariants" },
    // Gate metamorphic TT/history reset (reset-determinism; no golden -- assert internal
    // relations in one process): a second no-reset search reuses the TT (node count changes),
    // Clear Hash removes that reuse, and ucinewgame restores the exact clean search (no stale
    // state bleed). Single-thread deterministic, so it joins the portable aggregate.
    .{ .check = "reset-determinism", .step = "parity-reset", .desc = "Metamorphic TT/history reset: ucinewgame + Clear Hash restore state, TT reuse is live" },
    // Gate the metamorphic Skill Level (skill; no golden -- the path is RNG-seeded). Skill 20 is
    // deterministic (handicap off -> one move), Skill 0 varies (>= 2 distinct, all legal). The
    // PRNG persists per process, so K searches in one process give robust variance (measured
    // min 3 over 25 seeds). Single-thread, relations are platform-agnostic, so it joins the
    // portable aggregate.
    .{ .check = "skill", .step = "parity-skill", .desc = "Metamorphic Skill Level gate: Skill 20 deterministic, Skill 0 random + legal" },
    // Drive consecutive `go` with NO intervening `position` (repeat-go; no golden -- liveness).
    // Upstream guards the setup-state transfer, so the pool reuses the list it already owns;
    // zfish freed it and stored null, and the second `go` panicked in the shipped binary. Every
    // other gate re-sends `position` before each `go`, so none of them could see it.
    .{ .check = "repeat-go", .step = "parity-repeat-go", .desc = "Repeated `go` with no intervening `position` yields a bestmove each time, clean exit" },
    // Assert a FEN missing trailing fields SETS with upstream's defaults (fen-truncated; literal
    // expectations, no golden -- a golden here could be regenerated green over the defect).
    .{ .check = "fen-truncated", .step = "parity-fen-truncated", .desc = "A FEN missing trailing fields sets with upstream's defaults instead of failing" },
    // Assert `flip` re-parses the board under ITS OWN chess960 variant, not the live option
    // (flip-chess960; literal expectations verified against the oracle, no golden).
    .{ .check = "flip-chess960", .step = "parity-flip-chess960", .desc = "`flip` keeps the board's own chess960 variant when UCI_Chess960 is toggled" },
    // Exercise the ponder handshake (ponder; no golden -- N-time). `go ... ponder` then `ponderhit` must
    // emit a legal bestmove, `stop` during ponder must emit the best-so-far, and the process must
    // exit cleanly. Liveness + legality, platform-agnostic, so it joins the portable aggregate.
    .{ .check = "ponder", .step = "parity-ponder", .desc = "Ponder handshake: go ponder -> ponderhit/stop yields a legal bestmove, clean exit" },
    // Exercise the binary WITHOUT the net beside it -- the ONLY gate that does (net-missing).
    // Every other gate here runs with cwd=resources/ (addHarnessRun's setCwd), which hands the
    // engine the very precondition it must check -- so a startup that dies without a net
    // is invisible to all of them, and did ship that way. The harness spawns the child in
    // a scratch subdir holding no net and asserts a named diagnostic + a clean non-zero
    // exit, never a signal. Startup contract only, no search: portable, so it joins the
    // portable aggregate.
    .{ .check = "net-missing", .step = "parity-net-missing", .desc = "Missing-net startup: a named diagnostic + clean non-zero exit, never a signal" },
    // Assert the interrupted-search invariants no golden can cover (async; a command landing
    // inside a running search ends it wherever the clock got to, so there is no node count to
    // pin). A `stop` with nothing running must answer nothing and leave the engine up, and a
    // `quit` inside an unbounded search must exit cleanly. Every other gate here reaches the
    // interrupted path only where the command arrives too late to do anything. Liveness +
    // legality, platform-agnostic, so it joins the portable aggregate.
    .{ .check = "async", .step = "parity-async", .desc = "Interrupted-search invariants: a stray `stop` answers nothing, `quit` inside a search exits clean" },
};

pub const Context = struct {
    b: *std.Build,
    harness: *std.Build.Step.Compile,
    stockfish: *std.Build.Step.Compile,
    install_step: *std.Build.Step,
    net_step: *std.Build.Step,
};

/// Register each check's step; return check-name -> run for the aggregates to wire.
pub fn register(ctx: Context) std.StringHashMap(*std.Build.Step.Run) {
    var runs = std.StringHashMap(*std.Build.Step.Run).init(ctx.b.allocator);
    for (checks) |c| {
        // "-" stands in for the golden path: these gates carry their verdict in the harness,
        // so there is no file to diff and nothing to regenerate -- hence no update step.
        const cmd = gates.addHarnessRun(ctx.b, ctx.harness, ctx.stockfish, ctx.install_step, ctx.net_step, c.check, "-", "check");
        const step = ctx.b.step(c.step, c.desc);
        step.dependOn(&cmd.step);
        runs.put(c.check, cmd) catch @panic("OOM registering checks");
    }
    return runs;
}
