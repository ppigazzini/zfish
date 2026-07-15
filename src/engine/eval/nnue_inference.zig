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

// LLVM will not lower the portable @Vector int8-dot pattern to `vpdpbusd`, so on an
// AVX-512-VNNI target the affine uses an inline-asm seam; other tiers keep the pmaddwd
// reduction. Both paths are bit-identical (pure integer dot), so bench holds 2466447.
const has_vnni = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vnni);

// SSSE3 tier (no AVX2): the pmaddwd reduction is 128-bit and widens the u8 inputs to i16;
// pmaddubsw multiplies u8*i8 directly, twice the lanes per register. Reached through the
// LLVM intrinsic rather than inline asm: asm is an optimization barrier LLVM cannot
// schedule or reorder across, the intrinsic it can.
const use_maddubs = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3) and
    !std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

const pmaddubsw128 = struct {
    extern fn @"llvm.x86.ssse3.pmadd.ub.sw.128"(@Vector(16, i8), @Vector(16, i8)) @Vector(8, i16);
}.@"llvm.x86.ssse3.pmadd.ub.sw.128";

const vpdpbusd512 = struct {
    extern fn @"llvm.x86.avx512.vpdpbusd.512"(@Vector(16, i32), @Vector(16, i32), @Vector(16, i32)) @Vector(16, i32);
}.@"llvm.x86.avx512.vpdpbusd.512";

const pmaddwd128 = struct {
    extern fn @"llvm.x86.sse2.pmadd.wd"(@Vector(8, i16), @Vector(8, i16)) @Vector(4, i32);
}.@"llvm.x86.sse2.pmadd.wd";

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
// acc(i32x16) += the 4-way int8 dot of a(u8x64) and b(i8x64) over its 16 groups of 4.
inline fn vpdpbusd16(acc: @Vector(16, i32), a: @Vector(64, u8), b: @Vector(64, i8)) @Vector(16, i32) {
    return vpdpbusd512(acc, @bitCast(a), @bitCast(b));
}

/// Yields the input groups a layer must accumulate: every group when dense, only the
/// non-zero ones when sparse. Sparse walks upstream's NNZ bitset -- recorded by the feature
/// transformer, which had the values in a register -- so the per-group data-dependent test
/// does not exist. Indices ascend either way, so the accumulation order, and the result, is
/// unchanged.
///
/// It yields an index rather than taking the accumulator, so the accumulator stays a local
/// the caller can keep in registers.
fn GroupIter(comptime sparse: bool) type {
    return struct {
        nnz: *const nnue_accumulator_port.NnzBitset,
        groups: usize,
        w: usize = 0,
        bits: u64 = 0,
        g: usize = 0,

        inline fn next(self: *@This()) ?usize {
            if (sparse) {
                while (self.bits == 0) {
                    if (self.w >= nnue_accumulator_port.nnz_word_count) return null;
                    self.bits = self.nnz[self.w];
                    self.w += 1;
                }
                const found = (self.w - 1) * 64 + @ctz(self.bits);
                self.bits &= self.bits - 1;
                return found;
            }
            if (self.g >= self.groups) return null;
            const found = self.g;
            self.g += 1;
            return found;
        }
    };
}

// VNNI affine: the scrambled layout stores each group's OUT*4 weights contiguously, so a
// 16-output chunk is one vpdpbusd with the group's 4 input bytes broadcast across the 16
// outputs. Honors the sparse-input skip.
inline fn affineVnni(
    comptime OUT: usize,
    comptime sparse: bool,
    out: *[OUT]i32,
    biases: [*]const i32,
    weights: [*]const i8,
    input: []const u8,
    nnz: *const nnue_accumulator_port.NnzBitset,
) void {
    const chunks = OUT / 16;
    var acc: [chunks]@Vector(16, i32) = undefined;
    inline for (0..chunks) |c| acc[c] = biases[c * 16 ..][0..16].*;
    var it = GroupIter(sparse){ .nnz = nnz, .groups = input.len / 4 };
    while (it.next()) |g| {
        const in4: [4]u8 = input[g * 4 ..][0..4].*;
        const a: @Vector(64, u8) = @bitCast(@as(@Vector(16, u32), @splat(@as(u32, @bitCast(in4)))));
        inline for (0..chunks) |c| {
            const b: @Vector(64, i8) = weights[g * OUT * 4 + c * 64 ..][0..64].*;
            acc[c] = vpdpbusd16(acc[c], a, b);
        }
    }
    inline for (0..chunks) |c| out[c * 16 ..][0..16].* = acc[c];
}

