// Run the NNUE inference / forward pass, split out of network.zig. Pure compute: reads
// the feature-transformer and per-bucket affine-layer weights from the shared
// nnue_weight_storage leaf and runs the accumulator transform + affine layers.
// No file I/O and no dependency on network.zig, so it sits below the I/O half.
// Bench-verified bit-exact (node signature 2516158 on every arch).

const std = @import("std");
const builtin = @import("builtin");
const position_types = @import("position_types");
const nnue_accumulator_port = @import("nnue_accumulator");
const weight_storage = @import("nnue_weight_storage.zig");
const nnue_affine = @import("nnue_affine.zig");
const nnue_parse = @import("nnue_parse.zig");

// Take the layer activations from their own leaf (nnue_activations.zig): the squared and
// linear clipped ReLUs, in every shape upstream emits for them.
const nnue_activations = @import("nnue_activations.zig");
const sqrClippedReLU = nnue_activations.sqrClippedReLU;
const clippedReLU = nnue_activations.clippedReLU;
const sqrClipPair = nnue_activations.sqrClipPair;
const sqrClipPair128 = nnue_activations.sqrClipPair128;
const sqrClipPair512 = nnue_activations.sqrClipPair512;
const avx512_pair_activations = nnue_activations.avx512_pair_activations;
const sse_pair_activations = nnue_activations.sse_pair_activations;

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
// Return the layer arrays with their true 64-byte alignment (each is its own
// page_alloc block, >=64-aligned by contract): the affine kernels need the
// alignment in the type so non-VEX SSE can fold weight loads into pmaddubsw's
// m128 operand instead of paying a separate movdqu per chunk.
fn layerBiases(bucket: usize, idx: usize) [*]align(cache_line_size) const i32 {
    return @ptrCast(@alignCast(layerPtr(bucket, idx, .biases) orelse unreachable));
}
fn layerWeights(bucket: usize, idx: usize) [*]align(cache_line_size) const i8 {
    return @ptrCast(@alignCast(layerPtr(bucket, idx, .weights) orelse unreachable));
}

fn propagateBucket(bucket: usize, transformed: [*]const u8, nnz: *const nnue_accumulator_port.NnzOut) i32 {
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
    // The four activations write all 128 bytes (concat[0..32], [32..64], [64..96], [96..128])
    // before fc_1 reads [0..64] and fc_2 reads [0..128], so the zero-init was a dead store.
    // On the pair tier each block is written chunk-interleaved and the fc_1/fc_2 weights
    // compensate (see sqrClipPair); the dots, and every value below, are unchanged.
    var concat: [128]u8 = undefined;
    if (comptime avx512_pair_activations) {
        sqrClipPair512(7, &fc0_out, concat[0..32], concat[32..64]);
    } else if (comptime nnue_parse.pair_activations) {
        sqrClipPair(7, &fc0_out, concat[0..32], concat[32..64]);
    } else if (comptime sse_pair_activations) {
        sqrClipPair128(7, &fc0_out, concat[0..32], concat[32..64]);
    } else {
        sqrClippedReLU(21, &fc0_out, concat[0..32]);
        clippedReLU(7, &fc0_out, concat[32..64]);
    }

    // Run fc_1: affine 64 -> 32 over [ac_sqr_0 | ac_0].
    var fc1_out: [32]i32 = undefined;
    affineDpbusd(32, false, &fc1_out, fc1_b, fc1_w, concat[0..64], nnz);

    // Apply ac_sqr_1 / ac_1 over FC_1_OUTPUTS=32 with WeightScaleBitsLocal = WeightScaleBits = 6:
    // SqrClippedReLU shift = 2*6+7 = 19, ClippedReLU shift = 6. Written into concat[64..128].
    if (comptime avx512_pair_activations) {
        sqrClipPair512(6, &fc1_out, concat[64..96], concat[96..128]);
    } else if (comptime nnue_parse.pair_activations) {
        sqrClipPair(6, &fc1_out, concat[64..96], concat[96..128]);
    } else if (comptime sse_pair_activations) {
        sqrClipPair128(6, &fc1_out, concat[64..96], concat[96..128]);
    } else {
        sqrClippedReLU(19, &fc1_out, concat[64..96]);
        clippedReLU(6, &fc1_out, concat[96..128]);
    }

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
    var nnz: nnue_accumulator_port.NnzOut = undefined;

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
    // popcount the cached all-pieces bitboard, as upstream reads count<ALL_PIECES>()
    // (network.cpp:152), rather than scanning all 64 board squares every eval.
    return @popCount(pos.by_type_bb[0]);
}

fn networkTransformBucket(
    pos: *const Position,
    accumulator_stack: *nnue_accumulator_port.AccumulatorStack,
    cache: *nnue_accumulator_port.RefreshCache,
    bucket: usize,
    transformed_ptr: [*]u8,
    nnz: *nnue_accumulator_port.NnzOut,
) i32 {
    const ft: *const nnue_accumulator_port.FeatureTransformer = @ptrCast(ftPtr() orelse @panic("feature-transformer storage not initialized"));
    const stm = pos.side_to_move;
    return nnue_accumulator_port.transformBucket(accumulator_stack, pos, ft, cache, bucket, stm, transformed_ptr, nnz);
}

