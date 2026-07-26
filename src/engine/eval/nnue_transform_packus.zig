// Implement the NNUE feature transform's packus clip-multiply-narrow kernels.
//
// Upstream's transform body (nnue_feature_transformer.h) reached at each x86 vector
// width, split out of nnue_acc_rowops.zig: the row add/sub kernels there feed the
// ACCUMULATOR, these feed transformBucket's output bytes, and the two share nothing
// but the file they used to sit in. Self-contained: comptime tier gates, the three
// LLVM pack/mulhi intrinsic declarations, one kernel per width, and the scalar-
// reference tests that pin the trick. nnue_accumulator.zig is the only consumer.

const std = @import("std");

// Run the transform's clip-multiply-narrow at i16 width on the 256-bit tiers with
// upstream's packus body (nnue_feature_transformer.h): clamp only the FIRST half's
// operand to [0,255] and shift it left 7; the second half gets min(255, .) alone, no
// max -- a negative second operand keeps its sign through the SIGNED vpmulhw, drives
// the product negative, and the saturating vpackuswb zeroes it on pack, which is
// exactly the max(0, .) the generic path pays a vpmaxsw for (upstream: "saves one max
// operation per pair"). One byte shuffle (vpermq) undoes the pack's 128-bit-lane
// interleave, so the output bytes, the nnz bitset and everything downstream are
// unchanged. Positive products never saturate: (255<<7)*255 >> 16 == 127.
pub const use_packus_avx2 = @import("builtin").cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(@import("builtin").cpu.features, .avx2) and
    !std.Target.x86.featureSetHas(@import("builtin").cpu.features, .avx512bw);

const packuswb256 = struct {
    extern fn @"llvm.x86.avx2.packuswb"(@Vector(16, i16), @Vector(16, i16)) @Vector(32, u8);
}.@"llvm.x86.avx2.packuswb";
const transform_pmulhw256 = struct {
    extern fn @"llvm.x86.avx2.pmulh.w"(@Vector(16, i16), @Vector(16, i16)) @Vector(16, i16);
}.@"llvm.x86.avx2.pmulh.w";

// Run the same packus body at zmm width, which is the arm upstream's transform takes on
// AVX-512 too: its `#else` covers every x86 tier, and only NEON, LSX/LASX and wasm branch
// away. zfish gated the trick to `avx2 and !avx512f`, leaving the 512-bit tiers on the
// widen-free mulhi-UNSIGNED path -- which pays, per 64 output bytes, two vpmaxsw for the
// second half plus two vpmovwb and a vinserti64x4 to narrow, where packus narrows in one
// op and its saturation supplies the max. vpmulhw and vpackuswb are AVX512BW, so gate on
// that; a hypothetical avx512f-without-bw target keeps the generic path.
pub const use_packus_avx512 = @import("builtin").cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(@import("builtin").cpu.features, .avx512bw);

const packuswb512 = struct {
    extern fn @"llvm.x86.avx512.packuswb.512"(@Vector(32, i16), @Vector(32, i16)) @Vector(64, u8);
}.@"llvm.x86.avx512.packuswb.512";
const transform_pmulhw512 = struct {
    extern fn @"llvm.x86.avx512.pmulh.w.512"(@Vector(32, i16), @Vector(32, i16)) @Vector(32, i16);
}.@"llvm.x86.avx512.pmulh.w.512";

// Run the same packus body at xmm width on the pre-AVX2 x86 tiers (upstream's SSE2
// transform shape). The saturation argument is width-independent, and the 128-bit
// pack concatenates its operands' low bytes in order -- pa's 8 bytes then pb's 8
// bytes ARE natural element order, so no lane fix is needed at all.
pub const use_packus_sse = @import("builtin").cpu.arch == .x86_64 and
    !std.Target.x86.featureSetHas(@import("builtin").cpu.features, .avx2);

const packuswb128 = struct {
    extern fn @"llvm.x86.sse2.packuswb.128"(@Vector(8, i16), @Vector(8, i16)) @Vector(16, u8);
}.@"llvm.x86.sse2.packuswb.128";
const transform_pmulhw128 = struct {
    extern fn @"llvm.x86.sse2.pmulh.w"(@Vector(8, i16), @Vector(8, i16)) @Vector(8, i16);
}.@"llvm.x86.sse2.pmulh.w";