// SSSE3 affine via the LLVM pmaddubsw/pmaddwd intrinsics: each 128-bit weight chunk (16
// bytes = 4 outputs' 4 sublanes) is one pmaddubsw of the group's 4 input bytes (broadcast
// x4), then pmaddwd against ones folds each output's two i16 partials into its i32.
// pmaddubsw saturates at i16, but our products span [-16256,16129] and a pair sums inside
// i16, so it never saturates -- bit-identical to the pmaddwd path.
inline fn affineSsse3(
    comptime OUT: usize,
    comptime sparse: bool,
    out: *[OUT]i32,
    biases: [*]const i32,
    weights: [*]const i8,
    input: []const u8,
    nnz: *const nnue_accumulator_port.NnzBitset,
) void {
    var acc: [OUT]i32 = biases[0..OUT].*;
    const ones: @Vector(8, i16) = @splat(1);
    var it = GroupIter(sparse){ .nnz = nnz, .groups = input.len / 4 };
    while (it.next()) |g| {
        const in4: [4]u8 = input[g * 4 ..][0..4].*;
        const inpat: @Vector(16, i8) = @bitCast(@as(@Vector(4, u32), @splat(@as(u32, @bitCast(in4)))));
        inline for (0..OUT / 4) |c| {
            const w: @Vector(16, i8) = weights[g * OUT * 4 + c * 16 ..][0..16].*;
            const p: @Vector(4, i32) = pmaddwd128(pmaddubsw128(inpat, w), ones);
            acc[c * 4 ..][0..4].* = @as(@Vector(4, i32), acc[c * 4 ..][0..4].*) + p;
        }
    }
    out.* = acc;
}

