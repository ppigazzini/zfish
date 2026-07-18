// Run the NNUE inference / forward pass, split out of network.zig. Pure compute: reads
// the feature-transformer and per-bucket affine-layer weights from the shared
// nnue_weight_storage leaf and runs the accumulator transform + affine layers.
// No file I/O and no dependency on network.zig, so it sits below the I/O half.
// Bench-verified bit-exact (node signature 2466447 on every arch).

const std = @import("std");
const builtin = @import("builtin");
const position_types = @import("position_types");
const nnue_accumulator_port = @import("nnue_accumulator");
const weight_storage = @import("nnue_weight_storage.zig");
const nnue_affine = @import("nnue_affine.zig");

const affineDpbusd = nnue_affine.affineDpbusd;

const Position = position_types.Position;

const output_scale: i32 = 16;
const layer_stacks: usize = 8;
const cache_line_size: usize = 64;
const transformed_feature_bytes: usize = 1024;
const square_count: usize = 64;
const no_piece: u8 = 0;

const layerPtr = weight_storage.layerPtr;
const ftPtr = weight_storage.ftPtr;

pub const EvalOutput = struct {
    psqt: i32,
    positional: i32,
};

pub const TraceOutput = struct {
    psqt: [layer_stacks]i32,
    positional: [layer_stacks]i32,
    correct_bucket: usize,
};

// Run the NNUE network layer forward pass (NetworkArchitecture::propagate, SFNNv15). Layers:
// fc_0 (affine 1024->32) -> {ac_sqr_0, ac_0} -> fc_1 (affine 64->32) -> {ac_sqr_1, ac_1}
// -> fc_2 (affine 128->1), plus the fwdOut skip term. Bit-exact with the
// SSSE3 integer path. Weights are int8 in the SSSE3-scrambled layout;
// biases int32 linear. WeightScaleBits=6.
fn layerBiases(bucket: usize, idx: usize) [*]const i32 {
    return @ptrCast(@alignCast(layerPtr(bucket, idx, .biases) orelse unreachable));
}
fn layerWeights(bucket: usize, idx: usize) [*]const i8 {
    return @ptrCast(@alignCast(layerPtr(bucket, idx, .weights) orelse unreachable));
}

/// Compute upstream's SqrClippedReLU: min(127, (x*x) >> shift), over 32 outputs.
///
/// Clamping x into i16 first is what keeps the square inside i32 (32767^2 < 2^31), and it is
/// exact rather than an approximation: any x outside i16 squares past the 127 clamp regardless.
/// That is the same property upstream's saturating `packs_epi32` relies on before its
/// `mulhi_epi16`.
inline fn sqrClippedReLU(comptime shift: u5, in: *const [32]i32, out: *[32]u8) void {
    const V = 8;
    const lo: @Vector(V, i32) = @splat(-32768);
    const hi: @Vector(V, i32) = @splat(32767);
    const cap: @Vector(V, i32) = @splat(127);
    const sh: @Vector(V, u5) = @splat(shift);
    var i: usize = 0;
    while (i < 32) : (i += V) {
        const x: @Vector(V, i32) = in[i..][0..V].*;
        const clamped = @max(lo, @min(hi, x));
        const q = @min(cap, (clamped * clamped) >> sh);
        out[i..][0..V].* = @as(@Vector(V, u8), @intCast(q));
    }
}

/// Compute upstream's ClippedReLU: clamp(x >> shift, 0, 127), over 32 outputs.
inline fn clippedReLU(comptime shift: u5, in: *const [32]i32, out: *[32]u8) void {
    const V = 8;
    const zero: @Vector(V, i32) = @splat(0);
    const cap: @Vector(V, i32) = @splat(127);
    const sh: @Vector(V, u5) = @splat(shift);
    var i: usize = 0;
    while (i < 32) : (i += V) {
        const x: @Vector(V, i32) = in[i..][0..V].*;
        out[i..][0..V].* = @as(@Vector(V, u8), @intCast(@max(zero, @min(cap, x >> sh))));
    }
}

