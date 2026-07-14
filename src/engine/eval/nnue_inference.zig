// NNUE inference / forward pass, split out of network.zig. Pure compute: reads
// the feature-transformer and per-bucket affine-layer weights from the shared
// nnue_weight_storage leaf and runs the accumulator transform + affine layers.
// No file I/O and no dependency on network.zig, so it sits below the I/O half.
// Bench-verified bit-exact (node signature 2466447 on every arch).

const std = @import("std");
const builtin = @import("builtin");
const position_types = @import("position_types");
const nnue_accumulator_port = @import("nnue_accumulator");
const weight_storage = @import("nnue_weight_storage.zig");

// The affine int8 dot has a real codegen lever: on AVX-512-VNNI the whole 4-way dot +
// accumulate is one `vpdpbusd`, where the portable `@Vector` fallback needs a broadcast, an
// i16 multiply (`vpmullw`), and a shuffle-heavy 4-way reduction (profiled at ~61% of search
// cost). LLVM will NOT auto-emit `vpdpbusd` from the portable pattern, so it is a small inline
// asm seam, gated on the target actually having the feature and validated bit-identical by the
// affineDpbusd scalar-reference test (run at `-Darch=x86-64-vnni512`).
const has_vnni = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vnni);

const Position = position_types.Position;

const output_scale: c_int = 16;
const layer_stacks: usize = 8;
const cache_line_size: usize = 64;
const transformed_feature_bytes: usize = 1024;
const square_count: usize = 64;
const no_piece: u8 = 0;

const layerPtr = weight_storage.layerPtr;
const ftPtr = weight_storage.ftPtr;

pub const EvalOutput = struct {
    psqt: c_int,
    positional: c_int,
};

pub const TraceOutput = struct {
    psqt: [layer_stacks]c_int,
    positional: [layer_stacks]c_int,
    correct_bucket: usize,
};

// NNUE network layer forward pass (NetworkArchitecture::propagate, SFNNv15). Layers:
// fc_0 (affine 1024->32) -> {ac_sqr_0, ac_0} -> fc_1 (affine 64->32) -> {ac_sqr_1, ac_1}
// -> fc_2 (affine 128->1), plus the fwdOut skip term. Bit-exact with the
// SSSE3 integer path. Weights are int8 in the SSSE3-scrambled layout;
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
// is BIT-EXACT with the prior scalar loop (signature stays 2466447 on every arch);
// it just lets LLVM emit vector multiplies/shuffles (and dpbusd-class ops) instead of
// a scalar MAC. `input.len` must be the padded input dim (a multiple of 4); zero tail
// lanes contribute nothing.
// `vpdpbusd %b, %a, %acc`: acc(i32×16) += the 4-way int8 dot of a(u8×64) and b(i8×64) over
// its 16 groups of 4 (acc[k] += Σ_m a[4k+m]·b[4k+m]). One VNNI instruction; bit-identical to
// the scalar 4-way MAC (verified 0/1000 in isolation + the affineDpbusd test on a vnni build).
inline fn vpdpbusd16(acc: @Vector(16, i32), a: @Vector(64, u8), b: @Vector(64, i8)) @Vector(16, i32) {
    return asm (
        \\vpdpbusd %[b], %[a], %[acc]
        : [acc] "=v" (-> @Vector(16, i32)),
        : [_] "0" (acc),
          [a] "v" (a),
          [b] "v" (b),
    );
}

// VNNI affine: the scrambled layout stores each group's OUT×4 weights contiguously, so each
// 16-output chunk of a group is exactly one `vpdpbusd` with the group's 4 input bytes broadcast
// across all 16 outputs (a[4k+m] == input[g*4+m] for every k). Zero shuffles, zero i16 multiply.
inline fn affineVnni(comptime OUT: usize, out: *[OUT]i32, biases: [*]const i32, weights: [*]const i8, input: []const u8) void {
    const chunks = OUT / 16;
    var acc: [chunks]@Vector(16, i32) = undefined;
    inline for (0..chunks) |c| acc[c] = biases[c * 16 ..][0..16].*;
    const groups = input.len / 4;
    var g: usize = 0;
    while (g < groups) : (g += 1) {
        const in4: [4]u8 = input[g * 4 ..][0..4].*;
        const a: @Vector(64, u8) = @bitCast(@as(@Vector(16, u32), @splat(@as(u32, @bitCast(in4)))));
        inline for (0..chunks) |c| {
            const b: @Vector(64, i8) = weights[g * OUT * 4 + c * 64 ..][0..64].*;
            acc[c] = vpdpbusd16(acc[c], a, b);
        }
    }
    inline for (0..chunks) |c| out[c * 16 ..][0..16].* = acc[c];
}

