// Iterative-deepening orchestration helpers. The per-search worker-graph reads +
// time-management / thread-pool / skill / vote primitives the search root loop
// (workerStartSearching / iterativeDeepening, which stay in search_driver because
// they call the node recursion) drives. None of these touch the qsearch/search
// recursion, so they form a std-free leaf over the worker/board POD leaves + the
// option/timeman/tt/thread runtimes. The context types + shared worker
// accessors live in the search_ctx leaf both sides import.

const std = @import("std");
const worker_layout = @import("worker_layout");
const option_port = @import("option");
const timeman_port = @import("timeman");
const tt = @import("tt");
const search_thread = @import("search_thread");
const thread_vote = @import("thread_vote");
const nnue_acc = @import("nnue_accumulator");
const position_query = @import("position_query");
const time_source = @import("time_source");
const search_ctx = @import("search_ctx");

const SsCtx = search_ctx.SsCtx;
const ZfishIdState = search_ctx.ZfishIdState;
const RootMove = worker_layout.RootMove;

// Value bounds the ID loop's mate/TB checks read (search.h constants).
const q_value_inf: c_int = 32001;
const q_value_mate_in_max: c_int = 31754; // q_value_mate(32000) - q_max_ply(246)
const q_value_tb_win: c_int = 31507; // q_value_tb(31753) - q_max_ply(246)
pub const id_nodes_limit_output: u64 = 10_000_000;
const workerThreadsPool = search_ctx.workerThreadsPool;
const workerManager = search_ctx.workerManager;
const workerRootMove0 = search_ctx.workerRootMove0;
const workerTT = search_ctx.workerTT;
const sideToMove = position_query.sideToMove;
const gamePly = position_query.gamePly;

pub fn ssPrologue(wl: *worker_layout.WorkerLayout) void {
    nnue_acc.stackReset(@ptrCast(&wl.accumulator_stack));
    wl.last_iteration_pv.length = 0;
}

// Sum and reset each thread's worker bestMoveChanges (atomic u64), as a double.
pub fn searchIdCollectBmc(wl: *const worker_layout.WorkerLayout) f64 {
    const tp = wl.threads;
    const count = tp.numThreads();
    var tot: f64 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const wkr = tp.threadTyped(i).worker.?;
        const bmc = &wkr.best_move_changes;
        tot += @floatFromInt(bmc.*);
        bmc.* = 0;
    }
    return tot;
}

pub fn ssSetStop(wl: *const worker_layout.WorkerLayout) void {
    workerThreadsPool(wl).stop = 1;
}

// !threads.stop && (manager->ponder || limits.infinite).
pub fn ssShouldBusywait(wl: *const worker_layout.WorkerLayout) u8 {
    if (workerThreadsPool(wl).stop != 0) return 0;
    const ponder = workerManager(wl).?.ponder;
    const infinite = wl.limits.infinite;
    return if (ponder != 0 or infinite != 0) 1 else 0;
}

pub fn ssSetPrevScores(wl: *const worker_layout.WorkerLayout, best: *const worker_layout.WorkerLayout) void {
    const rmv = workerRootMove0(best);
    const sm = workerManager(wl).?;
    sm.best_previous_score = rmv.score;
    sm.best_previous_average_score = rmv.average_score;
}

pub fn optInt(name: []const u8) c_int {
    return option_port.intByName(name);
}

// Per-search context flags read off the worker graph + the OptionsModel.
pub fn ssContext(wl: *const worker_layout.WorkerLayout, out: *SsCtx) void {
    const limit_strength = optInt("UCI_LimitStrength") != 0;
    const uci_elo: c_int = if (limit_strength) optInt("UCI_Elo") else 0;
    const skill_level = optInt("Skill Level");
    const skill_enabled = uci_elo != 0 or skill_level < 20;

    out.is_mainthread = @intFromBool(wl.thread_idx == 0);
    out.root_moves_empty = @intFromBool(wl.root_moves.len == 0);
    out.npmsec = @intFromBool(wl.limits.npmsec != 0);
    out.limits_depth = wl.limits.depth;
    out.skill_enabled = @intFromBool(skill_enabled);
}

