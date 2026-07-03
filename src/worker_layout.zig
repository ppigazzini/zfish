// Byte-exact Zig mirror of Stockfish's Search::Worker (src/search.h).
//
// Worker is the largest object in the graph (13.2 MB, one per thread) and is
// the heart of the from-scratch Zig object graph: to construct it in Zig we
// must reproduce its memory layout field-for-field. This extern struct mirrors
// every member in declaration order, sized from the offsets pinned in
// graph_layout.zig. Aggregate members whose internals do not yet matter for
// allocation (the history tables, the embedded Position/StateInfo, the
// AccumulatorStack/Caches, std::vector RootMoves, etc.) are represented as raw
// byte storage of the exact C++ footprint; scalars, atomics and reference
// slots get real types so later construction code can address them directly.
//
// The comptime block asserts the total size, alignment and every probed member
// offset against graph_layout.zig. Any drift between this mirror and the C++
// class fails the build, before the layout verifier ever runs at startup.

const std = @import("std");
const graph_layout = @import("graph_layout.zig");

const off = graph_layout.worker_off;

// History-table footprints, derived from the gaps in the offset map. These are
// fixed-size POD arrays in C++ (Stats<...>), so raw byte storage reproduces
// them exactly.
const butterfly_history_bytes = off.low_ply_history - off.main_history; // 262144
const low_ply_history_bytes = off.capture_history - off.low_ply_history; // 655360
const capture_history_bytes = off.continuation_history - off.capture_history; // 16384
const continuation_history_bytes = off.continuation_correction_history - off.continuation_history; // 8388608
const correction_history_bytes = off.tt_move_history - off.continuation_correction_history; // 2097152
const tt_move_history_bytes = off.shared_history - off.tt_move_history; // 8

// Scalar-region footprints between probed anchors.
const limits_bytes = off.pv_idx - off.limits; // LimitsType, 120
const root_pos_bytes = graph_layout.position_size; // Position, 1032
const root_state_bytes = graph_layout.state_info_size; // StateInfo, 192
const root_moves_bytes = off.root_depth - off.root_moves; // std::vector<RootMove>, 24
const last_iteration_pv_bytes = off.thread_idx - (off.root_delta + 4); // PVMoves, 504
const numa_access_token_bytes = off.reductions - (off.thread_idx + 24); // 8
// manager(8) + tbConfig + options-ref(8) + threads-ref(8) precede tt.
const tb_config_bytes = off.tt - off.manager - 24; // Tablebases::Config, 16
// AccumulatorStack is over-aligned, so padding follows the network reference.
const pre_accumulator_pad = off.accumulator_stack - (off.network + 8); // 8
const max_moves = (off.manager - off.reductions) / @sizeOf(i32); // std::array<int, MAX_MOVES> -> 256
const accumulator_stack_bytes = off.refresh_table - off.accumulator_stack; // 2181568
const refresh_table_bytes = graph_layout.worker_size - off.refresh_table; // 278528

