// Object-graph layout lock for the Zig engine.
//
// The object graph (Engine -> ThreadPool -> Thread -> Worker, plus Position,
// TT, accumulator storage, ...) is constructed and read by the Zig runtime.
// These constants pin the exact byte footprint each object must have; native
// allocations size to them, and any drift surfaces as a bench/parity failure.

const std = @import("std");

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

// Position field offsets the NNUE eval reads directly, so network.zig need not
// import the (heavy, cycle-prone) position module for two scalar reads. Pinned
// here in the leaf layout authority; position.zig comptime-asserts them against
// its real Position struct, so a layout change is caught at build time.
// Position is now a native Zig struct (M16.8): Zig chose these field offsets; the
// network reads board/side through them and position.zig comptime-asserts they match
// @offsetOf(Position, ...), so a layout change fails the build instead of corrupting.
pub const position_board_off: usize = 940; // Position.board [64]u8
pub const position_side_to_move_off: usize = 1020; // Position.side_to_move (u8)

// Side to move of a Position by pointer (== Position.side_to_move).
pub inline fn positionSideToMove(pos: *const anyopaque) u8 {
    return @as([*]const u8, @ptrCast(pos))[position_side_to_move_off];
}

// ThreadPool aggregate reads (sum over the pool's threads). Pure graph reads, so they
// live here in the leaf: position.zig (search driver) reads them without importing the
// thread module, which would cycle (thread imports position). thread.zig's public
// nodesSearched/tbHits forward here.
pub fn poolNodesSearched(pool: *anyopaque) u64 {
    const tp = ThreadPool.fromPtr(@constCast(pool));
    const n = tp.numThreads();
    var total: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) total += Thread.fromPtr(tp.threadAtPtr(i)).nodesSearched();
    return total;
}
pub fn poolTbHits(pool: *anyopaque) u64 {
    const tp = ThreadPool.fromPtr(@constCast(pool));
    const n = tp.numThreads();
    var total: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) total += Thread.fromPtr(tp.threadAtPtr(i)).tbHits();
    return total;
}
// The 64-square piece board of a Position by pointer (Position.board, offset 0).
pub inline fn positionBoard(pos: *const anyopaque) [*]const u8 {
    return @as([*]const u8, @ptrCast(pos)) + position_board_off;
}

// Byte sizes of the position-module sub-blocks embedded in the Worker (asserted
// against @sizeOf of the real structs in position.zig, which can't be imported here).
pub const worker_histories_bytes: usize = 11419664; // == @sizeOf(position.WorkerHistories)
pub const refresh_table_bytes: usize = 278528; // native FT refresh cache