// Per-search TimeManagement init + TT new-search (main thread). Builds the timeman
// input from the worker's limits/rootPos + the manager's tm, reads nodestime/Move
// Overhead/Ponder from the OptionsModel, writes the outputs back, and bumps the TT
// generation.
pub fn ssTmInit(wl: *worker_layout.WorkerLayout) void {
    const lim = &wl.limits;
    const smgr = wl.manager.?;
    const tm = &smgr.tm;
    const root_pos = &wl.root_pos;

    const us: usize = sideToMove(root_pos);

    const input = timeman_port.TimemanInput{
        .time_us = lim.time[us],
        .inc_us = lim.inc[us],
        .start_time = lim.start_time,
        .npmsec = optInt("nodestime"),
        .move_overhead = optInt("Move Overhead"),
        .available_nodes = tm.available_nodes,
        .current_optimum_time = tm.optimum_time,
        .current_maximum_time = tm.maximum_time,
        .movestogo = lim.movestogo,
        .ply = gamePly(root_pos),
        .original_time_adjust = smgr.original_time_adjust,
        .ponder = @intFromBool(optInt("Ponder") != 0),
    };

    const out = timeman_port.init(input);

    tm.start_time = out.start_time;
    tm.optimum_time = out.optimum_time;
    tm.maximum_time = out.maximum_time;
    tm.available_nodes = out.available_nodes;
    tm.use_nodes_time = out.use_nodes_time;
    smgr.original_time_adjust = out.original_time_adjust;
    lim.time[us] = out.time_us;
    lim.inc[us] = out.inc_us;
    lim.npmsec = out.npmsec;

    const gen = &wl.tt.generation8;
    gen.* = tt.generationNext(gen.*);
}

// Skill level as a float: from UCI_Elo (interpolated) when UCI_LimitStrength is set,
// else the raw Skill Level option.
pub fn skillLevel() f64 {
    const limit_strength = optInt("UCI_LimitStrength") != 0;
    const uci_elo: c_int = if (limit_strength) optInt("UCI_Elo") else 0;
    if (uci_elo != 0) {
        const e = @as(f64, @floatFromInt(uci_elo - 1320)) / @as(f64, 3190 - 1320);
        const raw = (((37.2473 * e - 40.8525) * e + 22.2943) * e - 0.311438);
        return std.math.clamp(raw, 0.0, 19.0);
    }
    return @floatFromInt(optInt("Skill Level"));
}

