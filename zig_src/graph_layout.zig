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
    pub const root_moves: usize = 11421064;
    pub const root_depth: usize = 11421088;
    pub const root_delta: usize = 11421092;
    pub const thread_idx: usize = 11421600;
    pub const reductions: usize = 11421632;
    pub const manager: usize = 11422656;
    pub const tt: usize = 11422664; // reference (derived)
    pub const network: usize = 11422672; // reference (derived)
    pub const accumulator_stack: usize = 11422720;
    pub const refresh_table: usize = 13604288;
};

extern fn zfish_graph_layout_size(which: c_int) usize;

const Pinned = struct { which: c_int, value: usize, name: []const u8 };

const pinned = [_]Pinned{
    .{ .which = 0, .value = worker_size, .name = "Worker" },
    .{ .which = 1, .value = worker_align, .name = "alignof(Worker)" },
    .{ .which = 2, .value = thread_size, .name = "Thread" },
    .{ .which = 3, .value = thread_pool_size, .name = "ThreadPool" },
    .{ .which = 4, .value = engine_size, .name = "Engine" },
    .{ .which = 5, .value = uci_engine_size, .name = "UCIEngine" },
    .{ .which = 6, .value = shared_state_size, .name = "SharedState" },
    .{ .which = 7, .value = search_manager_size, .name = "SearchManager" },
    .{ .which = 8, .value = position_size, .name = "Position" },
    .{ .which = 9, .value = state_info_size, .name = "StateInfo" },
    .{ .which = 10, .value = transposition_table_size, .name = "TranspositionTable" },
    .{ .which = 11, .value = accumulator_stack_size, .name = "AccumulatorStack" },
    .{ .which = 12, .value = accumulator_caches_size, .name = "AccumulatorCaches" },
    .{ .which = 13, .value = root_move_size, .name = "RootMove" },
};

pub export fn zfish_graph_verify_layouts() void {
    for (pinned) |entry| {
        const actual = zfish_graph_layout_size(entry.which);
        if (actual != entry.value) {
            std.debug.print(
                "graph layout drift: {s} pinned {d} but C++ reports {d}\n",
                .{ entry.name, entry.value, actual },
            );
            @panic("object-graph layout changed; update graph_layout.zig before allocating in Zig");
        }
    }
}
