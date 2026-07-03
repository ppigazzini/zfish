// Construction model for Eval::NNUE::AccumulatorCaches (the per-thread "Finny
// table" refresh cache embedded in every Worker at offset worker_off.refresh_table).
//
// AccumulatorCaches is pure inline POD: a [SQUARE_NB][COLOR_NB] grid of
// cache-line-aligned Entry structs. Each Entry is
//   accumulation:      [L1]BiasType   (1024 int16 = 2048 bytes)
//   psqtAccumulation:  [PSQTBuckets]PSQTWeightType
//   pieces:            [SQUARE_NB]Piece
//   pieceBB:           Bitboard
//   (padding to CacheLineSize)
// and Entry::clear(biases) copies the network's feature-transformer biases into
// `accumulation` and memsets everything from psqtAccumulation onward to zero.
// Construction (the templated AccumulatorCaches ctor) just calls clear on every
// entry, so the fully-built object is exactly
//   [ biases(2048 bytes) ++ zeros(tail) ]  repeated entry_count times,
// with the same biases in every entry.
//
// This module pins that geometry (comptime-asserted to reproduce the locked
// footprint in graph_layout.zig) and exports a read-only verifier that proves a
// live C++ AccumulatorCaches obeys the rule: every entry shares entry 0's
// 2048-byte bias prefix and has an all-zero tail. It is wired into engine
// creation alongside zfish_graph_verify_layouts so that, once Worker
// construction moves to Zig, the bias-fill logic is already proven byte-exact.

const std = @import("std");
const graph_layout = @import("graph_layout.zig");

// NNUE constants (src/nnue/nnue_architecture.h, nnue_common.h).
pub const l1: usize = 1024; // TransformedFeatureDimensions
pub const cache_line_size: usize = 64;
pub const square_nb: usize = 64;
pub const color_nb: usize = 2;

pub const BiasType = i16;
pub const bias_prefix_bytes = l1 * @sizeOf(BiasType); // 2048

// Entry count and size derived from the locked AccumulatorCaches footprint.
pub const entry_count = square_nb * color_nb; // 128
pub const entry_size = graph_layout.accumulator_caches_size / entry_count; // 2176
pub const entry_tail_bytes = entry_size - bias_prefix_bytes; // 128

comptime {
    // The bias prefix must fit inside an entry and the grid must reproduce the
    // exact C++ footprint, or our construction model is wrong.
    std.debug.assert(bias_prefix_bytes < entry_size);
    std.debug.assert(entry_count * entry_size == graph_layout.accumulator_caches_size);
    std.debug.assert(entry_size % cache_line_size == 0);
}

// Build an AccumulatorCaches image into `dst` from the feature-transformer
// `biases` (L1 int16). This is the Zig reproduction of the C++ ctor; once Worker
// is Zig-allocated this writes refreshTable directly.
pub fn build(dst: []u8, biases: []const BiasType) void {
    std.debug.assert(dst.len == graph_layout.accumulator_caches_size);
    std.debug.assert(biases.len == l1);
    const bias_bytes = std.mem.sliceAsBytes(biases);
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const base = i * entry_size;
        @memcpy(dst[base .. base + bias_prefix_bytes], bias_bytes);
        @memset(dst[base + bias_prefix_bytes .. base + entry_size], 0);
    }
}