// Snapshot the iterative-deepening state (worker/pool member pointers + scalars) for
// the search root loop. Graph reads + the OptionsModel only.
pub fn searchIdState(wl: *worker_layout.WorkerLayout, out: *ZfishIdState) void {
    const thread_idx = wl.thread_idx;
    const is_main = thread_idx == 0;
    const tp = wl.threads;

    out.root_pos = &wl.root_pos;
    out.root_moves = wl.root_moves.ptr;
    out.pv_idx = &wl.pv_idx;
    out.pv_last = &wl.pv_last;
    out.sel_depth = &wl.sel_depth;
    out.root_depth = &wl.root_depth;
    out.root_delta = &wl.root_delta;
    out.optimism = &wl.optimism;
    out.nodes = &wl.nodes;
    out.stop = &tp.stop;
    out.increase_depth = &tp.increase_depth;
    // wl.last_iteration_pv and ZfishIdState's field are the one canonical PVMoves,
    // so this is a plain mut->const coercion, no cast.
    out.last_iter_pv = &wl.last_iteration_pv;
    out.root_moves_count = wl.root_moves.len;
    out.thread_idx = thread_idx;
    out.threads_size = tp.numThreads();
    out.multipv_option = @intCast(@max(optInt("MultiPV"), 0));
    out.limits_depth = wl.limits.depth;
    out.limits_mate = wl.limits.mate;
    out.use_time_management = @intFromBool(wl.limits.time[0] != 0 or wl.limits.time[1] != 0);
    out.is_main = @intFromBool(is_main);

    const sl = skillLevel();
    out.skill_level = sl;
    out.skill_enabled = @intFromBool(sl < 20.0);

    if (is_main) {
        const smgr = wl.manager.?;
        out.stop_on_ponderhit = @ptrCast(&smgr.stop_on_ponderhit);
        out.ponder = @ptrCast(&smgr.ponder);
        out.iter_value = @ptrCast(&smgr.iter_value);
        out.previous_time_reduction = @ptrCast(&smgr.previous_time_reduction);
        out.tm_optimum = smgr.tm.optimum_time;
        out.tm_maximum = smgr.tm.maximum_time;
        out.tm_start_time = smgr.tm.start_time;
        out.tm_use_nodes_time = smgr.tm.use_nodes_time;
        out.best_previous_score = smgr.best_previous_score;
        out.best_previous_average_score = smgr.best_previous_average_score;
    } else {
        // Non-main threads bail before the time-management block (`if (!main_thread)
        // continue;`), so these SearchManager/TM pointer fields are never dereferenced
        // for them. position's ZfishIdState types them non-optional, so use the worker
        // pointer as a harmless valid placeholder (they are otherwise null/unused).
        out.stop_on_ponderhit = @ptrCast(wl);
        out.ponder = @ptrCast(wl);
        out.iter_value = @ptrCast(@alignCast(wl));
        out.previous_time_reduction = @ptrCast(@alignCast(wl));
        out.tm_optimum = 0;
        out.tm_maximum = 0;
        out.tm_start_time = 0;
        out.tm_use_nodes_time = 0;
        out.best_previous_score = 0;
        out.best_previous_average_score = 0;
    }
}

// Start / wait the sibling search threads.
pub fn ssThreadsStart(wl: *const worker_layout.WorkerLayout) void {
    search_thread.startPoolSiblings(wl.threads);
}
pub fn ssWaitFinished(wl: *const worker_layout.WorkerLayout) void {
    search_thread.waitPoolSiblings(wl.threads);
}

// Worker of the vote-winning thread (Lazy-SMP best-thread selection via the leaf
// thread_vote model).
pub fn ssGetBestThread(wl: *const worker_layout.WorkerLayout) ?*worker_layout.WorkerLayout {
    const pool = wl.threads;
    return thread_vote.bestThreadWorker(pool);
}

// nodestime available-nodes advance (tm.advance_nodes_time).
pub fn ssNpmsecAdvance(wl: *const worker_layout.WorkerLayout) void {
    const avail = &wl.manager.?.tm.available_nodes;
    const us: usize = sideToMove(&wl.root_pos);
    const inc = wl.limits.inc[us];
    const nodes: i64 = @intCast(worker_layout.poolNodesSearched(wl.threads));
    avail.* = @max(@as(i64, 0), avail.* - (nodes - inc));
}

// ---- ID-loop root-move / skill / mate helpers ----------------------
// Pure over RootMove / ZfishIdState + the value bounds above; the depth loop
// (iterativeDeepening, which stays in search_driver because it calls the node
// recursion) uses them via search_driver aliases.