// Compute 16 output bytes from the two halves' i16 accumulator lanes (a = first half,
// b = second): per element min(127, (clamp(a,0,255) * clamp(b,0,255)) >> 9), in natural
// element order. The scalar-reference unit test pins the packus trick's equivalence.
pub inline fn packusTransform16(a: [2]@Vector(8, i16), b: [2]@Vector(8, i16)) @Vector(16, u8) {
    const c255: @Vector(8, i16) = @splat(255);
    const zero: @Vector(8, i16) = @splat(0);
    const sh7: @Vector(8, u4) = @splat(7);
    const sum0a: @Vector(8, i16) = @max(@min(a[0], c255), zero) << sh7;
    const sum0b: @Vector(8, i16) = @max(@min(a[1], c255), zero) << sh7;
    const sum1a: @Vector(8, i16) = @min(b[0], c255);
    const sum1b: @Vector(8, i16) = @min(b[1], c255);
    return packuswb128(
        transform_pmulhw128(sum0a, sum1a),
        transform_pmulhw128(sum0b, sum1b),
    );
}

// Compute 32 output bytes from the two halves' i16 accumulator lanes (a = first half,
// b = second): per element min(127, (clamp(a,0,255) * clamp(b,0,255)) >> 9), in natural
// element order. The scalar-reference unit test pins the packus trick's equivalence.
pub inline fn packusTransform32(a: [2]@Vector(16, i16), b: [2]@Vector(16, i16)) @Vector(32, u8) {
    const c255: @Vector(16, i16) = @splat(255);
    const zero: @Vector(16, i16) = @splat(0);
    const sh7: @Vector(16, u4) = @splat(7);
    const clamped0: @Vector(16, i16) = @max(@min(a[0], c255), zero);
    const clamped1: @Vector(16, i16) = @max(@min(a[1], c255), zero);
    const sum0a: @Vector(16, i16) = clamped0 << sh7;
    const sum0b: @Vector(16, i16) = clamped1 << sh7;
    const sum1a: @Vector(16, i16) = @min(b[0], c255);
    const sum1b: @Vector(16, i16) = @min(b[1], c255);
    const packed_bytes = packuswb256(
        transform_pmulhw256(sum0a, sum1a),
        transform_pmulhw256(sum0b, sum1b),
    );
    // Undo the pack's per-128-bit-lane interleave (one vpermq): natural byte order out.
    const natural_fix: @Vector(32, i32) = comptime blk: {
        const src_quads = [4]usize{ 0, 2, 1, 3 };
        var m: [32]i32 = undefined;
        for (&m, 0..) |*e, i| e.* = @intCast(src_quads[i / 8] * 8 + i % 8);
        break :blk m;
    };
    return @shuffle(u8, packed_bytes, undefined, natural_fix);
}

// Compute 64 output bytes from the two halves' i16 accumulator lanes (a = first half,
// b = second): per element min(127, (clamp(a,0,255) * clamp(b,0,255)) >> 9), in natural
// element order. The scalar-reference unit test pins the packus trick's equivalence.
pub inline fn packusTransform64(a: [2]@Vector(32, i16), b: [2]@Vector(32, i16)) @Vector(64, u8) {
    const c255: @Vector(32, i16) = @splat(255);
    const zero: @Vector(32, i16) = @splat(0);
    const sh7: @Vector(32, u4) = @splat(7);
    const sum0a: @Vector(32, i16) = (@max(@min(a[0], c255), zero)) << sh7;
    const sum0b: @Vector(32, i16) = (@max(@min(a[1], c255), zero)) << sh7;
    const sum1a: @Vector(32, i16) = @min(b[0], c255);
    const sum1b: @Vector(32, i16) = @min(b[1], c255);
    const packed_bytes = packuswb512(
        transform_pmulhw512(sum0a, sum1a),
        transform_pmulhw512(sum0b, sum1b),
    );
    // Undo the pack's per-128-bit-lane interleave (one vpermq over the 8 qwords): the
    // result's qwords run a0 b0 a1 b1 a2 b2 a3 b3, so gathering 0,2,4,6,1,3,5,7 restores
    // natural order -- the same permutation upstream folds into the weights at load time
    // (`PackusEpi16Order`, nnue_feature_transformer.h) rather than paying at runtime.
    const natural_fix: @Vector(64, i32) = comptime blk: {
        const src_quads = [8]usize{ 0, 2, 4, 6, 1, 3, 5, 7 };
        var m: [64]i32 = undefined;
        for (&m, 0..) |*e, i| e.* = @intCast(src_quads[i / 8] * 8 + i % 8);
        break :blk m;
    };
    return @shuffle(u8, packed_bytes, undefined, natural_fix);
}