fn propagateBucket(bucket: usize, transformed: [*]const u8, nnz: *const nnue_accumulator_port.NnzBitset) i32 {
    // Read the affine-layer weights from the Zig-owned storage. The parse
    // writes this storage and is the sole source, so the eval is bench-verified.
    const fc0_b = layerBiases(bucket, 0);
    const fc0_w = layerWeights(bucket, 0);
    const fc1_b = layerBiases(bucket, 1);
    const fc1_w = layerWeights(bucket, 1);
    const fc2_b = layerBiases(bucket, 2);
    const fc2_w = layerWeights(bucket, 2);

    // Run fc_0: affine 1024 -> 32 (PaddedInputDimensions = 1024).
    var fc0_out: [32]i32 = undefined;
    affineDpbusd(32, true, &fc0_out, fc0_b, fc0_w, transformed[0..1024], nnz);

    // Build SFNNv15 concat[128] = [ac_sqr_0(32) | ac_0(32) | ac_sqr_1(32) | ac_1(32)].
    // ac_sqr_0 / ac_0 over all FC_0_OUTPUTS=32 with WeightScaleBitsLocal = WeightScaleBits+1 = 7:
    // SqrClippedReLU shift = 2*7+7 = 21, ClippedReLU shift = 7.
    var concat: [128]u8 = @splat(0);
    sqrClippedReLU(21, &fc0_out, concat[0..32]);
    clippedReLU(7, &fc0_out, concat[32..64]);

    // Run fc_1: affine 64 -> 32 over [ac_sqr_0 | ac_0].
    var fc1_out: [32]i32 = undefined;
    affineDpbusd(32, false, &fc1_out, fc1_b, fc1_w, concat[0..64], nnz);

    // Apply ac_sqr_1 / ac_1 over FC_1_OUTPUTS=32 with WeightScaleBitsLocal = WeightScaleBits = 6:
    // SqrClippedReLU shift = 2*6+7 = 19, ClippedReLU shift = 6. Written into concat[64..128].
    sqrClippedReLU(19, &fc1_out, concat[64..96]);
    clippedReLU(6, &fc1_out, concat[96..128]);

    // Run fc_2: affine 128 -> 1 over the full concat (OUT=1 -> identity scramble).
    var fc2_out: [1]i32 = undefined;
    affineDpbusd(1, false, &fc2_out, fc2_b, fc2_w, concat[0..128], nnz);

    // Compute SFNNv15: fwdOut = fc_2_out[0] + (fc_0_out[FC_0_OUTPUTS-2] - fc_0_out[FC_0_OUTPUTS-1]),
    // then scale by 600*OutputScale / (HiddenOneVal*(1<<WeightScaleBits)*2) = 9600/16384 via i64.
    const fwd_sum: i64 = @as(i64, fc2_out[0]) + (@as(i64, fc0_out[30]) - @as(i64, fc0_out[31]));
    return @intCast(@divTrunc(fwd_sum * (600 * 16), 128 * 64 * 2));
}

pub fn evaluate(
    pos: *const Position,
    accumulator_stack: *nnue_accumulator_port.AccumulatorStack,
    cache: *nnue_accumulator_port.RefreshCache,
) EvalOutput {
    const piece_count = pieceCount(pos);
    const bucket = (piece_count - 1) / 4;
    const raw = evaluateBucketRaw(pos, accumulator_stack, cache, bucket);
    return .{
        .psqt = @divTrunc(raw.psqt, output_scale),
        .positional = @divTrunc(raw.positional, output_scale),
    };
}

pub fn traceEvaluate(
    pos: *const Position,
    accumulator_stack: *nnue_accumulator_port.AccumulatorStack,
    cache: *nnue_accumulator_port.RefreshCache,
) TraceOutput {
    var output = TraceOutput{
        .psqt = @splat(0),
        .positional = @splat(0),
        .correct_bucket = 0,
    };
    const piece_count = pieceCount(pos);
    output.correct_bucket = (piece_count - 1) / 4;

    var bucket: usize = 0;
    while (bucket < layer_stacks) : (bucket += 1) {
        const raw = evaluateBucketRaw(pos, accumulator_stack, cache, bucket);
        output.psqt[bucket] = @divTrunc(raw.psqt, output_scale);
        output.positional[bucket] = @divTrunc(raw.positional, output_scale);
    }

    return output;
}

