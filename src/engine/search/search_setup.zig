// Construct the QCtx: fetch the Worker-graph state the inlined node
// recursion needs one-shot (searchCbWorkerState) and assemble the hot QCtx from it
// (buildCtx). Read worker-graph only -- no call into the recursion -- so form a
// leaf over worker_layout + the root_move / search_ctx type leaves;
// search_driver's entry points (qsearchEntry/searchEntry/iterativeDeepening) import
// it one-way to build the ctx they thread into qsearchImpl/searchImpl.

const worker_layout = @import("worker_layout");
const root_move = @import("root_move");
const search_ctx = @import("search_ctx");
const tt_types = @import("tt_types");
const nnue_acc = @import("nnue_accumulator");

const PVMoves = root_move.PVMoves;
const QCtx = search_ctx.QCtx;
const SearchTimeState = search_ctx.SearchTimeState;

// Fetch the Worker state the inlined search needs one-shot, all stable for the
// duration of one search tree. Keep live (mutable) fields as pointers into the Worker;
// null the main-thread-only time-management fields on helper threads.
fn searchCbWorkerState(wl: *worker_layout.WorkerLayout, out_acc_stack: *?*nnue_acc.AccumulatorStack, out_nodes: *?*u64, out_cache: *?*nnue_acc.RefreshCache, out_optimism: *?*const [2]i32, out_nmp_min_ply: *?*i32, out_sel_depth: *?*i32, out_root_depth: *?*i32, out_reductions: *?[*]const i32, out_root_delta: *?*const i32, out_last_iter_pv: *?*const PVMoves, out_stop: *?*const u8, out_pv_idx: *?*const usize, out_root_moves: *?[*]root_move.RootMove, out_pv_last: *?*const usize, out_best_move_changes: *?*u64, out_time: *SearchTimeState) void {
    const stop = &wl.threads.stop;

    // Erase the NNUE arenas here -- raw byte buffers embedded in the worker; this is their
    // single erasure boundary into the opaque B4 handles the eval path consumes.
    out_acc_stack.* = @ptrCast(&wl.accumulator_stack);
    out_nodes.* = &wl.nodes;
    out_cache.* = @ptrCast(&wl.refresh_table);
    out_optimism.* = &wl.optimism;
    out_nmp_min_ply.* = &wl.nmp_min_ply;
    out_sel_depth.* = &wl.sel_depth;
    out_root_depth.* = &wl.root_depth;
    out_reductions.* = &wl.reductions;
    out_root_delta.* = &wl.root_delta;
    // Coerce mut->const with no cast -- one canonical PVMoves now.
    out_last_iter_pv.* = &wl.last_iteration_pv;
    out_stop.* = stop;
    out_pv_idx.* = &wl.pv_idx;
    // Point at root_moves' first element via .ptr (a typed slice now).
    out_root_moves.* = wl.root_moves.ptr;
    out_pv_last.* = &wl.pv_last;
    out_best_move_changes.* = &wl.best_move_changes;

    if (wl.thread_idx == 0) {
        const smgr = wl.manager.?;
        out_time.calls_cnt = &smgr.calls_cnt;
        out_time.stop_write = stop;
        out_time.ponder = &smgr.ponder;
        out_time.stop_on_ponderhit = &smgr.stop_on_ponderhit;
        out_time.tm_start_time = smgr.tm.start_time;
        out_time.tm_maximum_time = smgr.tm.maximum_time;
        out_time.lim_nodes = wl.limits.nodes;
        out_time.lim_movetime = wl.limits.movetime;
        out_time.tm_use_nodes_time = smgr.tm.use_nodes_time;
        out_time.use_time_management = @intFromBool(wl.limits.time[0] != 0 or wl.limits.time[1] != 0);
        // Wire the pool: checkTime must gate on the nodes the whole pool searched, not
        // this worker's own count (search.cpp:2073, 2088).
        out_time.threads = wl.threads;
    } else {
        out_time.calls_cnt = null;
        out_time.threads = null;
    }
}

pub fn buildCtx(worker: *worker_layout.WorkerLayout, table: ?[*]tt_types.TtCluster, cc: usize, gen: u8) QCtx {
    var acc_stack: ?*nnue_acc.AccumulatorStack = null;
    var nodes: ?*u64 = null;
    var cache: ?*nnue_acc.RefreshCache = null;
    var optimism: ?*const [2]i32 = null;
    var nmp_min_ply: ?*i32 = null;
    var sel_depth: ?*i32 = null;
    var root_depth: ?*i32 = null;
    var reductions: ?[*]const i32 = null;
    var root_delta: ?*const i32 = null;
    var last_iter_pv: ?*const PVMoves = null;
    var stop: ?*const u8 = null;
    var pv_idx: ?*const usize = null;
    var root_moves: ?[*]root_move.RootMove = null;
    var pv_last: ?*const usize = null;
    var best_move_changes: ?*u64 = null;
    var time_state: SearchTimeState = undefined;
    searchCbWorkerState(worker, &acc_stack, &nodes, &cache, &optimism, &nmp_min_ply, &sel_depth, &root_depth, &reductions, &root_delta, &last_iter_pv, &stop, &pv_idx, &root_moves, &pv_last, &best_move_changes, &time_state);
    return .{
        .worker = worker,
        .table = table,
        .cluster_count = cc,
        .generation = gen,
        .acc_stack = acc_stack.?,
        .nodes = nodes.?,
        .cache = cache.?,
        .optimism = optimism.?,
        .nmp_min_ply = nmp_min_ply.?,
        .sel_depth = sel_depth.?,
        .root_depth = root_depth.?,
        .reductions = reductions.?,
        .root_delta = root_delta.?,
        .last_iter_pv = last_iter_pv.?,
        .stop = stop.?,
        .pv_idx = pv_idx.?,
        .root_moves = root_moves.?,
        .pv_last = pv_last.?,
        .best_move_changes = best_move_changes.?,
        .time_state = time_state,
    };
}

test {
    @import("std").testing.refAllDecls(@This());
}
