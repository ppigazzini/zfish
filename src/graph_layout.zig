// Object-graph layout lock for the Zig engine.
//
// The object graph (Engine -> ThreadPool -> Thread -> Worker, plus Position,
// TT, accumulator storage, ...) is constructed and read by the Zig runtime.
// These constants pin the exact byte footprint each object must have; native
// allocations size to them, and any drift surfaces as a bench/parity failure.

const std = @import("std");
const worker_histories = @import("worker_histories");
const position_types = @import("position_types");
const limits_type = @import("limits_type");
const root_move = @import("root_move");
const tt_types = @import("tt_types");
const state_list = @import("state_list");

// Canonical footprint in bytes (x86-64, ARCH=x86-64-sse41-popcnt).
pub const worker_size: usize = @sizeOf(WorkerLayout);
pub const worker_align: usize = 64;
pub const thread_size: usize = 208;
pub const thread_pool_size: usize = 64;
pub const engine_size: usize = 1680;
pub const uci_engine_size: usize = 1696;
pub const shared_state_size: usize = 40;
pub const search_manager_size: usize = 120;
pub const position_size: usize = 1032;
pub const state_info_size: usize = 192;
pub const transposition_table_size: usize = 24;
pub const accumulator_stack_size: usize = 2181568;
pub const accumulator_caches_size: usize = 278528;
pub const root_move_size: usize = 552;

// ThreadPool aggregate reads (sum over the pool's threads). Pure graph reads, so they
// live here in the leaf: position.zig (search driver) reads them without importing the
// thread module, which would cycle (thread imports position). thread.zig's public
// nodesSearched/tbHits forward here.
pub fn poolNodesSearched(tp: *ThreadPool) u64 {
    const n = tp.numThreads();
    var total: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) total += tp.threadTyped(i).nodesSearched();
    return total;
}
pub fn poolTbHits(tp: *ThreadPool) u64 {
    const n = tp.numThreads();
    var total: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) total += tp.threadTyped(i).tbHits();
    return total;
}

// Byte size of the still-opaque position-module sub-blocks embedded in the Worker
// (asserted against @sizeOf of the real structs in position.zig, which can't be
// imported here). histories is no longer here -- it is a typed WorkerHistories field
// (the worker_histories leaf module is importable, unlike position).
pub const worker_histories_bytes: usize = @sizeOf(worker_histories.WorkerHistories);
pub const refresh_table_bytes: usize = 278528; // native FT refresh cache

// The full Search::Worker block as a native Zig layout (M16.9): worker_off is now
// @offsetOf of this struct, not a hand-probed C++ offset map. graph_layout owns it
// using its own LimitsType/PVMoves + the typed WorkerHistories, plus opaque byte
// regions for the position-module types still trapped behind the cycle (Position /
// StateInfo). Zig picks the field order (the 64-aligned NNUE arenas float to the
// front), so every consumer must read via worker_off/@offsetOf, never a raw offset.
pub const WorkerLayout = struct {
    histories: worker_histories.WorkerHistories align(8), // the typed per-Worker history tables
    limits: LimitsType,
    pv_idx: usize,
    pv_last: usize,
    nodes: u64,
    tb_hits: u64,
    best_move_changes: u64,
    sel_depth: c_int,
    nmp_min_ply: c_int,
    optimism: [2]c_int,
    root_pos: position_types.Position align(8), // the worker's root Position (typed, M17.3c)
    root_state: position_types.StateInfo align(8), // its root StateInfo (typed, M17.3c)
    root_moves: []root_move.RootMove, // the worker's rootMoves (M19.1: a typed slice, was {begin,end,cap})
    root_depth: c_int,
    root_delta: c_int,
    last_iteration_pv: PVMoves,
    thread_idx: usize,
    numa_thread_idx: usize,
    numa_total: usize,
    numa_access_token: usize,
    reductions: [256]c_int,
    manager: ?*SearchManager, // the worker's SearchManager (null before build / after free)
    tb_config: [16]u8 align(8), // {cardinality:i32, root_in_tb:u8, use_rule50:u8, _, probe_depth:i32} — read as i32, keep aligned
    threads: *ThreadPool,
    tt: *TranspositionTable,
    accumulator_stack: [accumulator_stack_size]u8 align(64),
    refresh_table: [refresh_table_bytes]u8 align(64),

    /// Typed view over the 13.2 MB worker block (M17.2a). The block is a
    /// 64-aligned large-page allocation, so this reinterpret is sound and reads
    /// each scalar field at its @offsetOf -- the same address worker_off yields,
    /// so it is bench-invariant. Opaque byte regions (histories/root_pos/NNUE
    /// arenas) still need the position-type embedding a later slice will do.
    pub inline fn fromPtr(p: *anyopaque) *WorkerLayout {
        return @ptrCast(@alignCast(p));
    }
    /// Same typed view from a raw Worker base address (the value a Thread.worker
    /// slot holds), for the search driver's per-thread worker walks.
    pub inline fn fromAddr(addr: usize) *WorkerLayout {
        return @ptrFromInt(addr);
    }
};