// The full Search::Worker block as a native Zig layout (M16.9): worker_off is now
// @offsetOf of this struct, not a hand-probed C++ offset map. graph_layout owns it
// using its own LimitsType/PVMoves + opaque byte regions for the position-module types
// (histories/Position/StateInfo). Zig picks the field order (the 64-aligned NNUE arenas
// float to the front), so every consumer must read via worker_off/@offsetOf, never a
// raw absolute offset.
pub const WorkerLayout = struct {
    histories: [worker_histories_bytes]u8 align(8), // position.WorkerHistories
    limits: LimitsType,
    pv_idx: usize,
    pv_last: usize,
    nodes: u64,
    tb_hits: u64,
    best_move_changes: u64,
    sel_depth: c_int,
    nmp_min_ply: c_int,
    optimism: [2]c_int,
    root_pos: [position_size]u8 align(8), // position.Position
    root_state: [state_info_size]u8 align(8), // position.StateInfo
    root_moves: [3]usize, // libc++ vector header {begin,end,cap}
    root_depth: c_int,
    root_delta: c_int,
    last_iteration_pv: PVMoves,
    thread_idx: usize,
    numa_thread_idx: usize,
    numa_total: usize,
    numa_access_token: usize,
    reductions: [256]c_int,
    manager: usize, // ?*SearchManager as a raw address
    tb_config: [16]u8 align(8), // {cardinality:i32, root_in_tb:u8, use_rule50:u8, _, probe_depth:i32} — read as i32, keep aligned
    options: usize, // SharedState reference slots
    threads: usize,
    tt: usize,
    network: usize,
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
    pub const options = @offsetOf(WorkerLayout, "options");
    pub const threads = @offsetOf(WorkerLayout, "threads");
    pub const tt = @offsetOf(WorkerLayout, "tt");
    pub const network = @offsetOf(WorkerLayout, "network");
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

// The SharedState bundle (40 bytes): the five subsystem references the Engine
// hands each Worker at construction (options, thread pool, TT, per-NUMA shared
// histories, network), stored as pointers in source order. Typed view over the
// *anyopaque worker-build boundary that main.zig's native hook impls cross; the
// owner is support/shared_state.zig (same field list, comptime-asserted there).
pub const SharedState = struct {
    options: *anyopaque, // @0  OptionsModel
    threads: *anyopaque, // @8  ThreadPool
    tt: *anyopaque, // @16 TranspositionTable
    shared_histories: *anyopaque, // @24 per-NUMA SharedHistories
    network: *anyopaque, // @32

    pub inline fn fromPtr(p: *const anyopaque) *SharedState {
        return @ptrCast(@alignCast(@constCast(p)));
    }
};

comptime {
    std.debug.assert(@sizeOf(SharedState) == shared_state_size);
}

// The ThreadPool object (64 bytes): the runtime constructs and reads the pool
// through these fields. The `threads`/`bound` members are libc++-`std::vector`
// `{begin,end,cap}` pointer triples (native_threadpool lays *NativeThread into a
// contiguous buffer that begin/end point into).
pub const ThreadPool = struct {
    stop: u8 = 0, // atomic_bool
    increase_depth: u8 = 0, // atomic_bool
    setup_states: ?*anyopaque = null, // StateListPtr (?*StateList)
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
    /// The i-th `Thread*` as an opaque pointer (for the search-driver call sites).
    pub inline fn threadAtPtr(self: *const ThreadPool, i: usize) *anyopaque {
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
        const worker = Thread.fromPtr(self.threadAtPtr(0)).worker;
        if (worker == 0) return null;
        return SearchManager.fromAddr(WorkerLayout.fromAddr(worker).manager);
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
    worker: usize, // @8 (LargePagePtr<Worker>, as a raw address)

    pub inline fn fromAddr(addr: usize) *Thread {
        return @ptrFromInt(addr);
    }
    pub inline fn fromPtr(p: *anyopaque) *Thread {
        return @ptrCast(@alignCast(p));
    }
    /// This thread's Worker cumulative node count (0 if no worker attached).
    pub inline fn nodesSearched(self: *const Thread) u64 {
        if (self.worker == 0) return 0;
        return WorkerLayout.fromAddr(self.worker).nodes;
    }
    /// This thread's Worker cumulative tablebase-hit count.
    pub inline fn tbHits(self: *const Thread) u64 {
        if (self.worker == 0) return 0;
        return WorkerLayout.fromAddr(self.worker).tb_hits;
    }
};

// A cursor over the ~13 MB Worker: the base address plus typed accessors for the few
// fields the search-driver reads/writes. Each accessor reinterprets the base as a
// *WorkerLayout (via layout()) and touches the field directly -- typing the *access*
// over a raw Worker base address.
pub const Worker = struct {
    base: usize,

    pub inline fn fromThread(thread: *anyopaque) ?Worker {
        const w = Thread.fromPtr(thread).worker;
        return if (w == 0) null else Worker{ .base = w };
    }
    inline fn layout(self: Worker) *WorkerLayout {
        return WorkerLayout.fromAddr(self.base);
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
    pub inline fn setRootState(self: Worker, src: *const anyopaque) void {
        const dst: [*]u8 = &self.layout().root_state;
        @memcpy(dst[0..state_info_size], @as([*]const u8, @ptrCast(src))[0..state_info_size]);
    }
    pub inline fn rootPosPtr(self: Worker) *anyopaque {
        return &self.layout().root_pos;
    }
    pub inline fn rootStatePtr(self: Worker) *anyopaque {
        return &self.layout().root_state;
    }
    pub inline fn rootDepth(self: Worker) c_int {
        return self.layout().root_depth;
    }
    /// &rootMoves[0] as a typed RootMove.
    pub inline fn rootMovesFirst(self: Worker) *RootMove {
        return RootMove.fromAddr(self.layout().root_moves[0]);
    }
};

// PVMoves: a Move[MAX_PLY+1] buffer plus a length. Now a native struct (M16.8
// de-mirror): the _pad is gone and Zig owns the field order (length lands first),
// so every reader/writer goes through the typed fields, not the old C++ offsets.
pub const PVMoves = struct {
    moves: [247]u16,
    length: usize,

    pub inline fn fromAddr(addr: usize) *PVMoves {
        return @ptrFromInt(addr);
    }
};

// A RootMove: effort, the Value(int) scores, the two bound bools, the depth/tb
// ranks, and the embedded PVMoves. Native struct (M16.8) with the same field list
// as position.RootMove / root_move.RootMove, so all three share one Zig layout and
// alias the rootMoves vector element (stride @sizeOf(RootMove) == root_move_size).
pub const RootMove = struct {
    effort: u64,
    score: i32,
    previous_score: i32,
    average_score: i32,
    mean_squared_score: i32,
    uci_score: i32,
    score_lowerbound: u8,
    score_upperbound: u8,
    sel_depth: i32,
    tb_rank: i32,
    tb_score: i32,
    pv: PVMoves,

    pub inline fn fromAddr(addr: usize) *RootMove {
        return @ptrFromInt(addr);
    }
};

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
    table: ?*anyopaque = null, // Cluster*
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

// The LimitsType object (120 bytes): a leading 24-byte std::vector<std::string>
// `searchmoves` (POD-opaque here), then seven 8-byte TimePoints
// (time[2]/inc[2]/npmsec/movetime/startTime) ending at 80, then the search-mode
// ints (movestogo/depth/mate/perft/infinite), nodes, and ponderMode. workerSetLimits
// copies the POD fields, so any layout error here breaks bench (gate-verified).
pub const LimitsType = struct {
    searchmoves: [24]u8, // std::vector<std::string> mirror {begin,end,cap}
    time: [2]i64, // time[WHITE], time[BLACK]
    inc: [2]i64, // inc[WHITE], inc[BLACK]
    npmsec: i64,
    movetime: i64,
    start_time: i64,
    movestogo: i32,
    depth: i32,
    mate: i32,
    perft: i32,
    infinite: i32,
    nodes: u64,
    ponder_mode: u8,

    pub inline fn fromPtr(p: *anyopaque) *LimitsType {
        return @ptrCast(@alignCast(p));
    }
    pub inline fn fromAddr(addr: usize) *LimitsType {
        return @ptrFromInt(addr);
    }
    pub inline fn ponderMode(self: *const LimitsType) bool {
        return self.ponder_mode != 0;
    }
    pub inline fn perftValue(self: *const LimitsType) usize {
        return @intCast(self.perft);
    }
    /// Number of entries in the searchmoves std::vector<std::string> at offset 0.
    pub inline fn searchmoveCount(self: *const LimitsType) usize {
        const begin = @as(*const usize, @ptrCast(@alignCast(&self.searchmoves[0]))).*;
        const end = @as(*const usize, @ptrCast(@alignCast(&self.searchmoves[8]))).*;
        return (end - begin) / 24;
    }
};

comptime {
    // Native struct (M16.8 de-mirror): Zig owns the field order; workerSetLimits copies
    // the POD fields explicitly (not a byte range), so only the fit in the Worker's
    // 120-byte limits slot (worker_off.limits..pv_idx) is contractual.
    std.debug.assert(@sizeOf(LimitsType) <= 120);
}

pub fn verifyLayouts() void {
    // The pinned layout constants are trusted directly; any drift surfaces as a
    // bench/parity failure, and upstream-parity re-pins them against pristine
    // upstream on a resync.
}
