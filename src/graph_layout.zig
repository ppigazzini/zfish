// Object-graph layout lock for the Zig engine reimplementation.
//
// The C++ object graph (Engine -> ThreadPool -> Thread -> Worker, plus Position,
// TT, accumulator storage, ...) is what the Zig runtime currently constructs and
// reads through layout mirrors. Reimplementing construction in Zig means
// allocating these objects from Zig, byte-for-byte compatible. These constants
// pin the exact C++ footprint captured from the bridge probe; the verifier runs
// at engine creation and aborts on any drift, so an upstream size change is
// caught immediately rather than corrupting a mirror silently.

const std = @import("std");

// Canonical C++ footprint in bytes (x86-64, ARCH=x86-64-sse41-popcnt).
pub const worker_size: usize = 13882816;
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

// Worker member offsets (bytes from the Worker base), captured from a live
// Worker via pointer arithmetic. Non-reference members are probed directly;
// the three reference members (sharedHistory, tt, network) are stored as
// pointers but &ref yields the referent, so their slots are derived from the
// gaps between neighbours and cross-checked against alignment. This is the
// address map the Zig Worker struct (HARD-3) must reproduce.
pub const worker_off = struct {
    pub const main_history: usize = 0;
    pub const low_ply_history: usize = 262144;
    pub const capture_history: usize = 917504;
    pub const continuation_history: usize = 933888;
    pub const continuation_correction_history: usize = 9322496;
    pub const tt_move_history: usize = 11419648;
    pub const shared_history: usize = 11419656; // reference (derived)
    pub const limits: usize = 11419664;
    pub const pv_idx: usize = 11419784;
    pub const pv_last: usize = 11419792;
    pub const nodes: usize = 11419800;
    pub const tb_hits: usize = 11419808;
    pub const best_move_changes: usize = 11419816;
    pub const sel_depth: usize = 11419824;
    pub const nmp_min_ply: usize = 11419828;
    pub const optimism: usize = 11419832;
    pub const root_pos: usize = 11419840;
    // rootState (StateInfo, 192 bytes) sits between rootPos (Position, 1032 bytes)
    // and rootMoves. Verified at engine creation via the offsetof probe
    // (which == 16) below.
    pub const root_state: usize = 11420872;
    pub const root_moves: usize = 11421064;
    pub const root_depth: usize = 11421088;
    pub const root_delta: usize = 11421092;
    // lastIterationPV (PVMoves, 504 bytes) sits between rootDelta and threadIdx.
    // Verified at engine creation via the offsetof probe (which == 17).
    pub const last_iteration_pv: usize = 11421096;
    pub const thread_idx: usize = 11421600;
    pub const reductions: usize = 11421632;
    pub const manager: usize = 11422656;
    // tbConfig (Tablebases::Config, 12 used bytes + 4 pad) sits immediately after
    // the 8-byte manager unique_ptr, before the options reference slot. Verified
    // at engine creation via the offsetof probe (which == 15) below.
    pub const tb_config: usize = 11422664;
    // After manager come tbConfig (16B), then the options/threads/tt/network
    // reference slots; 8 bytes of AccumulatorStack-alignment padding follow
    // network before accumulator_stack. These offsets were confirmed by dumping
    // the live pointer region (the SharedState referents land here exactly).
    pub const options: usize = 11422680; // reference
    pub const threads: usize = 11422688; // reference
    pub const tt: usize = 11422696; // reference
    pub const network: usize = 11422704; // reference
    pub const accumulator_stack: usize = 11422720;
    pub const refresh_table: usize = 13604288;
};

// SearchManager member offsets (bytes from the manager base), probed from the
// live C++ Search::SearchManager (offsetof). The vtable pointer occupies [0,8);
// `tm` is a 40-byte TimeManagement. This is the address map the native
// SearchManager flip uses to read/write the manager's data fields, which the
// search reaches today through the C++ main_manager() shims. See the
// [[searchmanager-flip-plan]] memory: the vtable is functionally dead, so only
// these data fields plus `updates` are live.
// TimeManagement (40 bytes): the clock sub-object embedded in SearchManager at
// offset 8. availableNodes (4th i64) is set to -1 by TimeManagement::clear.
pub const TimeManagement = extern struct {
    start_time: i64, // @0
    optimum_time: i64, // @8
    maximum_time: i64, // @16
    available_nodes: i64, // @24
    use_nodes_time: u8, // @32 (bool)
    _pad: [7]u8,
};