comptime {
    // Worker-block layout-lock (M17.3a / M20). The Worker is a fixed 64-aligned
    // large-page image. `root_pos`/`root_state` carry typed Position / StateInfo
    // (M17.3c) accessed by @offsetOf (worker_off), never by cross-field adjacency, so
    // the real contract is only that each type fills exactly its reserved slot width.
    // Assert that directly on the TYPE SIZES (ordering-independent) rather than on the
    // WorkerLayout field offset-deltas -- the former held a hidden dependency on Zig's
    // auto field-reorder that blocked removing unrelated fields (M20).
    std.debug.assert(@alignOf(WorkerLayout) == 64);
    std.debug.assert(@sizeOf(position_types.Position) == position_size);
    std.debug.assert(@sizeOf(position_types.StateInfo) == state_info_size);
}

pub const worker_off = struct {
    pub const histories = @offsetOf(WorkerLayout, "histories");
    // shared_history is inside WorkerHistories at position.worker_shared_history_off
    // (a native struct, so not a fixed sub-offset); users add histories + that.
    pub const limits = @offsetOf(WorkerLayout, "limits");
    pub const pv_idx = @offsetOf(WorkerLayout, "pv_idx");
    pub const pv_last = @offsetOf(WorkerLayout, "pv_last");
    pub const nodes = @offsetOf(WorkerLayout, "nodes");
    pub const tb_hits = @offsetOf(WorkerLayout, "tb_hits");
    pub const best_move_changes = @offsetOf(WorkerLayout, "best_move_changes");
    pub const sel_depth = @offsetOf(WorkerLayout, "sel_depth");
    pub const nmp_min_ply = @offsetOf(WorkerLayout, "nmp_min_ply");
    pub const optimism = @offsetOf(WorkerLayout, "optimism");
    pub const root_pos = @offsetOf(WorkerLayout, "root_pos");
    pub const root_state = @offsetOf(WorkerLayout, "root_state");
    pub const root_moves = @offsetOf(WorkerLayout, "root_moves");
    pub const root_depth = @offsetOf(WorkerLayout, "root_depth");
    pub const root_delta = @offsetOf(WorkerLayout, "root_delta");
    pub const last_iteration_pv = @offsetOf(WorkerLayout, "last_iteration_pv");
    pub const thread_idx = @offsetOf(WorkerLayout, "thread_idx");
    pub const numa_thread_idx = @offsetOf(WorkerLayout, "numa_thread_idx");
    pub const numa_total = @offsetOf(WorkerLayout, "numa_total");
    pub const numa_access_token = @offsetOf(WorkerLayout, "numa_access_token");
    pub const reductions = @offsetOf(WorkerLayout, "reductions");
    pub const manager = @offsetOf(WorkerLayout, "manager");
    pub const tb_config = @offsetOf(WorkerLayout, "tb_config");
    pub const threads = @offsetOf(WorkerLayout, "threads");
    pub const tt = @offsetOf(WorkerLayout, "tt");
    pub const accumulator_stack = @offsetOf(WorkerLayout, "accumulator_stack");
    pub const accumulator_stack_size_field = accumulator_stack + accumulator_stack_size - 64;
    pub const refresh_table = @offsetOf(WorkerLayout, "refresh_table");
};

// TimeManagement (40 bytes): the clock sub-object embedded in SearchManager at
// offset 8. availableNodes (4th i64) is set to -1 by TimeManagement::clear.
pub const TimeManagement = struct {
    start_time: i64 = 0,
    optimum_time: i64 = 0,
    maximum_time: i64 = 0,
    available_nodes: i64 = 0,
    use_nodes_time: u8 = 0, // bool
};

