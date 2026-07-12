// NNUE inference / forward pass, split out of network.zig. Pure compute: reads
// the feature-transformer and per-bucket affine-layer weights from the shared
// nnue_weight_storage leaf and runs the accumulator transform + affine layers.
// No file I/O and no dependency on network.zig, so it sits below the I/O half.
// Bench-verified bit-exact (node signature 2067208 on every arch).

const std = @import("std");
const position_types = @import("position_types");
const nnue_accumulator_port = @import("nnue_accumulator");
const weight_storage = @import("nnue_weight_storage.zig");

const Position = position_types.Position;

const output_scale: c_int = 16;
const layer_stacks: usize = 8;
const cache_line_size: usize = 64;
const transformed_feature_bytes: usize = 1024;
const square_count: usize = 64;
const no_piece: u8 = 0;

const nativeLayerPtr = weight_storage.nativeLayerPtr;
const nativeFtPtr = weight_storage.nativeFtPtr;

pub const EvalOutput = struct {
    psqt: c_int,
    positional: c_int,
};

pub const TraceOutput = struct {
    psqt: [layer_stacks]c_int,
    positional: [layer_stacks]c_int,
    correct_bucket: usize,
};

// NNUE network layer forward pass (NetworkArchitecture::propagate), ported to
// Zig. Layers: fc_0 (affine 1024->32) -> {ac_sqr_0, ac_0} -> fc_1 (affine 62->32)
// -> ac_1 -> fc_2 (affine 32->1), plus the fwdOut bias term. Bit-exact with the
// C++ SSSE3 path (integer math). Weights are int8 in the SSSE3-scrambled layout;
// biases int32 linear. WeightScaleBits=6.
// Affine layer over the int8 weights' dpbusd (SSSE3/AVX2/AVX-512-VNNI) tiling.
// The scrambled physical index weightIndexScrambled(j*padded+i,padded,OUT) reduces,
// for padded%4==0, to  phys = (i/4)*OUT*4 + j*4 + (i%4)  -- i.e. for input group
// g=i/4 and sublane m=i%4 the weight of output j lives at g*OUT*4 + j*4 + m, so each
// group's OUT*4 weight bytes are CONTIGUOUS. Load that block, broadcast the group's
// 4 input bytes across it, multiply (input<=127, weight in [-128,127] -> product fits
// i16), then sum each group of 4 sublanes into the i32 accumulator.
//
// Integer sums are order-independent and no partial ever leaves i32's range, so this
// is BIT-EXACT with the prior scalar loop (signature stays 2067208 on every arch);
// it just lets LLVM emit vector multiplies/shuffles (and dpbusd-class ops) instead of
// a scalar MAC. `input.len` must be the padded input dim (a multiple of 4); zero tail
// lanes contribute nothing.
inline fn affineDpbusd(
    comptime OUT: usize,
    out: *[OUT]i32,
    biases: [*]const i32,
    weights: [*]const i8,
    input: []const u8,
) void {
    const N = OUT * 4;
    const Vi16 = @Vector(N, i16);
    const Vo = @Vector(OUT, i32);
    // broadcast mask: lane k takes input sublane k%4 (repeats the 4 input bytes OUT×).
    const rep_mask: @Vector(N, i32) = comptime blk: {
        var m: [N]i32 = undefined;
        for (0..N) |k| m[k] = @intCast(k % 4);
        break :blk m;
    };
    // deinterleave masks: mask[sub] gathers lanes {j*4+sub : j in 0..OUT}.
    const deint: [4]@Vector(OUT, i32) = comptime blk: {
        var d: [4]@Vector(OUT, i32) = undefined;
        for (0..4) |sub| {
            var col: [OUT]i32 = undefined;
            for (0..OUT) |j| col[j] = @intCast(j * 4 + sub);
            d[sub] = col;
        }
        break :blk d;
    };
    var acc: Vo = biases[0..OUT].*;
    const groups = input.len / 4;
    var g: usize = 0;
    while (g < groups) : (g += 1) {
        const in4: @Vector(4, i16) = .{
            @intCast(input[g * 4]),     @intCast(input[g * 4 + 1]),
            @intCast(input[g * 4 + 2]), @intCast(input[g * 4 + 3]),
        };
        const inpat: Vi16 = @shuffle(i16, in4, @as(@Vector(4, i16), undefined), rep_mask);
        const wq: @Vector(N, i8) = weights[g * N ..][0..N].*;
        const w16: Vi16 = wq; // widen i8 -> i16
        const prod: Vi16 = inpat * w16; // exact: |input|<=127, |weight|<=128
        inline for (0..4) |sub| {
            const s: @Vector(OUT, i16) = @shuffle(i16, prod, @as(Vi16, undefined), deint[sub]);
            const s32: Vo = s; // widen i16 -> i32 before summing (4 partials can exceed i16)
            acc += s32;
        }
    }
    out.* = acc;
}