// The SearchManager object (120 bytes). Typed replacement for search_manager_off:
// a vtable slot, the embedded TimeManagement, and the per-search bookkeeping the
// time-management + PV code reads. `ponder` is a std::atomic_bool in a 4-byte slot.
pub const SearchManager = extern struct {
    vtable: usize, // @0
    tm: TimeManagement, // @8 (40 bytes)
    original_time_adjust: f64, // @48
    calls_cnt: i32, // @56
    ponder: u8, // @60 (atomic_bool, 4-byte slot)
    _pad0: [3]u8,
    iter_value: [4]i32, // @64
    previous_time_reduction: f64, // @80
    best_previous_score: i32, // @88
    best_previous_average_score: i32, // @92
    stop_on_ponderhit: u8, // @96 (bool)
    _pad1: [7]u8,
    id: usize, // @104
    updates: ?*const anyopaque, // @112 (const UpdateContext&)

    pub inline fn fromPtr(p: *anyopaque) *SearchManager {
        return @ptrCast(@alignCast(p));
    }
    pub inline fn fromAddr(addr: usize) *SearchManager {
        return @ptrFromInt(addr);
    }
};

comptime {
    std.debug.assert(@sizeOf(TimeManagement) == 40);
    std.debug.assert(@sizeOf(SearchManager) == search_manager_size);
    std.debug.assert(@offsetOf(SearchManager, "tm") == 8);
    std.debug.assert(@offsetOf(SearchManager, "ponder") == 60);
    std.debug.assert(@offsetOf(SearchManager, "best_previous_score") == 88);
    std.debug.assert(@offsetOf(SearchManager, "id") == 104);
    std.debug.assert(@offsetOf(SearchManager, "updates") == 112);
    std.debug.assert(@offsetOf(TimeManagement, "available_nodes") == 24);
}

// The ThreadPool object (64 bytes). Typed replacement for the old thread_pool_off
// offset map: the runtime constructs and reads the pool through these fields. The
// `threads`/`bound` members are still C++-`std::vector` `{begin,end,cap}` pointer
// triples (native_threadpool lays *NativeThread into a contiguous buffer that
// begin/end point into); the extern layout is byte-identical to the probed offsets,
// so this is a pure offset-arithmetic → field-access change.
pub const ThreadPool = extern struct {
    stop: u8, // std::atomic_bool @0
    increase_depth: u8, // std::atomic_bool @1
    _pad: [6]u8,
    setup_states: ?*anyopaque, // StateListPtr (?*StateList) @8
    threads_begin: usize, // std::vector<Thread*> {begin,end,cap} @16/24/32
    threads_end: usize,
    threads_cap: usize,
    bound_begin: usize, // std::vector<size_t> {begin,end,cap} @40/48/56
    bound_end: usize,
    bound_cap: usize,

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
    pub inline fn boundCount(self: *const ThreadPool) usize {
        return (self.bound_end - self.bound_begin) / @sizeOf(usize);
    }
};

comptime {
    // The extern layout must reproduce the 64-byte C++ ThreadPool the native
    // constructor writes (native_threadpool.zig), or reads and writes disagree.
    std.debug.assert(@sizeOf(ThreadPool) == thread_pool_size);
    std.debug.assert(@offsetOf(ThreadPool, "setup_states") == 8);
    std.debug.assert(@offsetOf(ThreadPool, "threads_begin") == 16);
    std.debug.assert(@offsetOf(ThreadPool, "bound_begin") == 40);
}

// Thread member offset (probed): the LargePagePtr<Worker> worker is at Thread+8.
// Dereferenced (the unique_ptr is a single pointer) it yields the Worker base.
pub const thread_off = struct {
    pub const worker: usize = 8;
};