// The SearchManager object (120 bytes). Typed replacement for search_manager_off:
// a vtable slot, the embedded TimeManagement, and the per-search bookkeeping the
// time-management + PV code reads. `ponder` is a std::atomic_bool in a 4-byte slot.
pub const SearchManager = struct {
    vtable: usize = 0, // functionally dead (no virtual dispatch); kept as a zero slot
    tm: TimeManagement = .{},
    original_time_adjust: f64 = 0,
    calls_cnt: i32 = 0,
    ponder: u8 = 0, // atomic_bool
    iter_value: [4]i32 = .{ 0, 0, 0, 0 },
    previous_time_reduction: f64 = 0,
    best_previous_score: i32 = 0,
    best_previous_average_score: i32 = 0,
    stop_on_ponderhit: u8 = 0, // bool
    id: usize = 0,
    updates: ?*const anyopaque = null, // const UpdateContext&

    pub inline fn fromPtr(p: *anyopaque) *SearchManager {
        return @ptrCast(@alignCast(p));
    }
    pub inline fn fromAddr(addr: usize) *SearchManager {
        return @ptrFromInt(addr);
    }

    // Typed accessors that reset the per-search MainSearchManager state the
    // ThreadPool::start_searching path re-inits.
    pub inline fn resetCallsCount(self: *SearchManager) void {
        self.calls_cnt = 0;
    }
    pub inline fn resetBestPreviousScore(self: *SearchManager) void {
        self.best_previous_score = 32001; // VALUE_INFINITE
    }
    pub inline fn resetBestPreviousAverageScore(self: *SearchManager) void {
        self.best_previous_average_score = 32001;
    }
    pub inline fn resetOriginalTimeAdjust(self: *SearchManager) void {
        self.original_time_adjust = -1;
    }
    pub inline fn resetPreviousTimeReduction(self: *SearchManager) void {
        self.previous_time_reduction = 0.85;
    }
    pub inline fn setPonder(self: *SearchManager, v: bool) void {
        self.ponder = @intFromBool(v);
    }
    pub inline fn setStopOnPonderhit(self: *SearchManager, v: bool) void {
        self.stop_on_ponderhit = @intFromBool(v);
    }
    pub inline fn clearTimeman(self: *SearchManager) void {
        self.tm.available_nodes = -1;
    }
};

// SearchManager + TimeManagement are now native Zig structs (M16.8 de-mirror): the
// manager is a standalone heap object reached only through these typed accessors and
// pointed to by worker_off.manager, so its internal layout is Zig's to choose -- the
// C++ offset mirror (@offsetOf == 8/60/88/... asserts) is retired. The allocation in
// zfishMakeSearchManager now sizes to @sizeOf(SearchManager).

// The SharedState bundle (40 bytes) is no longer re-exported here (M18.5): typing its
// five fields required the referent types, which reach graph_layout and would close a
// module cycle. It is now the comptime-generic support/shared_state.SharedStateOf,
// instantiated once with concrete types in support/engine.zig; main.zig reads it via
// engine.SharedState.fromPtr. graph_layout no longer imports shared_state, which cuts
// the last `→ shared_state` back-edge. `shared_state_size` (40) stays as the pinned
// footprint the native allocations reserve. See REPORT-17 Annex A.