fn layerBiases(bucket: usize, idx: c_int) [*]const i32 {
    return @ptrCast(@alignCast(nativeLayerPtr(bucket, idx, 0) orelse unreachable));
}
fn layerWeights(bucket: usize, idx: c_int) [*]const i8 {
    return @ptrCast(@alignCast(nativeLayerPtr(bucket, idx, 1) orelse unreachable));
}

fn propagateBucket(bucket: usize, transformed: [*]const u8) c_int {
    // Read the affine-layer weights from the Zig-owned native storage. The native parse
    // writes this storage and is the sole source, so the eval is bench-verified.
    const fc0_b = layerBiases(bucket, 0);
    const fc0_w = layerWeights(bucket, 0);
    const fc1_b = layerBiases(bucket, 1);
    const fc1_w = layerWeights(bucket, 1);
    const fc2_b = layerBiases(bucket, 2);
    const fc2_w = layerWeights(bucket, 2);

    // fc_0: affine 1024 -> 32 (PaddedInputDimensions = 1024).
    var fc0_out: [32]i32 = undefined;
    affineDpbusd(32, &fc0_out, fc0_b, fc0_w, transformed[0..1024]);

    // ac_sqr_0 / ac_0 on the first FC_0_OUTPUTS=31 outputs, concatenated into 62.
    // upstream 7c7fe322e: ac_sqr_0/ac_0 use WeightScaleBitsLocal = WeightScaleBits+1 = 7.
    var combined: [64]u8 = [_]u8{0} ** 64;
    var i: usize = 0;
    while (i < 31) : (i += 1) {
        const sq: i64 = @as(i64, fc0_out[i]) * @as(i64, fc0_out[i]);
        combined[i] = @intCast(@min(@as(i64, 127), sq >> 21)); // SqrClippedReLU: >> (2*7+7)
        combined[31 + i] = @intCast(@max(@as(i32, 0), @min(@as(i32, 127), fc0_out[i] >> 7))); // ClippedReLU (WSB+1)
    }

    // fc_1: affine 62 -> 32 (PaddedInputDimensions = 64). Pass the full padded 64:
    // combined[62..64] are the zero-init pad, so the extra lanes add nothing.
    var fc1_out: [32]i32 = undefined;
    affineDpbusd(32, &fc1_out, fc1_b, fc1_w, combined[0..64]);

    // ac_1: ClippedReLU 32.
    var ac1: [32]u8 = undefined;
    var k: usize = 0;
    while (k < 32) : (k += 1) ac1[k] = @intCast(@max(@as(i32, 0), @min(@as(i32, 127), fc1_out[k] >> 6)));

    // fc_2: affine 32 -> 1 (PaddedInputDimensions = 32). OUT=1 makes the scramble the
    // identity (phys == i); the dpbusd path handles it uniformly.
    var fc2_out: [1]i32 = undefined;
    affineDpbusd(1, &fc2_out, fc2_b, fc2_w, ac1[0..32]);

    // upstream 7c7fe322e: fwdOut = fc_2_out[0] + fc_0_out[FC_0_OUTPUTS], then scale the sum by
    // 600*OutputScale / (HiddenOneVal*(1<<WeightScaleBits)*2) = 9600/16384, via i64.
    const fwd_sum: i64 = @as(i64, fc2_out[0]) + @as(i64, fc0_out[31]);
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
        .psqt = [_]c_int{0} ** layer_stacks,
        .positional = [_]c_int{0} ** layer_stacks,
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

    return .{
        .psqt = networkTransformBucket(
            pos,
            accumulator_stack,
            cache,
            bucket,
            @ptrCast(&transformed),
        ),
        .positional = propagateBucket(bucket, @ptrCast(&transformed)),
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
) c_int {
    const ft: *const nnue_accumulator_port.FeatureTransformer = @ptrCast(nativeFtPtr() orelse @panic("native feature-transformer storage not initialized"));
    const stm = pos.side_to_move;
    return nnue_accumulator_port.transformBucket(accumulator_stack, pos, ft, cache, bucket, stm, transformed_ptr);
}

test {
    @import("std").testing.refAllDecls(@This());
}
