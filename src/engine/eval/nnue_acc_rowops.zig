// NNUE accumulator SIMD row ops.
//
// The vectorized feature-transformer weight-row add/sub kernels split out of
// nnue_accumulator.zig. Fully self-contained: pure @Vector math over the FT
// weight rows, depending only on the two network dimensions (duplicated as tiny
// consts). No *anyopaque, no position_snapshot / nnue_feature, so no cycle. The
// accumulator core imports this and aliases the kernels. Bit-exact: vector +/- is
// the same element-wise i16 op as the scalar loop it replaces (bench 2466447).

const half_dimensions: usize = 1024;
const psqt_buckets: usize = 8;

/// Lane count for the FT weight-row add/sub tile. Swept as the only variable (5c93ad7fe): 64
/// beats 32 by +3.4%/+4.7%, 128 is flat, 256 spills. Independent of nnue_acc_layout's
/// transform_vec_width.
const row_tile_width: usize = 64;
comptime {
    if (half_dimensions % row_tile_width != 0)
        @compileError("half_dimensions must be a multiple of row_tile_width");
}

inline fn accRow(comptime WT: type, comptime add: bool, target: []i16, weights_row: [*]const WT) void {
    const V = row_tile_width;
    const Vi16 = @Vector(V, i16);
    var d: usize = 0;
    while (d < half_dimensions) : (d += V) {
        const t: Vi16 = target.ptr[d..][0..V].*;
        const wraw: @Vector(V, WT) = weights_row[d..][0..V].*;
        const w: Vi16 = wraw; // i8 -> i16 widen; i16 identity
        target.ptr[d..][0..V].* = if (add) t + w else t - w;
    }
}

pub fn applyAccumulatorDeltaI16(
    target: []i16,
    source: []const i16,
    removed: []const u32,
    added: []const u32,
    weights: [*]const i16,
) void {
    @memcpy(target, source);
    for (removed) |index| accRow(i16, false, target, weights + @as(usize, index) * half_dimensions);
    for (added) |index| accRow(i16, true, target, weights + @as(usize, index) * half_dimensions);
}

pub fn applyAccumulatorDeltaInPlaceI16(
    target: []i16,
    removed: []const u32,
    added: []const u32,
    weights: [*]const i16,
) void {
    for (removed) |index| accRow(i16, false, target, weights + @as(usize, index) * half_dimensions);
    for (added) |index| accRow(i16, true, target, weights + @as(usize, index) * half_dimensions);
}

pub fn applyAccumulatorDeltaI8(
    target: []i16,
    source: []const i16,
    removed: []const u32,
    added: []const u32,
    weights: [*]const i8,
) void {
    @memcpy(target, source);
    for (removed) |index| accRow(i8, false, target, weights + @as(usize, index) * half_dimensions);
    for (added) |index| accRow(i8, true, target, weights + @as(usize, index) * half_dimensions);
}

pub fn accumulateRowsI8(target: []i16, rows: []const u32, weights: [*]const i8) void {
    for (rows) |index| accRow(i8, true, target, weights + @as(usize, index) * half_dimensions);
}

pub fn applyPsqtDelta(
    target: []i32,
    source: []const i32,
    removed: []const u32,
    added: []const u32,
    weights: [*]const i32,
) void {
    @memcpy(target, source);

    for (removed) |index| {
        const row_offset = @as(usize, index) * psqt_buckets;
        var bucket: usize = 0;
        while (bucket < psqt_buckets) : (bucket += 1) {
            target[bucket] -= weights[row_offset + bucket];
        }
    }

    for (added) |index| {
        const row_offset = @as(usize, index) * psqt_buckets;
        var bucket: usize = 0;
        while (bucket < psqt_buckets) : (bucket += 1) {
            target[bucket] += weights[row_offset + bucket];
        }
    }
}

pub fn applyPsqtDeltaInPlace(
    target: []i32,
    removed: []const u32,
    added: []const u32,
    weights: [*]const i32,
) void {
    for (removed) |index| {
        const row_offset = @as(usize, index) * psqt_buckets;
        var bucket: usize = 0;
        while (bucket < psqt_buckets) : (bucket += 1) {
            target[bucket] -= weights[row_offset + bucket];
        }
    }

    for (added) |index| {
        const row_offset = @as(usize, index) * psqt_buckets;
        var bucket: usize = 0;
        while (bucket < psqt_buckets) : (bucket += 1) {
            target[bucket] += weights[row_offset + bucket];
        }
    }
}

pub fn accumulatePsqtRows(target: []i32, rows: []const u32, weights: [*]const i32) void {
    for (rows) |index| {
        const row_offset = @as(usize, index) * psqt_buckets;
        var bucket: usize = 0;
        while (bucket < psqt_buckets) : (bucket += 1) {
            target[bucket] += weights[row_offset + bucket];
        }
    }
}

// Hand-vectorized port of upstream Stockfish's `apply_combined` (nnue_accumulator.cpp):
// one combined accumulator (HalfKA + Threats), loaded per tile ONCE into a register,
// with both feature sets' removed/added weight rows applied in-register (psq int16 rows
// via i16 add/sub, threat int8 rows widened to i16), then stored ONCE. Replaces the two
// separate load/store round-trips (one per feature) of the split-accumulator design.
// Integer add/sub commute under 2's-complement i16 wrap, so the final tile value equals
// source + Σpsq_added − Σpsq_removed + Σthr_added − Σthr_removed regardless of order:
// bit-exact with the prior two-accumulator path (signature 2466447).
pub fn applyCombinedDelta(
    target: []i16,
    source: []const i16,
    psq_removed: []const u32,
    psq_added: []const u32,
    thr_removed: []const u32,
    thr_added: []const u32,
    psq_weights: [*]const i16,
    thr_weights: [*]const i8,
) void {
    const V = row_tile_width;
    const Vi16 = @Vector(V, i16);
    var d: usize = 0;
    while (d < half_dimensions) : (d += V) {
        var acc: Vi16 = source.ptr[d..][0..V].*;
        for (psq_removed) |index| {
            const w: Vi16 = (psq_weights + @as(usize, index) * half_dimensions)[d..][0..V].*;
            acc -= w;
        }
        for (psq_added) |index| {
            const w: Vi16 = (psq_weights + @as(usize, index) * half_dimensions)[d..][0..V].*;
            acc += w;
        }
        for (thr_removed) |index| {
            const wraw: @Vector(V, i8) = (thr_weights + @as(usize, index) * half_dimensions)[d..][0..V].*;
            acc -= @as(Vi16, wraw); // i8 -> i16 widen
        }
        for (thr_added) |index| {
            const wraw: @Vector(V, i8) = (thr_weights + @as(usize, index) * half_dimensions)[d..][0..V].*;
            acc += @as(Vi16, wraw);
        }
        target.ptr[d..][0..V].* = acc;
    }
}

// psqt counterpart of applyCombinedDelta: one combined psqtAccumulation, both feature
// sets applied (psq + threat psqt weights, both i32). Scalar -- PSQTBuckets is tiny.
pub fn applyCombinedPsqtDelta(
    target: []i32,
    source: []const i32,
    psq_removed: []const u32,
    psq_added: []const u32,
    thr_removed: []const u32,
    thr_added: []const u32,
    psq_weights: [*]const i32,
    thr_weights: [*]const i32,
) void {
    @memcpy(target, source);
    applyPsqtDeltaInPlace(target, psq_removed, psq_added, psq_weights);
    applyPsqtDeltaInPlace(target, thr_removed, thr_added, thr_weights);
}

test {
    @import("std").testing.refAllDecls(@This());
}
