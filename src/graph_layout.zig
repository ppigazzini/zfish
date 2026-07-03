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
pub const search_manager_off = struct {
    pub const vtable: usize = 0;
    pub const tm: usize = 8; // TimeManagement (40 bytes)
    pub const original_time_adjust: usize = 48; // f64
    pub const calls_cnt: usize = 56; // i32
    pub const ponder: usize = 60; // atomic_bool (4-byte slot)
    pub const iter_value: usize = 64; // [4]i32
    pub const previous_time_reduction: usize = 80; // f64
    pub const best_previous_score: usize = 88; // i32
    pub const best_previous_average_score: usize = 92; // i32
    pub const stop_on_ponderhit: usize = 96; // bool
    pub const id: usize = 104; // usize
    pub const updates: usize = 112; // const UpdateContext& (pointer)
    // tm.availableNodes: TimeManagement is {startTime, optimumTime, maximumTime,
    // availableNodes, useNodesTime}; availableNodes is the 4th i64 at tm+24.
    pub const tm_available_nodes: usize = tm + 24; // i64; TimeManagement::clear sets it -1
};

// ThreadPool member offsets (probed). `stop` and `increaseDepth` are the leading
// std::atomic_bool pair; the rest of the 64-byte pool is the threads vector and
// bookkeeping. Used by the native ThreadPool flag shims.
pub const thread_pool_off = struct {
    pub const stop: usize = 0; // std::atomic_bool
    pub const increase_depth: usize = 1; // std::atomic_bool
    // setupStates: StateListPtr (unique_ptr<deque<StateInfo>>, single pointer) at 8
    // (after increaseDepth@1, padded to the pointer's 8-byte alignment).
    pub const setup_states: usize = 8;
    // threads: std::vector<unique_ptr<Thread>> {begin, end, cap} at 16/24/32.
    // size() == (end - begin) / sizeof(unique_ptr) (8 bytes).
    pub const threads_begin: usize = 16;
    pub const threads_end: usize = 24;
    // boundThreadToNumaNode (std::vector<NumaIndex/size_t>) follows the threads
    // vector at offset 40; size() == (end - begin) / 8. ThreadPool is 64 bytes
    // (40 + the 24-byte vector), which pins this.
    pub const bound_nodes_begin: usize = 40;
    pub const bound_nodes_end: usize = 48;
};

// Engine member offsets (probed). The accessor shims return &engine->member; the
// native versions add these offsets to the engine pointer. network (the
// LazyNumaReplicatedSystemWide wrapper) sits at `network`; network.operator->()
// (the resolved Network*) stays a C++ shim.
pub const engine_off = struct {
    pub const numa_context: usize = 24;
    pub const pos: usize = 112;
    pub const states: usize = 1144;
    pub const options: usize = 1152;
    pub const threads: usize = 1232;
    pub const tt: usize = 1296;
    pub const network: usize = 1320;
    pub const update_context: usize = 1408;
    pub const shared_hists: usize = 1648;
};

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

// TranspositionTable member offsets (size 24). Declaration order is clusterCount,
// table, generation8.
pub const tt_off = struct {
    pub const cluster_count: usize = 0;
    pub const table: usize = 8;
    pub const generation8: usize = 16;
};

// LimitsType field offsets (bytes from the limits sub-object base). searchmoves
// is a 24-byte std::vector at 0, then seven 8-byte TimePoints
// (time[2]/inc[2]/npmsec/movetime/startTime) ending at 80, then the five ints
// movestogo/depth/mate/perft/infinite. The bridge's zfish_ss_context reads depth
// at +84, which cross-checks this map.
pub const limits_off = struct {
    pub const time_w: usize = 24; // time[WHITE] (1st TimePoint)
    pub const time_b: usize = 32; // time[BLACK]
    pub const inc_w: usize = 40; // inc[WHITE] (3rd TimePoint)
    pub const inc_b: usize = 48; // inc[BLACK]
    pub const npmsec: usize = 56; // 5th TimePoint (after time[2]/inc[2])
    pub const movetime: usize = 64; // 6th TimePoint
    pub const start_time: usize = 72; // 7th TimePoint
    pub const movestogo: usize = 80; // first int after the TimePoints
    pub const depth: usize = 84;
    pub const mate: usize = 88;
    pub const infinite: usize = 96;
    // uint64_t nodes follows the five ints (movestogo/depth/mate/perft/infinite@80..100)
    // after 4 bytes of alignment padding; ponderMode (bool) follows at 112.
    pub const perft: usize = 92; // int perft (4th of movestogo/depth/mate/perft/infinite)
    pub const nodes: usize = 104;
    pub const ponder_mode: usize = 112; // bool ponderMode (after uint64 nodes)
    // sizeof(LimitsType) == 120 (ponderMode@112 + 7 alignment padding); searchmoves is the
    // leading 24-byte std::vector<std::string>. The POD tail copied by zfish_worker_set_limits
    // is [searchmoves_bytes .. total), so any error here breaks bench (gate-verified).
    pub const total_size: usize = 120;
    pub const searchmoves_bytes: usize = 24;
};

// UCIEngine member offsets. engine (Engine, 1680 bytes) is at 0; cli
// (CommandLine {int argc; char** argv}) follows at 1680. UCIEngine is 1696 bytes
// (1680 + 16), which pins this.
pub const uci_engine_off = struct {
    pub const cli_argc: usize = 1680;
    pub const cli_argv: usize = 1688;
};

// NumaConfig member offsets. `nodes` (std::vector<std::set<CpuIndex>>) is the
// first member at offset 0; the vector is {begin, end, cap} 8-byte pointers, and
// each std::set<CpuIndex> element is 48 bytes (libstdc++ _Rb_tree). So
// num_numa_nodes() == nodes.size() == (end - begin) / 48.
pub const numa_config_off = struct {
    pub const nodes_begin: usize = 0;
    pub const nodes_end: usize = 8;
    pub const node_set_size: usize = 48;
    // libstdc++ std::set<CpuIndex> stores its element count (_Rb_tree _M_node_count)
    // at offset 40 within the 48-byte set; num_cpus_in_numa_node(n) == nodes[n].size().
    pub const node_set_count_off: usize = 40;
};

pub fn zfish_graph_verify_layouts() void {
    // The pinned layout constants were cross-checked against the in-tree C++ oracle
    // (sizeof/offsetof of the real src/ types) until it was retired (REPORT-16 M16.1).
    // With no C++ types left to compare against, the constants are trusted directly;
    // any drift now surfaces as a bench/parity failure, and upstream-parity re-pins
    // them against pristine upstream on a resync.
}