// The ThreadPool object (64 bytes): the runtime constructs and reads the pool
// through these fields. The `threads`/`bound` members are libc++-`std::vector`
// `{begin,end,cap}` pointer triples (native_threadpool lays *NativeThread into a
// contiguous buffer that begin/end point into).
pub const ThreadPool = struct {
    stop: u8 = 0, // atomic_bool
    increase_depth: u8 = 0, // atomic_bool
    setup_states: ?*state_list.StateList = null, // the native `states` StateListPtr
    threads_begin: usize = 0, // Thread* vector {begin,end,cap}
    threads_end: usize = 0,
    threads_cap: usize = 0,
    bound_begin: usize = 0, // size_t vector {begin,end,cap}
    bound_end: usize = 0,
    bound_cap: usize = 0,

    pub inline fn fromPtr(p: *anyopaque) *ThreadPool {
        return @ptrCast(@alignCast(p));
    }
    pub inline fn fromAddr(addr: usize) *ThreadPool {
        return @ptrFromInt(addr);
    }
    pub inline fn numThreads(self: *const ThreadPool) usize {
        return (self.threads_end - self.threads_begin) / @sizeOf(usize);
    }
    /// The i-th `Thread*` (loaded slot value) in the threads vector.
    pub inline fn threadAt(self: *const ThreadPool, i: usize) usize {
        return @as(*const usize, @ptrFromInt(self.threads_begin + i * @sizeOf(usize))).*;
    }
    /// The i-th pool Thread as a typed pointer. The threads vector stores Thread
    /// addresses as usize, so this is the single @ptrFromInt the graph callers used
    /// to each re-do via Thread.fromPtr/fromAddr.
    pub inline fn threadTyped(self: *const ThreadPool, i: usize) *Thread {
        return @ptrFromInt(self.threadAt(i));
    }
    pub inline fn boundCount(self: *const ThreadPool) usize {
        return (self.bound_end - self.bound_begin) / @sizeOf(usize);
    }
    pub inline fn hasSetupStates(self: *const ThreadPool) bool {
        return self.setup_states != null;
    }
    /// The i-th entry of the bound-nodes vector.
    pub inline fn boundAt(self: *const ThreadPool, i: usize) usize {
        return @as(*const usize, @ptrFromInt(self.bound_begin + i * @sizeOf(usize))).*;
    }
    pub inline fn setStop(self: *ThreadPool, v: bool) void {
        self.stop = @intFromBool(v);
    }
    pub inline fn setIncreaseDepth(self: *ThreadPool, v: bool) void {
        self.increase_depth = @intFromBool(v);
    }
    /// The main thread's SearchManager (thread 0's Worker's manager), or null if not built
    /// yet.
    pub inline fn mainManager(self: *ThreadPool) ?*SearchManager {
        const worker = self.threadTyped(0).worker orelse return null;
        return worker.manager;
    }
};

comptime {
    // ThreadPool is now a native struct (M16.8 de-mirror): native_threadpool.zig
    // writes and every reader (accessors here, the search's captured &stop pointer)
    // go through this typed struct, so Zig owns the field placement. The size must
    // still equal the calloc'd pool buffer (native_engine.memberThreadpoolNew).
    std.debug.assert(@sizeOf(ThreadPool) == thread_pool_size);
}

// A Thread (view). The full Thread is 208 bytes; the search-driver code only
// needs the LargePagePtr<Worker> `worker` at offset 8 (a single pointer, dereferenced
// to the Worker base), so this partial view struct reinterprets a Thread pointer to
// read that one slot. `worker` is kept as a raw address (the loaded pointer value).
pub const Thread = struct {
    _lo: usize, // @0 (idle-loop / vtable region; unused here)
    worker: ?*WorkerLayout, // @8 (LargePagePtr<Worker>; a typed pointer, null == 0)

    pub inline fn fromAddr(addr: usize) *Thread {
        return @ptrFromInt(addr);
    }
    pub inline fn fromPtr(p: *anyopaque) *Thread {
        return @ptrCast(@alignCast(p));
    }
    /// This thread's Worker cumulative node count (0 if no worker attached).
    pub inline fn nodesSearched(self: *const Thread) u64 {
        const w = self.worker orelse return 0;
        return w.nodes;
    }
    /// This thread's Worker cumulative tablebase-hit count.
    pub inline fn tbHits(self: *const Thread) u64 {
        const w = self.worker orelse return 0;
        return w.tb_hits;
    }
};