pub const Worker = extern struct {
    // Public history tables (updatable by the search statistics).
    main_history: [butterfly_history_bytes]u8 align(graph_layout.worker_align),
    low_ply_history: [low_ply_history_bytes]u8,
    capture_history: [capture_history_bytes]u8,
    continuation_history: [continuation_history_bytes]u8,
    continuation_correction_history: [correction_history_bytes]u8,
    tt_move_history: [tt_move_history_bytes]u8,
    shared_history: ?*anyopaque, // SharedHistories& reference slot

    // Private search bookkeeping.
    limits: [limits_bytes]u8, // LimitsType
    pv_idx: usize,
    pv_last: usize,
    nodes: std.atomic.Value(u64),
    tb_hits: std.atomic.Value(u64),
    best_move_changes: std.atomic.Value(u64),
    sel_depth: i32,
    nmp_min_ply: i32,
    optimism: [2]i32, // Value optimism[COLOR_NB]

    root_pos: [root_pos_bytes]u8, // Position
    root_state: [root_state_bytes]u8, // StateInfo
    root_moves: [root_moves_bytes]u8, // RootMoves (std::vector<RootMove>)
    root_depth: i32,
    root_delta: i32,
    last_iteration_pv: [last_iteration_pv_bytes]u8, // PVMoves

    thread_idx: usize,
    numa_thread_idx: usize,
    numa_total: usize,
    numa_access_token: [numa_access_token_bytes]u8,
    reductions: [max_moves]i32, // std::array<int, MAX_MOVES>

    manager: ?*anyopaque, // std::unique_ptr<ISearchManager>
    tb_config: [tb_config_bytes]u8, // Tablebases::Config
    options: ?*anyopaque, // const OptionsMap& reference slot
    threads: ?*anyopaque, // ThreadPool& reference slot
    tt: ?*anyopaque, // TranspositionTable& reference slot
    network: ?*anyopaque, // network reference slot
    accumulator_pad: [pre_accumulator_pad]u8, // AccumulatorStack alignment padding

    accumulator_stack: [accumulator_stack_bytes]u8, // Eval::NNUE::AccumulatorStack
    refresh_table: [refresh_table_bytes]u8, // Eval::NNUE::AccumulatorCaches
};

comptime {
    // Total footprint and alignment must match the live C++ object exactly.
    std.debug.assert(@sizeOf(Worker) == graph_layout.worker_size);
    std.debug.assert(@alignOf(Worker) == graph_layout.worker_align);

    // Every probed member must land on its captured offset.
    std.debug.assert(@offsetOf(Worker, "main_history") == off.main_history);
    std.debug.assert(@offsetOf(Worker, "low_ply_history") == off.low_ply_history);
    std.debug.assert(@offsetOf(Worker, "capture_history") == off.capture_history);
    std.debug.assert(@offsetOf(Worker, "continuation_history") == off.continuation_history);
    std.debug.assert(@offsetOf(Worker, "continuation_correction_history") == off.continuation_correction_history);
    std.debug.assert(@offsetOf(Worker, "tt_move_history") == off.tt_move_history);
    std.debug.assert(@offsetOf(Worker, "shared_history") == off.shared_history);
    std.debug.assert(@offsetOf(Worker, "limits") == off.limits);
    std.debug.assert(@offsetOf(Worker, "pv_idx") == off.pv_idx);
    std.debug.assert(@offsetOf(Worker, "pv_last") == off.pv_last);
    std.debug.assert(@offsetOf(Worker, "nodes") == off.nodes);
    std.debug.assert(@offsetOf(Worker, "tb_hits") == off.tb_hits);
    std.debug.assert(@offsetOf(Worker, "best_move_changes") == off.best_move_changes);
    std.debug.assert(@offsetOf(Worker, "sel_depth") == off.sel_depth);
    std.debug.assert(@offsetOf(Worker, "nmp_min_ply") == off.nmp_min_ply);
    std.debug.assert(@offsetOf(Worker, "optimism") == off.optimism);
    std.debug.assert(@offsetOf(Worker, "root_pos") == off.root_pos);
    std.debug.assert(@offsetOf(Worker, "root_moves") == off.root_moves);
    std.debug.assert(@offsetOf(Worker, "root_depth") == off.root_depth);
    std.debug.assert(@offsetOf(Worker, "root_delta") == off.root_delta);
    std.debug.assert(@offsetOf(Worker, "thread_idx") == off.thread_idx);
    std.debug.assert(@offsetOf(Worker, "reductions") == off.reductions);
    std.debug.assert(@offsetOf(Worker, "manager") == off.manager);
    std.debug.assert(@offsetOf(Worker, "options") == off.options);
    std.debug.assert(@offsetOf(Worker, "threads") == off.threads);
    std.debug.assert(@offsetOf(Worker, "tt") == off.tt);
    std.debug.assert(@offsetOf(Worker, "network") == off.network);
    std.debug.assert(@offsetOf(Worker, "accumulator_stack") == off.accumulator_stack);
    std.debug.assert(@offsetOf(Worker, "refresh_table") == off.refresh_table);
}
