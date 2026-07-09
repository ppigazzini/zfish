// Search POD data types (M17.3p).
//
// The plain-data structs the search driver threads through: the per-ply
// SearchStack, the correction-history bundle, and the PV / RootMove mirrors.
// Pulled out of position.zig into a std-only leaf so the search-driver and
// history clusters can later be split out without dragging their type
// definitions along (the same leaf-extraction that position_types did for the
// board). position.zig re-exports all four, so its call sites are unchanged.

const std = @import("std");
const root_move = @import("root_move");
const worker_histories = @import("worker_histories");

// Memory mirror of the search Stack (src/search.h): the scalar fields the ported
// search helpers read. The two continuation pointers are concrete PieceToHistory
// pages (M18.7 de-erasure); pv stays opaque (resolved through the PV mirror).
pub const SearchStack = struct {
    pv: ?*anyopaque,
    continuation_history: ?*worker_histories.PieceToHistory,
    continuation_correction_history: ?*worker_histories.PieceToHistory,
    ply: c_int,
    current_move: u16,
    excluded_move: u16,
    static_eval: c_int,
    stat_score: c_int,
    move_count: c_int,
    in_check: bool,
    tt_pv: bool,
    tt_hit: bool,
    follow_pv: bool,
    cutoff_cnt: c_int,
    reduction: c_int,
};

// One CorrectionBundle (src/history.h): the four correction StatsEntry<int16>
// fields, one [2] page per correctionHistory index (indexed by color).
pub const CorrectionBundle = struct {
    pawn: i16,
    minor: i16,
    nonpawn_white: i16,
    nonpawn_black: i16,
};

// PVMoves + RootMove are re-exported from the single canonical definition in
// support/root_move.zig (M18.2 de-mirror). The search indexes the rootMoves vector
// (a contiguous array handed over by worker_state) through these; the canonical def
// carries the same field order/types/offsets plus the search's methods.
pub const PVMoves = root_move.PVMoves;
pub const RootMove = root_move.RootMove;
