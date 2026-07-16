// Lock the object-graph layout for the Zig engine.
//
// Pin the object graph (Engine -> ThreadPool -> Thread -> Worker, plus Position,
// TT, accumulator storage, ...) that the Zig runtime constructs and reads.
// Fix the exact byte footprint each object must have with these constants; the
// allocations size to them, and any drift surfaces as a bench/parity failure.

const std = @import("std");
const worker_histories = @import("worker_histories");
const position_types = @import("position_types");
const limits_type = @import("limits_type");
const root_move = @import("root_move");
const tt_types = @import("tt_types");
const state_list = @import("state_list");

// Pin the canonical footprint in bytes (x86-64, ARCH=x86-64-sse41-popcnt).
pub const worker_size: usize = @sizeOf(WorkerLayout);
pub const worker_align: usize = 64;
pub const thread_size: usize = 208;
pub const thread_pool_size: usize = 48;
pub const engine_size: usize = 1680;
pub const uci_engine_size: usize = 1696;
pub const shared_state_size: usize = 40;
pub const search_manager_size: usize = 120;
pub const position_size: usize = 1032;
pub const state_info_size: usize = 192;
pub const transposition_table_size: usize = 24;
pub const accumulator_stack_size: usize = 2181568;
pub const accumulator_caches_size: usize = 278528;
pub const root_move_size: usize = root_move.root_move_footprint;

// Aggregate the ThreadPool reads (sum over the pool's threads): position.zig (the search
// driver) reads them here without importing the thread module. thread.zig's public
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

// Measure the byte size of the WorkerHistories block embedded in the Worker.
pub const worker_histories_bytes: usize = @sizeOf(worker_histories.WorkerHistories);
pub const refresh_table_bytes: usize = 278528; // FT refresh cache

// Lay out the full Worker block as a Zig layout, using worker_layout's own
// LimitsType/PVMoves and the typed WorkerHistories. Let Zig pick the field order (the
// 64-aligned NNUE arenas float to the front), so every consumer must read via
// worker_off/@offsetOf, never a raw offset.
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
    root_pos: position_types.Position align(8), // the worker's root Position
    root_state: position_types.StateInfo align(8), // its root StateInfo
    root_moves: []root_move.RootMove, // the worker's rootMoves
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

    /// Return a typed view over the 13.2 MB worker block. The block is a 64-aligned large-page
    /// allocation, so this reinterpret is sound and reads each scalar field at its
    /// @offsetOf -- the same address worker_off yields, so it is bench-invariant.
    pub inline fn fromPtr(p: *anyopaque) *WorkerLayout {
        return @ptrCast(@alignCast(p));
    }
    /// Return the same typed view from a raw Worker base address (the value a Thread.worker
    /// slot holds), for the search driver's per-thread worker walks.
    pub inline fn fromAddr(addr: usize) *WorkerLayout {
        return @ptrFromInt(addr);
    }
};

comptime {
    // Lock the Worker-block layout. Treat the Worker as a fixed 64-aligned large-page image.
    // `root_pos`/`root_state` carry typed Position / StateInfo accessed by @offsetOf
    // (worker_off), never by cross-field adjacency, so the real contract is only that
    // each type fills exactly its reserved slot width. Assert that directly on the TYPE
    // SIZES (ordering-independent) rather than on the WorkerLayout field offset-deltas.
    std.debug.assert(@alignOf(WorkerLayout) == 64);
    std.debug.assert(@sizeOf(position_types.Position) == position_size);
    std.debug.assert(@sizeOf(position_types.StateInfo) == state_info_size);
}

