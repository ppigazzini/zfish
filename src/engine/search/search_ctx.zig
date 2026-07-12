// Search-driver context types: the plain-data bundles the search driver threads
// through: the per-iteration `SsCtx`/`SearchTimeState`/`ZfishIdState` snapshots and
// the hot `QCtx` the qsearch/search recursion carries. A std-free leaf over the
// worker/board POD leaves. Depends only on graph_layout + the position/root-move
// type leaves.

const graph_layout = @import("graph_layout");
const position_types = @import("position_types");
const root_move = @import("root_move");
const tt_types = @import("tt_types");
const nnue_acc = @import("nnue_accumulator");

const Position = position_types.Position;
const PVMoves = root_move.PVMoves;
const RootMove = root_move.RootMove;

// Worker-graph accessors shared by BOTH the ID-orchestration driver and the node
// recursion: pure reads of a `*WorkerLayout` into its bound subsystems. Kept
// here in the context leaf so search_id and search_driver both reach them.
pub fn workerThreadsPool(wl: *const graph_layout.WorkerLayout) *graph_layout.ThreadPool {
    return wl.threads;
}
pub fn workerManager(wl: *const graph_layout.WorkerLayout) ?*graph_layout.SearchManager {
    return wl.manager;
}
pub fn workerRootMove0(wl: *const graph_layout.WorkerLayout) *graph_layout.RootMove {
    // root_moves[0] is the first element's address; return the typed first RootMove
    // via the graph adapter.
    return @ptrCast(wl.root_moves.ptr);
}
pub fn workerTT(wl: *const graph_layout.WorkerLayout) *graph_layout.TranspositionTable {
    return wl.tt;
}
pub fn searchCbTtContext(wl: *const graph_layout.WorkerLayout, out_table: *?[*]tt_types.TtCluster, out_cluster_count: *usize, out_generation: *u8) void {
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
    calls_cnt: ?*c_int,
    stop_write: ?*u8,
    ponder: ?*const u8,
    stop_on_ponderhit: ?*const u8,
    tm_start_time: i64,
    tm_maximum_time: i64,
    lim_nodes: u64,
    lim_movetime: i64,
    tm_use_nodes_time: u8,
    use_time_management: u8,
};

// iterative_deepening state, snapshotted once at entry (skill-off path only). Live
// fields are pointers into Worker/SearchManager/ThreadPool; the rest are values
// read once.
pub const ZfishIdState = struct {
    root_pos: *Position,
    root_moves: [*]RootMove,
    pv_idx: *usize,
    pv_last: *usize,
    sel_depth: *c_int,
    root_depth: *c_int,
    root_delta: *c_int,
    optimism: *[2]c_int,
    nodes: *const u64,
    stop: *u8,
    increase_depth: *u8,
    stop_on_ponderhit: *u8,
    ponder: *const u8,
    iter_value: *[4]c_int,
    previous_time_reduction: *f64,
    last_iter_pv: *PVMoves,
    root_moves_count: usize,
    thread_idx: usize,
    threads_size: usize,
    multipv_option: usize,
    tm_optimum: i64,
    tm_maximum: i64,
    tm_start_time: i64,
    limits_depth: c_int,
    limits_mate: c_int,
    best_previous_score: c_int,
    best_previous_average_score: c_int,
    skill_level: f64,
    is_main: u8,
    use_time_management: u8,
    tm_use_nodes_time: u8,
    skill_enabled: u8,
};

// The hot per-node context the qsearch/search recursion carries: the Worker graph +
// the pointers into it the node bodies read/write. `table` is the typed TT cluster
// base; `acc_stack`/`cache` are the NNUE arena opaque handles (B4 idiom).
pub const QCtx = struct {
    worker: *graph_layout.WorkerLayout,
    table: ?[*]tt_types.TtCluster,
    cluster_count: usize,
    generation: u8,
    acc_stack: *nnue_acc.AccumulatorStack,
    nodes: *u64,
    cache: *nnue_acc.RefreshCache,
    optimism: *const [2]c_int,
    nmp_min_ply: *c_int,
    sel_depth: *c_int,
    root_depth: *c_int,
    reductions: [*]const c_int,
    root_delta: *const c_int,
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