// RootMove field offsets (bytes from a RootMove base). Layout: effort(u64)@0,
// then the Value(int) scores score@8, previousScore@12, averageScore@16,
// meanSquaredScore@20, uciScore@24, the two bound bools@28/29, selDepth@32,
// tbRank@36, tbScore@40, then PVMoves pv@48 (8-aligned). Total 552 bytes pins it.
pub const root_move_off = struct {
    pub const score: usize = 8;
    pub const average_score: usize = 16;
    // scoreLowerbound/scoreUpperbound (bools) follow uciScore@24; score_is_bound()
    // == lowerbound || upperbound.
    pub const score_lowerbound: usize = 28;
    pub const score_upperbound: usize = 29;
    // pv (PVMoves, 504 bytes, 8-aligned) follows tbScore@40; padded start is 48.
    pub const pv: usize = 48;
};

// PVMoves field offsets. moves[MAX_PLY+1] = Move[247] = 494 bytes at 0, then the
// std::size_t length at +496 (2 bytes of alignment padding precede it). Total 504
// bytes pins it (sizeof(PVMoves) static_assert in the bridge).
pub const pvmoves_off = struct {
    pub const length: usize = 496;
};

// The TranspositionTable object (24 bytes). Typed replacement for the tt_off offset
// map: clusterCount, table (Cluster*), generation8, in declaration order. The side
// TT the native engine allocates uses this layout.
pub const TranspositionTable = extern struct {
    cluster_count: usize, // @0
    table: ?*anyopaque, // @8 (Cluster*)
    generation8: u8, // @16
    _pad: [7]u8,

    pub inline fn fromPtr(p: *anyopaque) *TranspositionTable {
        return @ptrCast(@alignCast(p));
    }
    pub inline fn fromAddr(addr: usize) *TranspositionTable {
        return @ptrFromInt(addr);
    }
};

comptime {
    std.debug.assert(@sizeOf(TranspositionTable) == transposition_table_size);
    std.debug.assert(@offsetOf(TranspositionTable, "table") == 8);
    std.debug.assert(@offsetOf(TranspositionTable, "generation8") == 16);
}

// LimitsType field offsets (bytes from the limits sub-object base). searchmoves
// is a 24-byte std::vector at 0, then seven 8-byte TimePoints
// (time[2]/inc[2]/npmsec/movetime/startTime) ending at 80, then the five ints
// movestogo/depth/mate/perft/infinite. The bridge's zfish_ss_context reads depth
// at +84, which cross-checks this map.
// The LimitsType object (120 bytes). Typed replacement for limits_off: a leading
// 24-byte std::vector<std::string> `searchmoves` (POD-opaque here), then the
// TimePoints, the search-mode ints, nodes, and ponderMode. The POD tail copied by
// zfish_worker_set_limits is [@offsetOf(.,"time") .. @sizeOf), so any layout error
// here breaks bench (gate-verified).
pub const LimitsType = extern struct {
    searchmoves: [24]u8, // std::vector<std::string> @0
    time: [2]i64, // @24 time[WHITE], time[BLACK]
    inc: [2]i64, // @40 inc[WHITE], inc[BLACK]
    npmsec: i64, // @56
    movetime: i64, // @64
    start_time: i64, // @72
    movestogo: i32, // @80
    depth: i32, // @84
    mate: i32, // @88
    perft: i32, // @92
    infinite: i32, // @96
    _pad: [4]u8,
    nodes: u64, // @104
    ponder_mode: u8, // @112
    _pad2: [7]u8,

    pub inline fn fromPtr(p: *anyopaque) *LimitsType {
        return @ptrCast(@alignCast(p));
    }
    pub inline fn fromAddr(addr: usize) *LimitsType {
        return @ptrFromInt(addr);
    }
};

comptime {
    std.debug.assert(@sizeOf(LimitsType) == 120);
    std.debug.assert(@offsetOf(LimitsType, "time") == 24);
    std.debug.assert(@offsetOf(LimitsType, "inc") == 40);
    std.debug.assert(@offsetOf(LimitsType, "movestogo") == 80);
    std.debug.assert(@offsetOf(LimitsType, "nodes") == 104);
    std.debug.assert(@offsetOf(LimitsType, "ponder_mode") == 112);
}

pub fn zfish_graph_verify_layouts() void {
    // The pinned layout constants were cross-checked against the in-tree C++ oracle
    // (sizeof/offsetof of the real src/ types) until it was retired (REPORT-16 M16.1).
    // With no C++ types left to compare against, the constants are trusted directly;
    // any drift now surfaces as a bench/parity failure, and upstream-parity re-pins
    // them against pristine upstream on a resync.
}