// Pin the 512-bit packus trick against the same scalar identity: the dropped second-half
// max(0, .) must be reproduced by the signed vpmulhw's sign carry plus vpackuswb's
// low-side saturation, and the qword permute must restore natural byte order across all
// four 128-bit lanes.
test "packusTransform64 equals the scalar transform identity" {
    if (comptime !use_packus_avx512) return error.SkipZigTest;
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0x5DEECE66D2C03579);
    const rnd = prng.random();
    const edges = [_]i16{ -32768, -256, -255, -1, 0, 1, 127, 128, 255, 256, 32767 };

    var iter: usize = 0;
    while (iter < 512) : (iter += 1) {
        var a: [64]i16 = undefined;
        var b: [64]i16 = undefined;
        for (0..64) |i| {
            a[i] = if (rnd.boolean()) edges[rnd.uintLessThan(usize, edges.len)] else rnd.int(i16);
            b[i] = if (rnd.boolean()) edges[rnd.uintLessThan(usize, edges.len)] else rnd.int(i16);
        }
        var expected: [64]u8 = undefined;
        for (0..64) |i| {
            const c0: i32 = @max(0, @min(255, @as(i32, a[i])));
            const c1: i32 = @max(0, @min(255, @as(i32, b[i])));
            expected[i] = @intCast((c0 * c1) >> 9);
        }
        const got: [64]u8 = packusTransform64(.{
            a[0..32].*,
            a[32..64].*,
        }, .{
            b[0..32].*,
            b[32..64].*,
        });
        try testing.expectEqualSlices(u8, &expected, &got);
    }
}

// Pin the packus trick against the scalar transform identity over the full i16 range:
// the dropped second-half max(0, .) must be exactly reproduced by the signed vpmulhw's
// sign carry plus vpackuswb's low-side saturation, and the vpermq must restore natural
// byte order. Edge values cover both saturating clamps and the negative pass-through.
test "packusTransform32 equals the scalar transform identity" {
    if (comptime !use_packus_avx2) return error.SkipZigTest;
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0x5DEECE66D2C03579);
    const rnd = prng.random();
    const edges = [_]i16{ -32768, -256, -255, -1, 0, 1, 127, 128, 255, 256, 32767 };

    var iter: usize = 0;
    while (iter < 512) : (iter += 1) {
        var a: [32]i16 = undefined;
        var b: [32]i16 = undefined;
        for (0..32) |i| {
            a[i] = if (rnd.boolean()) edges[rnd.uintLessThan(usize, edges.len)] else rnd.int(i16);
            b[i] = if (rnd.boolean()) edges[rnd.uintLessThan(usize, edges.len)] else rnd.int(i16);
        }
        var expected: [32]u8 = undefined;
        for (0..32) |i| {
            const c0: i32 = @max(0, @min(255, @as(i32, a[i])));
            const c1: i32 = @max(0, @min(255, @as(i32, b[i])));
            expected[i] = @intCast((c0 * c1) >> 9);
        }
        const got: [32]u8 = packusTransform32(.{
            a[0..16].*,
            a[16..32].*,
        }, .{
            b[0..16].*,
            b[16..32].*,
        });
        try testing.expectEqualSlices(u8, &expected, &got);
    }
}

// Pin the 128-bit packus trick against the same scalar identity: the dropped
// second-half max(0, .) must be exactly reproduced by pmulhw's sign carry plus
// packuswb's low-side saturation, in natural byte order (the 128-bit pack has no
// lane interleave to undo).
test "packusTransform16 equals the scalar transform identity" {
    if (comptime !use_packus_sse) return error.SkipZigTest;
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0x5DEECE66D2C03579);
    const rnd = prng.random();
    const edges = [_]i16{ -32768, -256, -255, -1, 0, 1, 127, 128, 255, 256, 32767 };

    var iter: usize = 0;
    while (iter < 512) : (iter += 1) {
        var a: [16]i16 = undefined;
        var b: [16]i16 = undefined;
        for (0..16) |i| {
            a[i] = if (rnd.boolean()) edges[rnd.uintLessThan(usize, edges.len)] else rnd.int(i16);
            b[i] = if (rnd.boolean()) edges[rnd.uintLessThan(usize, edges.len)] else rnd.int(i16);
        }
        var expected: [16]u8 = undefined;
        for (0..16) |i| {
            const c0: i32 = @max(0, @min(255, @as(i32, a[i])));
            const c1: i32 = @max(0, @min(255, @as(i32, b[i])));
            expected[i] = @intCast((c0 * c1) >> 9);
        }
        const got: [16]u8 = packusTransform16(.{
            a[0..8].*,
            a[8..16].*,
        }, .{
            b[0..8].*,
            b[8..16].*,
        });
        try testing.expectEqualSlices(u8, &expected, &got);
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