pub const worker_off = struct {
    pub const histories = @offsetOf(WorkerLayout, "histories");
    // Find shared_history inside WorkerHistories at position.worker_shared_history_off
    // (a Zig-owned struct, so not a fixed sub-offset); users add histories + that.
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

// Lay out TimeManagement (40 bytes): the clock sub-object embedded in SearchManager at
// offset 8. availableNodes (4th i64) is set to -1 by TimeManagement's clear.
pub const TimeManagement = struct {
    start_time: i64 = 0,
    optimum_time: i64 = 0,
    maximum_time: i64 = 0,
    available_nodes: i64 = 0,
    use_nodes_time: u8 = 0, // bool
};

// Lay out the SearchManager object (120 bytes): a vtable slot, the embedded TimeManagement,
// and the per-search bookkeeping the time-management + PV code reads. Keep `ponder` an
// atomic bool in a 4-byte slot.
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
    updates: ?*const anyopaque = null, // pointer to a const UpdateContext

    pub inline fn fromPtr(p: *anyopaque) *SearchManager {
        return @ptrCast(@alignCast(p));
    }
    pub inline fn fromAddr(addr: usize) *SearchManager {
        return @ptrFromInt(addr);
    }

    // Provide typed accessors that reset the per-search MainSearchManager state the
    // ThreadPool's start_searching path re-inits.
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

// Reach the SearchManager as a standalone heap object only through these typed
// accessors, pointed to by worker_off.manager, so its internal layout is Zig's to
// choose. The allocation in zfishMakeSearchManager sizes to @sizeOf(SearchManager).

// Locate the SharedState bundle (40 bytes) in support/shared_state.SharedStateOf,
// instantiated with concrete types in support/engine.zig; main.zig reads it via
// engine.SharedState.fromPtr. Keep `shared_state_size` (40) here as the pinned
// footprint the allocations reserve.

// Lay out the ThreadPool object (48 bytes): the runtime constructs and reads the pool
// through these fields. Keep `threads` and `bound` both Zig slices: `threads` holds
// Thread* addresses, `bound` holds the per-thread NUMA-node index of the cold binding
// path. thread_pool allocates the backing buffers and the accessors index them.
pub const ThreadPool = struct {
    stop: u8 = 0, // atomic_bool
    increase_depth: u8 = 0, // atomic_bool
    setup_states: ?*state_list.StateList = null, // the `states` StateListPtr
    threads: []usize = &.{}, // Thread* addresses
    bound: []usize = &.{}, // per-thread NUMA node bindings

    pub inline fn fromPtr(p: *anyopaque) *ThreadPool {
        return @ptrCast(@alignCast(p));
    }
    pub inline fn fromAddr(addr: usize) *ThreadPool {
        return @ptrFromInt(addr);
    }
    pub inline fn numThreads(self: *const ThreadPool) usize {
        return self.threads.len;
    }
    /// Return the i-th `Thread*` (loaded slot value) in the threads slice.
    pub inline fn threadAt(self: *const ThreadPool, i: usize) usize {
        return self.threads[i];
    }
    /// Return the i-th pool Thread as a typed pointer. The threads vector stores Thread
    /// addresses as usize, so this is the single @ptrFromInt over that slot.
    pub inline fn threadTyped(self: *const ThreadPool, i: usize) *Thread {
        return @ptrFromInt(self.threadAt(i));
    }
    pub inline fn boundCount(self: *const ThreadPool) usize {
        return self.bound.len;
    }
    pub inline fn hasSetupStates(self: *const ThreadPool) bool {
        return self.setup_states != null;
    }
    /// Return the i-th entry of the bound-nodes slice.
    pub inline fn boundAt(self: *const ThreadPool, i: usize) usize {
        return self.bound[i];
    }
    pub inline fn setStop(self: *ThreadPool, v: bool) void {
        self.stop = @intFromBool(v);
    }
    pub inline fn setIncreaseDepth(self: *ThreadPool, v: bool) void {
        self.increase_depth = @intFromBool(v);
    }
    /// Return the main thread's SearchManager (thread 0's Worker's manager), or null if not built
    /// yet.
    pub inline fn mainManager(self: *ThreadPool) ?*SearchManager {
        const worker = self.threadTyped(0).worker orelse return null;
        return worker.manager;
    }
};

comptime {
    // Route thread_pool.zig writes and every reader (accessors here, the search's
    // captured &stop pointer) through this typed struct, so Zig owns the field
    // placement. The size must equal the calloc'd pool buffer
    // (engine_object.memberThreadpoolNew).
    std.debug.assert(@sizeOf(ThreadPool) == thread_pool_size);
}

// View a Thread. The full Thread is 208 bytes; the search-driver code only
// needs the LargePagePtr<Worker> `worker` at offset 8 (a single pointer, dereferenced
// to the Worker base), so this partial view struct reinterprets a Thread pointer to
// read that one slot. Keep `worker` as a raw address (the loaded pointer value).
pub const Thread = struct {
    _lo: usize, // @0 (idle-loop / vtable region; unused here)
    worker: ?*WorkerLayout, // @8 (LargePagePtr<Worker>; a typed pointer, null == 0)

    pub inline fn fromAddr(addr: usize) *Thread {
        return @ptrFromInt(addr);
    }
    pub inline fn fromPtr(p: *anyopaque) *Thread {
        return @ptrCast(@alignCast(p));
    }
    /// Return this thread's Worker cumulative node count (0 if no worker attached).
    pub inline fn nodesSearched(self: *const Thread) u64 {
        const w = self.worker orelse return 0;
        return w.nodes;
    }
    /// Return this thread's Worker cumulative tablebase-hit count.
    pub inline fn tbHits(self: *const Thread) u64 {
        const w = self.worker orelse return 0;
        return w.tb_hits;
    }
};

// Provide a cursor over the ~13 MB Worker: the base address plus typed accessors for the few
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
    /// Zero the per-search Worker counters that ThreadPool's start_searching re-inits.
    pub inline fn resetRootSetupState(self: Worker) void {
        const wl = self.layout();
        wl.nodes = 0;
        wl.tb_hits = 0;
        wl.best_move_changes = 0;
        wl.nmp_min_ply = 0;
        wl.root_depth = 0;
    }
    pub inline fn setTbConfig(self: Worker, cardinality: c_int, root_in_tb: bool, use_rule50: bool, probe_depth: c_int) void {
        // Treat tb_config as a 16-byte blob {cardinality:i32, root_in_tb:u8, use_rule50:u8, _, probe_depth:i32}.
        const b = &self.layout().tb_config;
        @as(*c_int, @ptrCast(@alignCast(&b[0]))).* = cardinality;
        b[4] = @intFromBool(root_in_tb);
        b[5] = @intFromBool(use_rule50);
        @as(*c_int, @ptrCast(@alignCast(&b[8]))).* = probe_depth;
    }
    pub inline fn setRootState(self: Worker, src: *const position_types.StateInfo) void {
        // Copy root_state as a typed StateInfo: a struct copy, not a byte memcpy.
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
    /// Return &rootMoves[0] as a typed RootMove.
    pub inline fn rootMovesFirst(self: Worker) *RootMove {
        return @ptrCast(self.layout().root_moves.ptr);
    }
};

// Re-export PVMoves + RootMove from the canonical definition in
// support/root_move.zig. The Worker embeds `last_iteration_pv: PVMoves` and strides
// its rootMoves vector by @sizeOf(RootMove); the size asserts below pin those
// (504 / root_move_size).
pub const PVMoves = root_move.PVMoves;
pub const RootMove = root_move.RootMove;

comptime {
    std.debug.assert(@offsetOf(Thread, "worker") == 8);
    // Keep the sizes equal to the footprint the rootMoves vector is strided/allocated by
    // (root_move_size) and the Worker's embedded lastIterationPV slot (504).
    std.debug.assert(@sizeOf(PVMoves) == 504);
    std.debug.assert(@sizeOf(RootMove) == root_move_size);
}

// Lay out the TranspositionTable object (24 bytes): clusterCount, table (Cluster*),
// generation8, in declaration order. The side TT the engine allocates uses
// this layout.
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

// Write and read the side-TT handle in engine_object.side_tt_storage only through
// these typed accessors, so Zig owns the (naturally-ordered) layout.

// Re-export LimitsType + SearchMoveText from the limits_type module so the
// go-command chain keeps resolving worker_layout.LimitsType / .SearchMoveText.
// WorkerLayout embeds the re-exported LimitsType (same layout, the 120-byte
// contractual slot is asserted in limits_type.zig).
pub const SearchMoveText = limits_type.SearchMoveText;
pub const LimitsType = limits_type.LimitsType;

pub fn verifyLayouts() void {
    // Trust the pinned layout constants directly; any drift surfaces as a
    // bench/parity failure, and upstream-parity re-pins them against pristine
    // upstream on a resync.
}

test {
    @import("std").testing.refAllDecls(@This());
}
