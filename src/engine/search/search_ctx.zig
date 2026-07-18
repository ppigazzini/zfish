// Define the search-driver context types: the plain-data bundles the search driver threads
// through: the per-iteration `SsCtx`/`SearchTimeState`/`ZfishIdState` snapshots and
// the hot `QCtx` the qsearch/search recursion carries. A std-free leaf over the
// worker/board POD leaves. Depend only on worker_layout + the position/root-move
// type leaves.

const worker_layout = @import("worker_layout");
const position_types = @import("position_types");
const root_move = @import("root_move");
const tt_types = @import("tt_types");
const nnue_acc = @import("nnue_accumulator");

const Position = position_types.Position;
const PVMoves = root_move.PVMoves;
const RootMove = root_move.RootMove;

// Share the Worker-graph accessors between BOTH the ID-orchestration driver and the node
// recursion: pure reads of a `*WorkerLayout` into its bound subsystems. Keep them
// here in the context leaf so search_id and search_driver both reach them.
pub fn workerThreadsPool(wl: *const worker_layout.WorkerLayout) *worker_layout.ThreadPool {
    return wl.threads;
}
pub fn workerManager(wl: *const worker_layout.WorkerLayout) ?*worker_layout.SearchManager {
    return wl.manager;
}
pub fn workerRootMove0(wl: *const worker_layout.WorkerLayout) *worker_layout.RootMove {
    // Return the typed first RootMove via the graph adapter; root_moves[0] is the
    // first element's address.
    return @ptrCast(wl.root_moves.ptr);
}
pub fn workerTT(wl: *const worker_layout.WorkerLayout) *worker_layout.TranspositionTable {
    return wl.tt;
}
pub fn searchCbTtContext(wl: *const worker_layout.WorkerLayout, out_table: *?[*]tt_types.TtCluster, out_cluster_count: *usize, out_generation: *u8) void {
    const tp = workerTT(wl);
    out_table.* = tp.table;
    out_cluster_count.* = tp.cluster_count;
    out_generation.* = tp.generation8;
}

pub const SsCtx = struct {
    is_mainthread: u8,
    root_moves_empty: u8,
    npmsec: u8,
    limits_depth: i32,
    skill_enabled: u8,
};

pub const SearchTimeState = struct {
    calls_cnt: ?*i32,
    stop_write: ?*u8,
    ponder: ?*const u8,
    stop_on_ponderhit: ?*const u8,
    tm_start_time: i64,
    tm_maximum_time: i64,
    lim_nodes: u64,
    lim_movetime: i64,
    tm_use_nodes_time: u8,
    use_time_management: u8,
    // Carry the pool so checkTime can read the node count the WHOLE pool has searched,
    // as upstream does (`worker.threads.nodes_searched()`, search.cpp:2073 and 2088).
    // The per-worker counter is not the budget: checkTime runs on the main thread only,
    // so gating on its private count let each of N threads spend the full limit and
    // `go nodes N` overshot by ~N x Threads. Null on a non-main thread, where checkTime
    // returns early anyway.
    threads: ?*worker_layout.ThreadPool,
};

// Sum the nodes searched across the pool -- the quantity upstream's check_time gates on,
// for both the node limit and `nodestime` elapsed. Live here rather than in
// search_control so that module keeps its import set (it already depends on search_ctx);
// worker_layout is already a dependency of this module.
pub fn timeStatePoolNodes(ts: *const SearchTimeState, own_nodes: u64) u64 {
    const tp = ts.threads orelse return own_nodes; // no pool wired => own count is all there is
    return worker_layout.poolNodesSearched(tp);
}

// Snapshot the iterative_deepening state once at entry (skill-off path only). Live
// fields are pointers into Worker/SearchManager/ThreadPool; the rest are values
// read once.
pub const ZfishIdState = struct {
    root_pos: *Position,
    root_moves: [*]RootMove,
    pv_idx: *usize,
    pv_last: *usize,
    sel_depth: *i32,
    root_depth: *i32,
    root_delta: *i32,
    optimism: *[2]i32,
    nodes: *const u64,
    stop: *u8,
    increase_depth: *u8,
    // Hold time management for the main thread only; it lives on the SearchManager and helpers
    // have none. Null is the helper case: every deref sits behind `if (!main_thread) continue;`,
    // so `.?` traps if that guard ever moves instead of writing through a stale pointer.
    stop_on_ponderhit: ?*u8,
    ponder: ?*const u8,
    iter_value: ?*[4]i32,
    previous_time_reduction: ?*f64,
    last_iter_pv: *PVMoves,
    root_moves_count: usize,
    thread_idx: usize,
    threads_size: usize,
    multipv_option: usize,
    tm_optimum: i64,
    tm_maximum: i64,
    tm_start_time: i64,
    limits_depth: i32,
    limits_mate: i32,
    best_previous_score: i32,
    best_previous_average_score: i32,
    skill_level: f64,
    is_main: u8,
    use_time_management: u8,
    tm_use_nodes_time: u8,
    skill_enabled: u8,
};

// Carry the hot per-node context through the qsearch/search recursion: the Worker graph +
// the pointers into it the node bodies read/write. `table` is the typed TT cluster
// base; `acc_stack`/`cache` are the NNUE arena opaque handles (B4 idiom).
pub const QCtx = struct {
    worker: *worker_layout.WorkerLayout,
    table: ?[*]tt_types.TtCluster,
    cluster_count: usize,
    generation: u8,
    acc_stack: *nnue_acc.AccumulatorStack,
    nodes: *u64,
    cache: *nnue_acc.RefreshCache,
    optimism: *const [2]i32,
    nmp_min_ply: *i32,
    sel_depth: *i32,
    root_depth: *i32,
    reductions: [*]const i32,
    root_delta: *const i32,
    last_iter_pv: *const PVMoves,
    stop: *const u8,
    pv_idx: *const usize,
    root_moves: [*]RootMove,
    pv_last: *const usize,
    best_move_changes: *u64,
    time_state: SearchTimeState,
};

test {
    @import("std").testing.refAllDecls(@This());
}