// Cover affineDpbusd's codegen paths (portable pmaddwd; 128-bit pmaddubsw+pmaddwd on the SSSE3
// tier; 256-bit pmaddubsw+pmaddwd on AVX2; vpdpbusd on VNNI; and the OUT==1 fallback), selected
// at comptime by the -Darch tier. The whole-engine bench (2516158) proves the composite is
// right but cannot localize which path broke, and it only exercises the input distribution the
// search happens to produce. This pins every path against a scalar reference over random
// inputs -- run it at each -Darch to cover the tier that arch selects.
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
            var weights: [IN * OUT]i8 align(64) = undefined;
            for (&weights) |*w| w.* = rnd.intRangeAtMost(i8, -128, 127);
            var biases: [OUT]i32 align(64) = undefined;
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

            // Build here, SCALARLY, whatever the transform records in the engine on this tier
            // -- an index list where the AVX-512 consumer reads one, a bitset elsewhere. Writing
            // it the slow obvious way is the point: this is the gate that catches the vectorized
            // producer disagreeing with its consumer about which chunks are non-zero.
            var nnz: nnue_accumulator_port.NnzOut = undefined;
            if (comptime nnue_accumulator_port.use_nnz_index_list) {
                nnz.count = 0;
                if (SPARSE) {
                    const in32: [*]const u32 = @ptrCast(@alignCast(&input));
                    for (0..groups) |g| {
                        if (in32[g] != 0) {
                            nnz.list[nnz.count] = @intCast(g);
                            nnz.count += 1;
                        }
                    }
                }
            } else {
                nnz = @splat(0);
                if (SPARSE) {
                    const in32: [*]const u32 = @ptrCast(@alignCast(&input));
                    for (0..groups) |g| {
                        if (in32[g] != 0) nnz[g / 64] |= @as(u64, 1) << @intCast(g % 64);
                    }
                }
            }
            var got: [OUT]i32 = undefined;
            affineDpbusd(OUT, SPARSE, &got, &biases, &weights, input[0..IN], &nnz);
            try testing.expectEqualSlices(i32, &ref, &got);
        }
    }
}

// Pin the paired activations against the split reference THROUGH the parse-side index
// map: sqrClipPair must put the value of input i exactly where weightIndexScrambled's
// pair interleave expects it, or the fused packs and the weight scramble disagree and
// the dots silently change. Random inputs cover both i16-saturating magnitudes and the
// negative range (the max(0) side of the clip).
test "sqrClipPair matches the split activations through the pair interleave" {
    if (comptime !nnue_parse.pair_activations) return error.SkipZigTest;
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0xA1B2C3D4E5F60718);
    const rnd = prng.random();

    var iter: usize = 0;
    while (iter < 256) : (iter += 1) {
        var in: [32]i32 = undefined;
        for (&in) |*v| {
            v.* = switch (rnd.intRangeAtMost(u8, 0, 3)) {
                0 => rnd.intRangeAtMost(i32, -300000, 300000),
                1 => rnd.intRangeAtMost(i32, -40000, 40000),
                else => rnd.intRangeAtMost(i32, -5000, 5000),
            };
        }
        inline for (.{ 7, 6 }) |sb| {
            var ref_sqr: [32]u8 = undefined;
            var ref_clip: [32]u8 = undefined;
            sqrClippedReLU(2 * sb + 7, &in, &ref_sqr);
            clippedReLU(sb, &in, &ref_clip);
            var got_sqr: [32]u8 = undefined;
            var got_clip: [32]u8 = undefined;
            // Take the kernel the TIER runs: the two pack widths interleave differently,
            // and each is pinned against its own arm of the same index map.
            if (comptime avx512_pair_activations)
                sqrClipPair512(sb, &in, &got_sqr, &got_clip)
            else
                sqrClipPair(sb, &in, &got_sqr, &got_clip);
            for (0..32) |i| {
                const pos = nnue_parse.weightIndexScrambled(i, 32, 1, true);
                try testing.expectEqual(ref_sqr[i], got_sqr[pos]);
                try testing.expectEqual(ref_clip[i], got_clip[pos]);
            }
        }
    }
}

// Pin the 128-bit paired activations against the split reference in natural order: the
// 128-bit packs concatenate their operands, so byte i of each output must equal the split
// functions' byte i exactly -- no index map. Random inputs cover the i16-saturating
// magnitudes and the negative range (the max(0) side of the clip).
test "sqrClipPair128 matches the split activations in natural order" {
    if (comptime !sse_pair_activations) return error.SkipZigTest;
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE1234567890);
    const rnd = prng.random();

    var iter: usize = 0;
    while (iter < 256) : (iter += 1) {
        var in: [32]i32 = undefined;
        for (&in) |*v| {
            v.* = switch (rnd.intRangeAtMost(u8, 0, 3)) {
                0 => rnd.intRangeAtMost(i32, -300000, 300000),
                1 => rnd.intRangeAtMost(i32, -40000, 40000),
                else => rnd.intRangeAtMost(i32, -5000, 5000),
            };
        }
        inline for (.{ 7, 6 }) |sb| {
            var ref_sqr: [32]u8 = undefined;
            var ref_clip: [32]u8 = undefined;
            sqrClippedReLU(2 * sb + 7, &in, &ref_sqr);
            clippedReLU(sb, &in, &ref_clip);
            var got_sqr: [32]u8 = undefined;
            var got_clip: [32]u8 = undefined;
            sqrClipPair128(sb, &in, &got_sqr, &got_clip);
            try testing.expectEqualSlices(u8, &ref_sqr, &got_sqr);
            try testing.expectEqualSlices(u8, &ref_clip, &got_clip);
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
