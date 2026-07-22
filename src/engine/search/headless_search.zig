//! Run a headless single-worker shallow search.
//!
//! In production the platform ThreadPool constructs each Worker and `startThinking`
//! populates its root state before the engine-zone `search_driver.iterativeDeepening`
//! runs. That left the engine with no way to run one depth-capped search on one position
//! without the platform thread orchestrator -- the "search one position at depth N"
//! entry this module supplies. Stay pure engine-zone: build a single Worker plus a
//! one-thread ThreadPool, a SearchManager, a small TT, and a SharedHistories, then drive
//! `iterativeDeepening` directly. Every DI seam (option/output/time/tb) self-defaults
//! headless, so nothing needs installing; set the one seam, a deterministic option
//! source (Skill off, MultiPV 1) so a bounded search is reproducible.
//!
//! Run one search at a time (single-threaded): the heavy blocks are process-static and reused
//! across calls. Load the net (`network.load`) before calling.

const std = @import("std");
const worker_layout = @import("worker_layout");
const worker_construct = @import("worker_construct");
const search_driver = @import("search_driver");
const root_move_build = @import("root_move_build");
const network = @import("network");
const movegen = @import("movegen");
const position = @import("position");
const option_source = @import("option_source");
const nnue_acc = @import("nnue_accumulator");
const page_alloc = @import("page_alloc");
const tt_types = @import("tt_types");

const WorkerLayout = worker_layout.WorkerLayout;

pub const Result = struct {
    best_move: u16,
    score: i32,
    nodes: u64,
};

// Hold the process-static search context (one search at a time). The ~4.5 MB Worker block is a
// BSS static; the small scaffolding structs sit beside it. All are referenced by the
// Worker via pointers, so they must outlive the search -- statics guarantee that.
var g_worker: [worker_layout.worker_size]u8 align(worker_layout.worker_align) = undefined;
var g_pool: worker_layout.ThreadPool = .{};
var g_thread: worker_layout.Thread = undefined;
var g_thread_addr: [1]*worker_layout.Thread = undefined;
var g_manager: worker_layout.SearchManager = .{};
var g_tt: worker_layout.TranspositionTable = .{};
var g_shared: search_driver.SharedHistories = undefined;
var g_ready = false;

// Provide a deterministic option source: Skill Level 20 turns skill mode OFF
// (skill_enabled = level < 20), MultiPV 1 keeps a single principal variation. Every
// other option reads 0, which is the correct headless default for a depth-only search.
fn deterministicIntByName(name: []const u8) i32 {
    if (std.mem.eql(u8, name, "Skill Level")) return 20;
    if (std.mem.eql(u8, name, "MultiPV")) return 1;
    return 0;
}

// Build the process-static context once. Return false when the net is not loaded or a
// TT / shared-histories allocation fails; the caller then treats the search as skipped.
fn ensureReady() bool {
    if (g_ready) return true;
    if (network.ftPtr() == null) return false;

    g_shared = search_driver.constructSharedHistories(1) catch return false;

    // Allocate the TT clusters directly through the page_alloc default (zeroed, 64-aligned,
    // no libc / huge pages). Bypass tt.resizeState because it clears in parallel over a
    // *ThreadPool; a fresh zeroed block needs no clear, and the store path only requires a
    // non-null table with cluster_count > 0.
    const tt_clusters: usize = 1 << 15; // ~1 MB of clusters; any positive count is valid
    const raw = page_alloc.alloc(tt_clusters * @sizeOf(tt_types.TtCluster)) orelse return false;
    g_tt.table = @ptrCast(@alignCast(raw));
    g_tt.cluster_count = tt_clusters;
    g_tt.generation8 = 0;

    // Build a one-thread pool whose sole Thread points at the Worker block.
    g_thread = .{ ._lo = 0, .worker = WorkerLayout.fromPtr(&g_worker) };
    g_thread_addr[0] = &g_thread;
    g_pool.threads = g_thread_addr[0..];

    // Construct the Worker: zero the block, wire the reference members, clear the
    // histories / reductions / refresh cache from the loaded net.
    worker_construct.constructFull(
        &g_worker,
        @intFromPtr(&g_shared), // shared_history
        @intFromPtr(&g_pool), // threads
        @intFromPtr(&g_tt), // tt
        @intFromPtr(&g_manager), // manager
        0, // thread_idx  (0 => main thread => the depth cap applies)
        0, // numa_thread_idx
        1, // numa_total
        0, // numa_access_token
    );

    option_source.intByName = &deterministicIntByName;
    g_ready = true;
    return true;
}

