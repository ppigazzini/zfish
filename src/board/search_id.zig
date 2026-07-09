// Iterative-deepening orchestration helpers (M18.7 — split out of search_driver.zig).
// The per-search worker-graph reads + time-management / thread-pool / skill / vote
// primitives the search root loop (workerStartSearching / iterativeDeepening, which
// stay in search_driver because they call the node recursion) drives. None of these
// touch the qsearch/search recursion, so they form a std-free leaf over the worker/
// board POD leaves + the option/timeman/tt/native-thread runtimes -- search_driver
// imports it one-directionally (no cycle). The context types + shared worker
// accessors live in the search_ctx leaf both sides import.

const std = @import("std");
const graph_layout = @import("graph_layout");
const option_port = @import("option");
const timeman_port = @import("timeman");
const tt = @import("tt");
const native_thread = @import("native_thread");
const thread_vote = @import("thread_vote");
const nnue_acc = @import("nnue_accumulator");
const position_query = @import("position_query");
const search_ctx = @import("search_ctx");

const SsCtx = search_ctx.SsCtx;
const ZfishIdState = search_ctx.ZfishIdState;
const workerThreadsPool = search_ctx.workerThreadsPool;
const workerManager = search_ctx.workerManager;
const workerRootMove0 = search_ctx.workerRootMove0;
const workerTT = search_ctx.workerTT;
const sideToMove = position_query.sideToMove;
const gamePly = position_query.gamePly;

pub fn ssPrologue(wl: *graph_layout.WorkerLayout) void {
    nnue_acc.stackReset(@ptrCast(&wl.accumulator_stack));
    wl.last_iteration_pv.length = 0;
}

// Sum and reset each thread's worker bestMoveChanges (atomic u64), as a double.
pub fn searchIdCollectBmc(wl: *const graph_layout.WorkerLayout) f64 {
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

pub fn ssSetStop(wl: *const graph_layout.WorkerLayout) void {
    workerThreadsPool(wl).stop = 1;
}

// !threads.stop && (manager->ponder || limits.infinite).
pub fn ssShouldBusywait(wl: *const graph_layout.WorkerLayout) u8 {
    if (workerThreadsPool(wl).stop != 0) return 0;
    const ponder = workerManager(wl).?.ponder;
    const infinite = wl.limits.infinite;
    return if (ponder != 0 or infinite != 0) 1 else 0;
}

pub fn ssSetPrevScores(wl: *const graph_layout.WorkerLayout, best: *const graph_layout.WorkerLayout) void {
    const rmv = workerRootMove0(best);
    const sm = workerManager(wl).?;
    sm.best_previous_score = rmv.score;
    sm.best_previous_average_score = rmv.average_score;
}

pub fn optInt(name: []const u8) c_int {
    return option_port.intByName(name);
}

// Per-search context flags read off the worker graph + the native OptionsModel.
pub fn ssContext(wl: *const graph_layout.WorkerLayout, out: *SsCtx) void {
    // root_moves is the {begin,end,cap} vector header; empty iff begin == end.
    const rm_begin = wl.root_moves[0];
    const rm_end = wl.root_moves[1];

    const limit_strength = optInt("UCI_LimitStrength") != 0;
    const uci_elo: c_int = if (limit_strength) optInt("UCI_Elo") else 0;
    const skill_level = optInt("Skill Level");
    const skill_enabled = uci_elo != 0 or skill_level < 20;

    out.is_mainthread = @intFromBool(wl.thread_idx == 0);
    out.root_moves_empty = @intFromBool(rm_begin == rm_end);
    out.npmsec = @intFromBool(wl.limits.npmsec != 0);
    out.limits_depth = wl.limits.depth;
    out.skill_enabled = @intFromBool(skill_enabled);
}

// Per-search TimeManagement::init + TT::new_search (main thread). Builds the timeman
// input from the worker's limits/rootPos + the manager's tm, reads nodestime/Move
// Overhead/Ponder from the native model, writes the outputs back, and bumps the TT
// generation. Relocated from main.zig (M16.7).
pub fn ssTmInit(wl: *graph_layout.WorkerLayout) void {
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
// else the raw Skill Level option. Relocated from main.zig (M16.7).
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
// the native search root loop. Relocated from main.zig (M16.7); graph reads + the
// native OptionsModel only.
pub fn searchIdState(wl: *graph_layout.WorkerLayout, out: *ZfishIdState) void {
    const thread_idx = wl.thread_idx;
    const is_main = thread_idx == 0;
    const tp = wl.threads;

    // root_moves is the {begin,end,cap} vector header.
    const rm_begin = wl.root_moves[0];
    const rm_end = wl.root_moves[1];

    out.root_pos = &wl.root_pos;
    out.root_moves = @ptrFromInt(rm_begin);
    out.pv_idx = &wl.pv_idx;
    out.pv_last = &wl.pv_last;
    out.sel_depth = &wl.sel_depth;
    out.root_depth = &wl.root_depth;
    out.root_delta = &wl.root_delta;
    out.optimism = &wl.optimism;
    out.nodes = &wl.nodes;
    out.stop = &tp.stop;
    out.increase_depth = &tp.increase_depth;
    // wl.last_iteration_pv and ZfishIdState's field are now the one canonical
    // PVMoves (M18.2 de-mirror), so this is a plain mut->const coercion, no cast.
    out.last_iter_pv = &wl.last_iteration_pv;
    out.root_moves_count = (rm_end - rm_begin) / graph_layout.root_move_size;
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
pub fn ssThreadsStart(wl: *const graph_layout.WorkerLayout) void {
    native_thread.startPoolSiblings(wl.threads);
}
pub fn ssWaitFinished(wl: *const graph_layout.WorkerLayout) void {
    native_thread.waitPoolSiblings(wl.threads);
}

// Worker of the vote-winning thread (Lazy-SMP best-thread selection via the leaf
// thread_vote model). Relocated from main.zig (M16.7).
pub fn ssGetBestThread(wl: *const graph_layout.WorkerLayout) ?*graph_layout.WorkerLayout {
    const pool = wl.threads;
    return thread_vote.bestThreadWorker(pool);
}

// nodestime available-nodes advance (tm.advance_nodes_time). Relocated from main.zig (M16.7).
pub fn ssNpmsecAdvance(wl: *const graph_layout.WorkerLayout) void {
    const avail = &wl.manager.?.tm.available_nodes;
    const us: usize = sideToMove(&wl.root_pos);
    const inc = wl.limits.inc[us];
    const nodes: i64 = @intCast(graph_layout.poolNodesSearched(wl.threads));
    avail.* = @max(@as(i64, 0), avail.* - (nodes - inc));
}
