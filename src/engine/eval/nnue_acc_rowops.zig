// NNUE accumulator SIMD row ops.
//
// The vectorized feature-transformer weight-row add/sub kernels split out of
// nnue_accumulator.zig. Fully self-contained: pure @Vector math over the FT
// weight rows, depending only on the two network dimensions (duplicated as tiny
// consts). No *anyopaque, no position_snapshot / nnue_feature, so no cycle. The
// accumulator core imports this and aliases the kernels. Bit-exact: vector +/- is
// the same element-wise i16 op as the scalar loop it replaces (bench 2067208).

const half_dimensions: usize = 1024;
const psqt_buckets: usize = 8;

const acc_vec_width: usize = 32;
comptime {
    if (half_dimensions % acc_vec_width != 0)
        @compileError("half_dimensions must be a multiple of acc_vec_width");
}

inline fn accRow(comptime WT: type, comptime add: bool, target: []i16, weights_row: [*]const WT) void {
    const V = acc_vec_width;
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

test {
    @import("std").testing.refAllDecls(@This());
}