fn makeLimits(depth: i32) worker_layout.LimitsType {
    return .{
        .searchmoves = &.{},
        .time = .{ 0, 0 }, // {0,0} => use_time_management = 0 => no clock, depth cap governs
        .inc = .{ 0, 0 },
        .npmsec = 0,
        .movetime = 0,
        .start_time = 0,
        .movestogo = 0,
        .depth = depth,
        .mate = 0,
        .perft = 0,
        .infinite = 0,
        .nodes = 0,
        .ponder_mode = 0,
    };
}

fn resetManager() void {
    g_manager.resetBestPreviousScore();
    g_manager.resetBestPreviousAverageScore();
    g_manager.resetCallsCount();
    g_manager.resetPreviousTimeReduction();
    g_manager.resetOriginalTimeAdjust();
    g_manager.clearTimeman();
    g_manager.setPonder(false);
    g_manager.setStopOnPonderhit(false);
}

/// Search one position (given as a FEN) to a fixed depth, headless and single-threaded.
/// Return null when the net is not loaded, the FEN is illegal, or the root has no legal
/// move (mate/stalemate). Otherwise return the best root move, its score, and the node
/// count. Not reentrant (process-static Worker); one search at a time.
pub fn searchFen(fen: []const u8, chess960: u8, depth: i32) ?Result {
    if (!ensureReady()) return null;
    const wl = WorkerLayout.fromPtr(&g_worker);

    // Set the root position into the Worker's own root Position / StateInfo.
    if (position.setPosition(
        &wl.root_pos,
        fen.ptr,
        fen.len,
        chess960,
        &wl.root_state,
        worker_layout.position_size,
        worker_layout.state_info_size,
    )) |msg| {
        std.heap.c_allocator.free(std.mem.span(msg));
        return null; // illegal FEN
    }
    return searchCore(wl, fen, chess960, depth);
}

/// Search a live Position to a fixed depth, headless and single-threaded. Copy the position
/// into the Worker's own root slot as a fresh root (its StateInfo copied, the
/// `previous` chain cut -- the same shape a FEN-parsed root has, so repetition detection
/// starts clean). Return null on not-ready / no legal move. Not reentrant.
pub fn searchPosition(pos: *const position.Position, chess960: u8, depth: i32) ?Result {
    if (!ensureReady()) return null;
    const wl = WorkerLayout.fromPtr(&g_worker);
    wl.root_pos = pos.*;
    wl.root_state = pos.st.*;
    // Make a fresh root: no known pre-root history, exactly like a FEN-parsed root. Cut the
    // `previous` chain and zero plies_from_null / repetition -- otherwise the search's
    // repetition walk (min(rule50, plies_from_null) states back through `previous`) would run
    // off the truncated chain into the null root->previous and crash.
    wl.root_state.previous = null;
    wl.root_state.plies_from_null = 0;
    wl.root_state.repetition = 0;
    wl.root_pos.st = &wl.root_state; // repoint at the Worker's own StateInfo
    // Pass no FEN; buildRootMoves only reads root_fen on the TB-ranking path, which is
    // off headless (tb_source defaults to no tablebases), so "" is safe.
    return searchCore(wl, "", chess960, depth);
}

