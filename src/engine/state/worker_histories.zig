// WorkerHistories.
//
// The per-Worker history tables (butterfly / low-ply / capture / continuation /
// correction + tt-move history) plus the shared-history reference. graph_layout embeds
// it directly as WorkerLayout.histories.
//
// A contiguous int16-array prefix (no vtable; mainHistory is at offset 0) followed by
// the shared-history reference. Only ever used through a Worker pointer, so the field
// order/sizes must byte-match the WorkerLayout histories slot; graph_layout comptime-
// asserts @sizeOf against worker_histories_bytes.

const std = @import("std");
const shared_history_types = @import("shared_history_types");

// History-table dimensions.
pub const hist_color_nb: usize = 2;
pub const hist_uint16: usize = 65536;
pub const hist_low_ply: usize = 5;
pub const hist_piece_nb: usize = 16;
pub const hist_square_nb: usize = 64;
pub const hist_piece_type_nb: usize = 8;
pub const hist_pieceto: usize = hist_piece_nb * hist_square_nb; // PieceToHistory page = [16][64]

// One [16][64] continuation-history page: a stat_entry-per-(piece,to) table. The
// search stack's continuation_history points at one such page (indexed pc*64+to).
pub const PieceToHistory = [hist_pieceto]i16;

pub const WorkerHistories = struct {
    main_history: [hist_color_nb * hist_uint16]i16, // ButterflyHistory [2][65536]
    low_ply_history: [hist_low_ply * hist_uint16]i16, // LowPlyHistory [5][65536]
    capture_history: [hist_piece_nb * hist_square_nb * hist_piece_type_nb]i16, // [16][64][8]
    continuation_history: [2 * 2 * hist_pieceto * hist_pieceto]i16, // [2][2] of [16][64]->[16][64]
    continuation_correction_history: [hist_pieceto * hist_pieceto]i16, // [16][64]->[16][64]
    tt_move_history: i16,
    shared_history: ?*shared_history_types.SharedHistories,
};

// Offset of the shared_history reference WITHIN WorkerHistories (a Zig-owned struct, so
// Zig's choice); the constructor + clear path address it through the typed field, and
// this offset survives only for the worker_construct address cross-check test.
pub const worker_shared_history_off = @offsetOf(WorkerHistories, "shared_history");

test {
    @import("std").testing.refAllDecls(@This());
}