// A cursor over the ~13 MB Worker: the base address plus typed accessors for the few
// fields the search-driver reads/writes. Each accessor reinterprets the base as a
// *WorkerLayout (via layout()) and touches the field directly -- typing the *access*
// over a raw Worker base address.
pub const Worker = struct {
    base: *WorkerLayout,

    pub inline fn fromThread(thread: *Thread) ?Worker {
        const w = thread.worker orelse return null;
        return Worker{ .base = w };
    }
    inline fn layout(self: Worker) *WorkerLayout {
        return self.base;
    }
    /// ThreadPool::start_searching re-inits: zero the per-search Worker counters.
    pub inline fn resetRootSetupState(self: Worker) void {
        const wl = self.layout();
        wl.nodes = 0;
        wl.tb_hits = 0;
        wl.best_move_changes = 0;
        wl.nmp_min_ply = 0;
        wl.root_depth = 0;
    }
    pub inline fn setTbConfig(self: Worker, cardinality: c_int, root_in_tb: bool, use_rule50: bool, probe_depth: c_int) void {
        // tb_config is a 16-byte blob {cardinality:i32, root_in_tb:u8, use_rule50:u8, _, probe_depth:i32}.
        const b = &self.layout().tb_config;
        @as(*c_int, @ptrCast(@alignCast(&b[0]))).* = cardinality;
        b[4] = @intFromBool(root_in_tb);
        b[5] = @intFromBool(use_rule50);
        @as(*c_int, @ptrCast(@alignCast(&b[8]))).* = probe_depth;
    }
    pub inline fn setRootState(self: Worker, src: *const position_types.StateInfo) void {
        // root_state is a typed StateInfo (M17.3c/M18.7): a struct copy, not a byte memcpy.
        self.layout().root_state = src.*;
    }
    pub inline fn rootPosPtr(self: Worker) *position_types.Position {
        return &self.layout().root_pos;
    }
    pub inline fn rootStatePtr(self: Worker) *position_types.StateInfo {
        return &self.layout().root_state;
    }
    pub inline fn rootDepth(self: Worker) c_int {
        return self.layout().root_depth;
    }
    /// &rootMoves[0] as a typed RootMove.
    pub inline fn rootMovesFirst(self: Worker) *RootMove {
        return @ptrCast(self.layout().root_moves.ptr);
    }
};

// PVMoves + RootMove are re-exported from the single canonical definition in
// support/root_move.zig (M18.2 de-mirror): the former graph_layout copies (RootMove
// with u8 bound flags, PVMoves) were byte-identical to root_move's (bool flags — same
// 1-byte layout), so unify to one type. The Worker embeds `last_iteration_pv: PVMoves`
// and strides its rootMoves vector by @sizeOf(RootMove); the size asserts below still
// pin those (504 / 552). `.fromAddr` now lives on the canonical def.
pub const PVMoves = root_move.PVMoves;
pub const RootMove = root_move.RootMove;

comptime {
    std.debug.assert(@offsetOf(Thread, "worker") == 8);
    // Native layouts, but the sizes must still equal the C++ footprint the rootMoves
    // vector is strided/allocated by (root_move_size) and the Worker's embedded
    // lastIterationPV slot -- Zig's reorder happens to keep both (504 / 552).
    std.debug.assert(@sizeOf(PVMoves) == 504);
    std.debug.assert(@sizeOf(RootMove) == root_move_size);
}

// The TranspositionTable object (24 bytes). Typed replacement for the tt_off offset
// map: clusterCount, table (Cluster*), generation8, in declaration order. The side
// TT the native engine allocates uses this layout.
pub const TranspositionTable = struct {
    cluster_count: usize = 0,
    table: ?[*]tt_types.TtCluster = null,
    generation8: u8 = 0,

    pub inline fn fromPtr(p: *anyopaque) *TranspositionTable {
        return @ptrCast(@alignCast(p));
    }
    pub inline fn fromAddr(addr: usize) *TranspositionTable {
        return @ptrFromInt(addr);
    }
};

// TranspositionTable is now a native struct (M16.8 de-mirror): the side-TT handle in
// native_engine.side_tt_storage is written+read only through these typed accessors, so
// Zig owns the (naturally-ordered) layout; the C++ offset mirror is retired.

// LimitsType + SearchMoveText moved to the limits_type leaf (M17.10 god-module
// split); re-exported so the go-command chain keeps resolving graph_layout.LimitsType
// / .SearchMoveText. WorkerLayout embeds the re-exported LimitsType (same layout, the
// 120-byte contractual slot is asserted in limits_type.zig).
pub const SearchMoveText = limits_type.SearchMoveText;
pub const LimitsType = limits_type.LimitsType;

pub fn verifyLayouts() void {
    // The pinned layout constants are trusted directly; any drift surfaces as a
    // bench/parity failure, and upstream-parity re-pins them against pristine
    // upstream on a resync.
}