fn evaluateBucketRaw(
    pos: *const Position,
    accumulator_stack: *nnue_accumulator_port.AccumulatorStack,
    cache: *nnue_accumulator_port.RefreshCache,
    bucket: usize,
) EvalOutput {
    var transformed: [transformed_feature_bytes]u8 align(cache_line_size) = undefined;
    var nnz: nnue_accumulator_port.NnzBitset = undefined;

    return .{
        .psqt = networkTransformBucket(
            pos,
            accumulator_stack,
            cache,
            bucket,
            @ptrCast(&transformed),
            &nnz,
        ),
        .positional = propagateBucket(bucket, @ptrCast(&transformed), &nnz),
    };
}

fn pieceCount(pos: *const Position) usize {
    const board = &pos.board; // Position.board [64]u8
    var count: usize = 0;
    var sq: usize = 0;
    while (sq < square_count) : (sq += 1) {
        if (board[sq] != no_piece) count += 1;
    }
    return count;
}

fn networkTransformBucket(
    pos: *const Position,
    accumulator_stack: *nnue_accumulator_port.AccumulatorStack,
    cache: *nnue_accumulator_port.RefreshCache,
    bucket: usize,
    transformed_ptr: [*]u8,
    nnz: *nnue_accumulator_port.NnzBitset,
) i32 {
    const ft: *const nnue_accumulator_port.FeatureTransformer = @ptrCast(ftPtr() orelse @panic("feature-transformer storage not initialized"));
    const stm = pos.side_to_move;
    return nnue_accumulator_port.transformBucket(accumulator_stack, pos, ft, cache, bucket, stm, transformed_ptr, nnz);
}

// Cover affineDpbusd's four codegen paths (portable pmaddwd; pmaddubsw+pmaddwd intrinsics on
// the SSSE3 tier; vpdpbusd on VNNI; and the OUT==1 fallback), selected at comptime by the
// -Darch tier. The whole-engine bench (2466447) proves the composite is right but cannot
// localize which path broke, and it only exercises the input distribution the search happens
// to produce. This pins every path against a scalar reference over random inputs -- run it at
// each -Darch to cover the tier that arch selects.
test "affineDpbusd == scalar reference (all layer shapes, sparse and dense)" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15);
    const rnd = prng.random();

    // Iterate {OUT, IN, sparse} for fc0 / fc1 / fc2 as propagateBucket calls them.
    inline for (.{ .{ 32, 1024, true }, .{ 32, 64, false }, .{ 1, 128, false } }) |shape| {
        const OUT: usize = shape[0];
        const IN: usize = shape[1];
        const SPARSE: bool = shape[2];
        const groups = IN / 4;

        var iter: usize = 0;
        while (iter < 32) : (iter += 1) {
            var input: [IN]u8 align(64) = undefined;
            for (&input) |*v| {
                // Draw from the ClippedReLU output range, with ~half zeroed so the sparse skip is hit.
                v.* = if (rnd.boolean()) 0 else rnd.intRangeAtMost(u8, 0, 127);
            }
            var weights: [IN * OUT]i8 = undefined;
            for (&weights) |*w| w.* = rnd.intRangeAtMost(i8, -128, 127);
            var biases: [OUT]i32 = undefined;
            for (&biases) |*b| b.* = rnd.intRangeAtMost(i32, -100000, 100000);

            // Compute the scalar reference over the scrambled layout: weight of output j, group g,
            // sublane m lives at g*OUT*4 + j*4 + m.
            var ref: [OUT]i32 = biases;
            for (0..groups) |g| {
                for (0..OUT) |j| {
                    for (0..4) |m| {
                        ref[j] += @as(i32, input[g * 4 + m]) *
                            @as(i32, weights[g * OUT * 4 + j * 4 + m]);
                    }
                }
            }

            // Build the bitset here to match what the transform records in the engine.
            var nnz: nnue_accumulator_port.NnzBitset = @splat(0);
            if (SPARSE) {
                const in32: [*]const u32 = @ptrCast(@alignCast(&input));
                for (0..groups) |g| {
                    if (in32[g] != 0) nnz[g / 64] |= @as(u64, 1) << @intCast(g % 64);
                }
            }
            var got: [OUT]i32 = undefined;
            affineDpbusd(OUT, SPARSE, &got, &biases, &weights, input[0..IN], &nnz);
            try testing.expectEqualSlices(i32, &ref, &got);
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