inline fn affineDpbusd(
    comptime OUT: usize,
    out: *[OUT]i32,
    biases: [*]const i32,
    weights: [*]const i8,
    input: []const u8,
) void {
    if (comptime (has_vnni and OUT % 16 == 0)) {
        affineVnni(OUT, out, biases, weights, input);
        return;
    }
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
    return @ptrCast(@alignCast(layerPtr(bucket, idx, 0) orelse unreachable));
}
fn layerWeights(bucket: usize, idx: c_int) [*]const i8 {
    return @ptrCast(@alignCast(layerPtr(bucket, idx, 1) orelse unreachable));
}

fn propagateBucket(bucket: usize, transformed: [*]const u8) c_int {
    // Read the affine-layer weights from the Zig-owned storage. The parse
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

    // SFNNv15 concat[128] = [ac_sqr_0(32) | ac_0(32) | ac_sqr_1(32) | ac_1(32)].
    // ac_sqr_0 / ac_0 over all FC_0_OUTPUTS=32 with WeightScaleBitsLocal = WeightScaleBits+1 = 7:
    // SqrClippedReLU shift = 2*7+7 = 21, ClippedReLU shift = 7.
    var concat: [128]u8 = [_]u8{0} ** 128;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const sq: i64 = @as(i64, fc0_out[i]) * @as(i64, fc0_out[i]);
        concat[i] = @intCast(@min(@as(i64, 127), sq >> 21));
        concat[32 + i] = @intCast(@max(@as(i32, 0), @min(@as(i32, 127), fc0_out[i] >> 7)));
    }

    // fc_1: affine 64 -> 32 over [ac_sqr_0 | ac_0].
    var fc1_out: [32]i32 = undefined;
    affineDpbusd(32, &fc1_out, fc1_b, fc1_w, concat[0..64]);

    // ac_sqr_1 / ac_1 over FC_1_OUTPUTS=32 with WeightScaleBitsLocal = WeightScaleBits = 6:
    // SqrClippedReLU shift = 2*6+7 = 19, ClippedReLU shift = 6. Written into concat[64..128].
    var j: usize = 0;
    while (j < 32) : (j += 1) {
        const sq: i64 = @as(i64, fc1_out[j]) * @as(i64, fc1_out[j]);
        concat[64 + j] = @intCast(@min(@as(i64, 127), sq >> 19));
        concat[96 + j] = @intCast(@max(@as(i32, 0), @min(@as(i32, 127), fc1_out[j] >> 6)));
    }

    // fc_2: affine 128 -> 1 over the full concat (OUT=1 -> identity scramble).
    var fc2_out: [1]i32 = undefined;
    affineDpbusd(1, &fc2_out, fc2_b, fc2_w, concat[0..128]);

    // SFNNv15: fwdOut = fc_2_out[0] + (fc_0_out[FC_0_OUTPUTS-2] - fc_0_out[FC_0_OUTPUTS-1]),
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
    const ft: *const nnue_accumulator_port.FeatureTransformer = @ptrCast(ftPtr() orelse @panic("feature-transformer storage not initialized"));
    const stm = pos.side_to_move;
    return nnue_accumulator_port.transformBucket(accumulator_stack, pos, ft, cache, bucket, stm, transformed_ptr);
}

// Bit-identity harness for affineDpbusd. The scalar reference computes the same affine
// over the scrambled weight layout by definition; the integer 4-way dot is order- and
// codegen-independent, so ANY SIMD reformulation of affineDpbusd MUST match this exactly.
// This is what holds bench 2466447 and localizes a codegen regression below the engine.
fn affineScalarRef(comptime OUT: usize, out: *[OUT]i32, biases: [*]const i32, weights: [*]const i8, input: []const u8) void {
    for (0..OUT) |j| {
        var acc: i32 = biases[j];
        for (input, 0..) |x, i| {
            const g = i / 4;
            const m = i % 4;
            acc += @as(i32, x) * @as(i32, weights[g * OUT * 4 + j * 4 + m]);
        }
        out[j] = acc;
    }
}

test "affineDpbusd is bit-identical to the scalar reference (random inputs, all layer shapes)" {
    var prng = std.Random.DefaultPrng.init(0xA1FFEE);
    const rand = prng.random();
    inline for (.{ .{ 32, 1024 }, .{ 32, 64 }, .{ 1, 128 } }) |cfg| {
        const OUT: usize = cfg[0];
        const LEN: usize = cfg[1];
        var iter: usize = 0;
        while (iter < 100) : (iter += 1) {
            var input: [LEN]u8 = undefined;
            for (&input) |*x| x.* = rand.intRangeAtMost(u8, 0, 127); // ClippedReLU output range
            var weights: [(LEN / 4) * OUT * 4]i8 = undefined;
            for (&weights) |*w| w.* = rand.intRangeAtMost(i8, -128, 127);
            var biases: [OUT]i32 = undefined;
            for (&biases) |*b| b.* = rand.intRangeAtMost(i32, -100_000, 100_000);
            var got: [OUT]i32 = undefined;
            var want: [OUT]i32 = undefined;
            affineDpbusd(OUT, &got, &biases, &weights, &input);
            affineScalarRef(OUT, &want, &biases, &weights, &input);
            try std.testing.expectEqual(want, got);
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
