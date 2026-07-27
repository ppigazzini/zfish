// WorkerHistories.
//
// Hold the per-Worker history tables (butterfly / low-ply / capture / continuation /
// correction + tt-move history) plus the shared-history reference. worker_layout embeds
// it directly as WorkerLayout.histories.
//
// Lay out a contiguous int16-array prefix (no vtable; mainHistory is at offset 0) followed by
// the shared-history reference. Use it only through a Worker pointer, so the field
// order/sizes must byte-match the WorkerLayout histories slot; worker_layout comptime-
// asserts @sizeOf against worker_histories_bytes.

const std = @import("std");
const shared_history_types = @import("shared_history_types");

// Define the history-table dimensions.
pub const hist_color_nb: usize = 2;
pub const hist_uint16: usize = 65536;
pub const hist_low_ply: usize = 5;
pub const hist_piece_nb: usize = 16;
pub const hist_square_nb: usize = 64;
pub const hist_piece_type_nb: usize = 8;
pub const hist_pieceto: usize = hist_piece_nb * hist_square_nb; // PieceToHistory page = [16][64]

// Model one [16][64] continuation-history page: a stat_entry-per-(piece,to) table. The
// search stack's continuation_history points at one such page (indexed pc*64+to).
pub const PieceToHistory = [hist_pieceto]i16;

// Fix the field order with `extern`: this file's contract is that the i16 tables form a
// contiguous prefix with mainHistory at offset 0, and a plain Zig struct does not honour that --
// it orders by descending alignment, so the 8-byte `shared_history` pointer is placed among the
// tables and skews every one after it off the cache line. `extern` pins declaration order, so
// the four tables sit back to back; each size is a multiple of 64, so all four stay line-aligned
// behind main_history's align(64). Size is unchanged (3031104): the trailing pointer fits in the
// padding the block already carried.
pub const WorkerHistories = extern struct {
    // Pin the first table to a cache line so the whole run of tables is line-aligned. This is a
    // plain Zig struct, so the layout is Zig's: it orders by descending alignment, which floats
    // the 8-byte `shared_history` pointer to offset 0 and pushes every i16 table to offset 8 --
    // 8 bytes into a line, for the life of the process. That also silently broke this file's own
    // "mainHistory is at offset 0" invariant. Giving the first table align(64) makes it the
    // highest-alignment field, so it lands at offset 0 and the rest follow it: every table size
    // here (262144 / 655360 / 16384) is a multiple of 64, so one align fixes all four. The struct
    // size is unchanged -- the tail padding it would have taken anyway absorbs the pointer.
    main_history: [hist_color_nb * hist_uint16]i16 align(64), // ButterflyHistory [2][65536]
    low_ply_history: [hist_low_ply * hist_uint16]i16, // LowPlyHistory [5][65536]
    capture_history: [hist_piece_nb * hist_square_nb * hist_piece_type_nb]i16, // [16][64][8]
    continuation_correction_history: [hist_pieceto * hist_pieceto]i16, // [16][64]->[16][64]
    tt_move_history: i16,
    shared_history: ?*shared_history_types.SharedHistories,
};

// Element count of the shared continuationHistory table: [2][2] of PieceToHistory pages.
// Held in SharedHistories (shared per NUMA node, atomic entries) to match upstream
// search.h:342 / history.h:244 -- not per-Worker, so lazy-SMP threads share the updates.
pub const continuation_history_len: usize = 2 * 2 * hist_pieceto * hist_pieceto;

// Compute the offset of the shared_history reference WITHIN WorkerHistories (a Zig-owned
// struct, so Zig's choice); the constructor + clear path address it through the typed field,
// and this offset survives only for the worker_construct address cross-check test.
pub const worker_shared_history_off = @offsetOf(WorkerHistories, "shared_history");

test {
    @import("std").testing.refAllDecls(@This());
}