fn searchCore(wl: *WorkerLayout, root_fen: []const u8, chess960: u8, depth: i32) ?Result {
    // Build the root moves from the legal moves at the root (no `go searchmoves` filter).
    var legal: [256]u16 = undefined;
    const n = movegen.generateLegal(&wl.root_pos, &legal);
    if (n == 0) return null; // mate / stalemate -- nothing to search

    const built = root_move_build.buildRootMoves(
        std.heap.c_allocator,
        &wl.root_pos,
        root_fen,
        chess960,
        legal[0..n],
    ) catch return null;
    defer std.heap.c_allocator.free(built.root_moves);
    wl.root_moves = built.root_moves;

    // Reset the Worker per search, mirroring applyRootSetup + startThinking.
    const worker = worker_layout.Worker{ .base = wl };
    worker.resetRootSetupState();
    worker.setTbConfig(
        built.tb_config.cardinality,
        built.tb_config.root_in_tb != 0,
        built.tb_config.use_rule50 != 0,
        built.tb_config.probe_depth,
    );
    wl.limits = makeLimits(depth);
    wl.thread_idx = 0;
    g_pool.stop = 0;
    g_pool.increase_depth = 1;
    resetManager();

    // ssPrologue: reset the accumulator stack + clear the last-iteration PV.
    nnue_acc.stackReset(@ptrCast(&wl.accumulator_stack));
    wl.last_iteration_pv.length = 0;

    // Drive iterative deepening directly. thread_idx 0 makes it the main thread, so the
    // depth cap in the ID loop stops it; bypass the ThreadPool glue in
    // workerStartSearching (sibling start/wait, best-thread vote, bestmove emit).
    _ = search_driver.iterativeDeepening(wl);

    // Read the root moves, now sorted best-first after the search.
    const best = wl.root_moves[0];
    return .{
        .best_move = best.pv.moves[0],
        .score = best.score,
        .nodes = wl.nodes,
    };
}

test "headless search: startpos to a shallow depth yields a legal move + finite score" {
    position.initRuntime();
    // Load the net from the repo (cwd is the build root; "net/" reaches the default file).
    // Skip cleanly if the weights are unavailable in this environment.
    if (network.ftPtr() == null) {
        const dir = "net/";
        network.load(dir, dir.len, "", 0);
    }
    if (network.ftPtr() == null) return error.SkipZigTest; // net unavailable -> skip cleanly

    const start_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    const r = searchFen(start_fen, 0, 6) orelse return error.SearchReturnedNull;

    // Require the best move to be one of the 20 legal opening moves, and the score finite.
    var legal: [256]u16 = undefined;
    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    _ = position.setPosition(&p, start_fen, start_fen.len, 0, &st, worker_layout.position_size, worker_layout.state_info_size);
    const n = movegen.generateLegal(&p, &legal);
    var found = false;
    for (legal[0..n]) |m| {
        if (m == r.best_move) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expect(r.score > -32000 and r.score < 32000);
    try std.testing.expect(r.nodes > 0);

    // Require searchPosition on the same live board to agree that the move is legal + score finite.
    const r2 = searchPosition(&p, 0, 4) orelse return error.SearchReturnedNull;
    var found2 = false;
    for (legal[0..n]) |m| {
        if (m == r2.best_move) found2 = true;
    }
    try std.testing.expect(found2);
    try std.testing.expect(r2.score > -32000 and r2.score < 32000);
    try std.testing.expect(r2.nodes > 0);
}

// Stress searchPosition deterministically over diverse reached boards -- the same class
// the fuzz target explores, but in the always-run `zig build test` gate (RF+RS), so a
// setup regression that only bites non-startpos positions (e.g. the repetition-walk crash
// this originally caught: a fresh root must zero plies_from_null or the walk runs off the
// truncated `previous` chain) fails CI without needing `--fuzz`.
test "headless search: searchPosition over many random legal lines stays crash-free" {
    position.initRuntime();
    if (network.ftPtr() == null) {
        const dir = "net/";
        network.load(dir, dir.len, "", 0);
    }
    if (network.ftPtr() == null) return error.SkipZigTest;

    const start_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 500) : (iter += 1) {
        var p: position.Position align(64) = undefined;
        var st: position.StateInfo align(16) = undefined;
        _ = position.setPosition(&p, start_fen, start_fen.len, 0, &st, worker_layout.position_size, worker_layout.state_info_size);
        var chain: [24]position.StateInfo align(16) = undefined;
        const line_len = rand.intRangeAtMost(usize, 0, 24);
        var ply: usize = 0;
        while (ply < line_len) : (ply += 1) {
            var moves: [256]u16 = undefined;
            const cnt = movegen.generateLegal(&p, &moves);
            if (cnt == 0) break;
            const pick = moves[rand.uintLessThan(usize, cnt)];
            position.doMoveState(&p, pick, &chain[ply]);
        }
        const depth: i32 = @intCast(rand.intRangeAtMost(usize, 1, 4));
        _ = searchPosition(&p, 0, depth);
    }
}
