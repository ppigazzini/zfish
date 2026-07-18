// Define the search POD data types.
//
// Collect the plain-data structs the search driver threads through: the per-ply
// SearchStack, the correction-history bundle, and the PV / RootMove types.
// position.zig re-exports all four, so its call sites are unchanged.

const std = @import("std");
const root_move = @import("root_move");
const worker_histories = @import("worker_histories");
const correction_bundle = @import("correction_bundle");

// List the scalar fields the search helpers read. Keep the two continuation pointers as
// concrete PieceToHistory pages; keep pv opaque (resolved through the PV type).
pub const SearchStack = struct {
    pv: ?*root_move.PVMoves,
    continuation_history: ?*worker_histories.PieceToHistory,
    continuation_correction_history: ?*worker_histories.PieceToHistory,
    ply: i32,
    current_move: u16,
    excluded_move: u16,
    static_eval: i32,
    stat_score: i32,
    move_count: i32,
    in_check: bool,
    tt_pv: bool,
    tt_hit: bool,
    follow_pv: bool,
    cutoff_cnt: i32,
    reduction: i32,
};

// Re-export CorrectionBundle from the correction_bundle module as the
// canonical name.
pub const CorrectionBundle = correction_bundle.CorrectionBundle;

// Re-export PVMoves + RootMove from the single canonical definition in
// support/root_move.zig. The search indexes the rootMoves array
// (handed over by worker_state) through these; the canonical def
// carries the same field order/types/offsets plus the search's methods.
pub const PVMoves = root_move.PVMoves;
pub const RootMove = root_move.RootMove;

test {
    @import("std").testing.refAllDecls(@This());
}