pub inline fn idIsLoss(v: c_int) bool {
    return v <= -q_value_tb_win;
}
pub inline fn idIsMate(v: c_int) bool {
    return v >= q_value_mate_in_max;
}
pub inline fn idIsMated(v: c_int) bool {
    return v <= -q_value_mate_in_max;
}
// RootMove ordering: descending by (score, previousScore).
pub inline fn rootLess(a: *const RootMove, b: *const RootMove) bool {
    return if (a.score != b.score) a.score > b.score else a.previous_score > b.previous_score;
}
// Stable insertion sort over root_moves[lo, hi): a stable sort by the RootMove
// ordering (equal elements keep their relative order).
pub fn stableSortRoot(rm: [*]RootMove, lo: usize, hi: usize) void {
    if (hi <= lo) return;
    var i: usize = lo + 1;
    while (i < hi) : (i += 1) {
        const key = rm[i];
        var j: usize = i;
        while (j > lo and rootLess(&key, &rm[j - 1])) : (j -= 1) rm[j] = rm[j - 1];
        rm[j] = key;
    }
}
// move-to-front: rotate the first RootMove whose pv[0]==target to front.
pub fn moveToFront(rm: [*]RootMove, count: usize, target: u16) void {
    var fi: usize = 0;
    while (fi < count and rm[fi].pv.moves[0] != target) : (fi += 1) {}
    if (fi >= count) return;
    const tmp = rm[fi];
    var z: usize = fi;
    while (z > 0) : (z -= 1) rm[z] = rm[z - 1];
    rm[0] = tmp;
}
pub inline fn idElapsed(id: *const ZfishIdState) i64 {
    return if (id.tm_use_nodes_time != 0) @intCast(id.nodes.*) else time_source.now() - id.tm_start_time;
}
pub inline fn fclamp(v: f64, lo: f64, hi: f64) f64 {
    return @max(lo, @min(v, hi));
}

// Skill (strength handicap). The none-move is 0. The PRNG matches misc.h's
// xorshift*, seeded once from now() on first use (non-deterministic by design).
const skill_pawn_value: c_int = 208;
var skill_rng_state: u64 = 0;
fn skillRand64() u64 {
    if (skill_rng_state == 0) skill_rng_state = @bitCast(time_source.now());
    var s = skill_rng_state;
    s ^= s >> 12;
    s ^= s << 25;
    s ^= s >> 27;
    skill_rng_state = s;
    return s *% 2685821657736338717;
}
pub inline fn skillTimeToPick(level: f64, depth: c_int) bool {
    return depth == 1 + @as(c_int, @intFromFloat(level));
}
// Skill pick-best: a statistical rule over the (descending-sorted) rootMoves.
pub fn skillPickBest(id: *const ZfishIdState, multi_pv: usize) u16 {
    const top_score = id.root_moves[0].score;
    const span = top_score - id.root_moves[multi_pv - 1].score;
    const delta: c_int = if (span < skill_pawn_value) span else skill_pawn_value;
    const weakness: f64 = 120.0 - 2.0 * id.skill_level;
    const modw: u32 = @intFromFloat(weakness);
    var max_score: c_int = -q_value_inf;
    var best: u16 = 0;
    var i: usize = 0;
    while (i < multi_pv) : (i += 1) {
        const r: u32 = @truncate(skillRand64());
        const term1 = weakness * @as(f64, @floatFromInt(top_score - id.root_moves[i].score));
        const term2: c_int = delta * @as(c_int, @intCast(r % modw));
        const push = @divTrunc(@as(c_int, @intFromFloat(term1 + @as(f64, @floatFromInt(term2)))), 128);
        if (id.root_moves[i].score + push >= max_score) {
            max_score = id.root_moves[i].score + push;
            best = id.root_moves[i].pv.moves[0];
        }
    }
    return best;
}
// Swap rootMoves[0] with the RootMove whose pv[0]==move.
pub fn skillSwapBest(id: *const ZfishIdState, move: u16) void {
    var i: usize = 0;
    while (i < id.root_moves_count and id.root_moves[i].pv.moves[0] != move) : (i += 1) {}
    if (i >= id.root_moves_count or i == 0) return;
    const tmp = id.root_moves[0];
    id.root_moves[0] = id.root_moves[i];
    id.root_moves[i] = tmp;
}