inline fn affineDpbusd(
    comptime OUT: usize,
    comptime sparse: bool,
    out: *[OUT]i32,
    biases: [*]const i32,
    weights: [*]const i8,
    input: []const u8,
    nnz: *const nnue_accumulator_port.NnzBitset,
) void {
    if (comptime (has_vnni and OUT % 16 == 0)) {
        affineVnni(OUT, sparse, out, biases, weights, input, nnz);
        return;
    }
    if (comptime (use_maddubs and OUT % 4 == 0)) {
        affineSsse3(OUT, sparse, out, biases, weights, input, nnz);
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
    // Two-stage vpmaddwd reduction masks. Stage 1: deinterleave the N interleaved
    // products into even/odd halves so LLVM matches widen+mul+add as vpmaddwd(inpat,
    // w16) -> N/2 i32 partials (madd[2j], madd[2j+1] are output j's two partials).
    // Stage 2: gather the even/odd partials and add -> OUT i32.
    const N2 = N / 2;
    const even_n: @Vector(N2, i32) = comptime blk: {
        var m: [N2]i32 = undefined;
        for (0..N2) |k| m[k] = @intCast(2 * k);
        break :blk m;
    };
    const odd_n: @Vector(N2, i32) = comptime blk: {
        var m: [N2]i32 = undefined;
        for (0..N2) |k| m[k] = @intCast(2 * k + 1);
        break :blk m;
    };
    const even_out: @Vector(OUT, i32) = comptime blk: {
        var m: [OUT]i32 = undefined;
        for (0..OUT) |k| m[k] = @intCast(2 * k);
        break :blk m;
    };
    const odd_out: @Vector(OUT, i32) = comptime blk: {
        var m: [OUT]i32 = undefined;
        for (0..OUT) |k| m[k] = @intCast(2 * k + 1);
        break :blk m;
    };
    var acc: Vo = biases[0..OUT].*;
    var it = GroupIter(sparse){ .nnz = nnz, .groups = input.len / 4 };
    while (it.next()) |g| {
        const in4: @Vector(4, i16) = .{
            @intCast(input[g * 4]),     @intCast(input[g * 4 + 1]),
            @intCast(input[g * 4 + 2]), @intCast(input[g * 4 + 3]),
        };
        const inpat: Vi16 = @shuffle(i16, in4, @as(@Vector(4, i16), undefined), rep_mask);
        const wq: @Vector(N, i8) = weights[g * N ..][0..N].*;
        const w16: Vi16 = wq; // widen i8 -> i16
        const Vh = @Vector(N2, i32);
        // Stage 1 = vpmaddwd(inpat, w16): the deinterleave+widen+mul+add folds into a
        // single pmaddwd per register (products are exact: |in|<=127, |w|<=128).
        const in_e: @Vector(N2, i16) = @shuffle(i16, inpat, @as(Vi16, undefined), even_n);
        const in_o: @Vector(N2, i16) = @shuffle(i16, inpat, @as(Vi16, undefined), odd_n);
        const w_e: @Vector(N2, i16) = @shuffle(i16, w16, @as(Vi16, undefined), even_n);
        const w_o: @Vector(N2, i16) = @shuffle(i16, w16, @as(Vi16, undefined), odd_n);
        const madd: Vh = @as(Vh, in_e) * @as(Vh, w_e) + @as(Vh, in_o) * @as(Vh, w_o);
        // Stage 2: sum output j's two i32 partials.
        const m_e: Vo = @shuffle(i32, madd, @as(Vh, undefined), even_out);
        const m_o: Vo = @shuffle(i32, madd, @as(Vh, undefined), odd_out);
        acc += m_e + m_o;
    }
    out.* = acc;
}

fn layerBiases(bucket: usize, idx: c_int) [*]const i32 {
    return @ptrCast(@alignCast(layerPtr(bucket, idx, 0) orelse unreachable));
}
fn layerWeights(bucket: usize, idx: c_int) [*]const i8 {
    return @ptrCast(@alignCast(layerPtr(bucket, idx, 1) orelse unreachable));
}

/// Upstream's SqrClippedReLU: min(127, (x*x) >> shift), over 32 outputs.
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

/// Upstream's ClippedReLU: clamp(x >> shift, 0, 127), over 32 outputs.
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

fn propagateBucket(bucket: usize, transformed: [*]const u8, nnz: *const nnue_accumulator_port.NnzBitset) c_int {
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
    affineDpbusd(32, true, &fc0_out, fc0_b, fc0_w, transformed[0..1024], nnz);

    // SFNNv15 concat[128] = [ac_sqr_0(32) | ac_0(32) | ac_sqr_1(32) | ac_1(32)].
    // ac_sqr_0 / ac_0 over all FC_0_OUTPUTS=32 with WeightScaleBitsLocal = WeightScaleBits+1 = 7:
    // SqrClippedReLU shift = 2*7+7 = 21, ClippedReLU shift = 7.
    var concat: [128]u8 = [_]u8{0} ** 128;
    sqrClippedReLU(21, &fc0_out, concat[0..32]);
    clippedReLU(7, &fc0_out, concat[32..64]);

    // fc_1: affine 64 -> 32 over [ac_sqr_0 | ac_0].
    var fc1_out: [32]i32 = undefined;
    affineDpbusd(32, false, &fc1_out, fc1_b, fc1_w, concat[0..64], nnz);

    // ac_sqr_1 / ac_1 over FC_1_OUTPUTS=32 with WeightScaleBitsLocal = WeightScaleBits = 6:
    // SqrClippedReLU shift = 2*6+7 = 19, ClippedReLU shift = 6. Written into concat[64..128].
    sqrClippedReLU(19, &fc1_out, concat[64..96]);
    clippedReLU(6, &fc1_out, concat[96..128]);

    // fc_2: affine 128 -> 1 over the full concat (OUT=1 -> identity scramble).
    var fc2_out: [1]i32 = undefined;
    affineDpbusd(1, false, &fc2_out, fc2_b, fc2_w, concat[0..128], nnz);

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
) c_int {
    const ft: *const nnue_accumulator_port.FeatureTransformer = @ptrCast(ftPtr() orelse @panic("feature-transformer storage not initialized"));
    const stm = pos.side_to_move;
    return nnue_accumulator_port.transformBucket(accumulator_stack, pos, ft, cache, bucket, stm, transformed_ptr, nnz);
}

// affineDpbusd has four codegen paths (portable pmaddwd; pmaddubsw+pmaddwd intrinsics on
// the SSSE3 tier; vpdpbusd on VNNI; and the OUT==1 fallback), selected at comptime by the
// -Darch tier. The whole-engine bench (2466447) proves the composite is right but cannot
// localize which path broke, and it only exercises the input distribution the search happens
// to produce. This pins every path against a scalar reference over random inputs -- run it at
// each -Darch to cover the tier that arch selects.
test "affineDpbusd == scalar reference (all layer shapes, sparse and dense)" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15);
    const rnd = prng.random();

    // {OUT, IN, sparse} for fc0 / fc1 / fc2 as propagateBucket calls them.
    inline for (.{ .{ 32, 1024, true }, .{ 32, 64, false }, .{ 1, 128, false } }) |shape| {
        const OUT: usize = shape[0];
        const IN: usize = shape[1];
        const SPARSE: bool = shape[2];
        const groups = IN / 4;

        var iter: usize = 0;
        while (iter < 32) : (iter += 1) {
            var input: [IN]u8 align(64) = undefined;
            for (&input) |*v| {
                // ClippedReLU output range, with ~half zeroed so the sparse skip is hit.
                v.* = if (rnd.boolean()) 0 else rnd.intRangeAtMost(u8, 0, 127);
            }
            var weights: [IN * OUT]i8 = undefined;
            for (&weights) |*w| w.* = rnd.intRangeAtMost(i8, -128, 127);
            var biases: [OUT]i32 = undefined;
            for (&biases) |*b| b.* = rnd.intRangeAtMost(i32, -100000, 100000);

            // Scalar reference over the scrambled layout: weight of output j, group g,
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

            // The transform records this bitset in the engine; build it here to match.
            var nnz: nnue_accumulator_port.NnzBitset = .{0} ** nnue_accumulator_port.nnz_word_count;
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
