// Search POD data types (M17.3p).
//
// The plain-data structs the search driver threads through: the per-ply
// SearchStack, the correction-history bundle, and the PV / RootMove mirrors.
// Pulled out of position.zig into a std-only leaf so the search-driver and
// history clusters can later be split out without dragging their type
// definitions along (the same leaf-extraction that position_types did for the
// board). position.zig re-exports all four, so its call sites are unchanged.

const std = @import("std");

// Memory mirror of the search Stack (src/search.h): the scalar fields the ported
// search helpers read; the three history pointers are opaque (resolved through the
// worker/shared-history mirrors).
pub const SearchStack = struct {
    pv: ?*anyopaque,
    continuation_history: ?*anyopaque,
    continuation_correction_history: ?*anyopaque,
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

// Memory mirror of Search::PVMoves (src/search.h): a Move array + length.
pub const PVMoves = struct {
    moves: [247]u16,
    length: usize,
};

// Memory mirror of Search::RootMove (src/search.h). RootMove is a standard-layout
// POD (its pv is the inline PVMoves, not a heap vector), so the rootMoves vector is
// a contiguous array the Zig search indexes through a base pointer handed over by
// worker_state. Field order/types/offsets match the RootMove layout the search reads.
pub const RootMove = struct {
    effort: u64,
    score: i32,
    previous_score: i32,
    average_score: i32,
    mean_squared_score: i32,
    uci_score: i32,
    score_lowerbound: bool,
    score_upperbound: bool,
    sel_depth: i32,
    tb_rank: i32,
    tb_score: i32,
    pv: PVMoves,
};
