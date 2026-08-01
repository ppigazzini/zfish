//! Own the layer activations: the squared and linear clipped ReLUs that sit between the
//! affine layers, in every shape upstream emits for them.
//!
//! Split out of nnue_inference.zig, which the god-file gate put over its line when the
//! AVX-512 paired kernel landed. Pure compute over 32 i32 inputs; the forward driver
//! picks a shape at comptime and the bench signature pins that all of them agree.

const std = @import("std");
const builtin = @import("builtin");

/// Compute upstream's SqrClippedReLU: min(127, (x*x) >> shift), over 32 outputs.
///
/// Clamping x into i16 first is what keeps the square inside i32 (32767^2 < 2^31), and it is
/// exact rather than an approximation: any x outside i16 squares past the 127 clamp regardless.
/// That is the same property upstream's saturating `packs_epi32` relies on before its
/// `mulhi_epi16`.
pub inline fn sqrClippedReLU(comptime shift: u5, in: *const [32]i32, out: *[32]u8) void {
    const V = if (@import("builtin").cpu.arch == .x86_64) 16 else 8;
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

// Run both activations of one layer on the AVX2 pair tier with upstream's
// SqrClippedReLU::propagate_pair (sqr_clipped_relu.h): share the input loads and the
// signed 32->16 saturating packs, compute the square via pmulhw and the clip via
// max+shift at i16 width, then narrow each with one saturating vpacksswb. The packs
// work per 128-bit lane, so the output bytes land interleaved by 4-byte chunk
// (k -> (k%2)*4 + k/2 within each 32-byte block); the fc_1/fc_2 weight parse folds
// that interleave into the weight index (nnue_parse.pair_activations -- the SAME
// comptime condition, and the bench signature pins that the two agree), so no
// lane-restoring permute is issued anywhere. Values are bit-identical to the split
// sqrClippedReLU/clippedReLU pair: the saturating pack equals their i16-range clamp,
// pmulhw>>N equals (x*x)>>(16+N) for the non-negative square, and vpacksswb's signed
// saturation equals their min(127, .) on these non-negative inputs.
// Take the AVX-512 arm of the paired activations when the tier has AVX512F. Upstream's
// USE_PAIR_ACTIVATIONS covers both this and the AVX2 pair tier; the two differ only in
// narrowing order, which is exactly what nnue_parse.scrambled_activations keys off.
pub const avx512_pair_activations = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f);

const packssdw256 = struct {
    extern fn @"llvm.x86.avx2.packssdw"(@Vector(8, i32), @Vector(8, i32)) @Vector(16, i16);
}.@"llvm.x86.avx2.packssdw";
const packsswb256 = struct {
    extern fn @"llvm.x86.avx2.packsswb"(@Vector(16, i16), @Vector(16, i16)) @Vector(32, i8);
}.@"llvm.x86.avx2.packsswb";
const pmulhw256 = struct {
    extern fn @"llvm.x86.avx2.pmulh.w"(@Vector(16, i16), @Vector(16, i16)) @Vector(16, i16);
}.@"llvm.x86.avx2.pmulh.w";

// Run both activations of one layer on the 128-bit SSSE3-class tier with the same
// packs+mulhi shape upstream emits there (sqr_clipped_relu.h / clipped_relu.h lower to
// packssdw+pmulhw+psrlw+packsswb at SSE): share the input loads and the signed 32->16
// saturating packs, square via pmulhw and clip via max+shift at i16 width, then narrow
// each with one saturating packsswb. The 128-bit packs concatenate their two operands in
// order -- no cross-lane interleave exists at this width -- so the bytes land in natural
// order and the fc_1/fc_2 weight parse stays the identity (unlike the avx2 pair tier's
// compensating scramble). The split sqrClippedReLU/clippedReLU pair instead runs the
// square at i32 width: pmulld is 2 uops on this tier and every clamp/shift/pack step
// pays 4 xmm ops per 16 outputs, ~3x the instructions of the pack shape for the same
// values. Values are bit-identical by sqrClipPair's argument: the saturating pack equals
// the i16-range clamp, pmulhw>>N equals (x*x)>>(16+N) for the non-negative square, and
// packsswb's signed saturation equals min(127, .) on these non-negative inputs.
pub const sse_pair_activations = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3) and
    !std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

const packssdw128 = struct {
    extern fn @"llvm.x86.sse2.packssdw.128"(@Vector(4, i32), @Vector(4, i32)) @Vector(8, i16);
}.@"llvm.x86.sse2.packssdw.128";
const packsswb128 = struct {
    extern fn @"llvm.x86.sse2.packsswb.128"(@Vector(8, i16), @Vector(8, i16)) @Vector(16, i8);
}.@"llvm.x86.sse2.packsswb.128";
const pmulhw128 = struct {
    extern fn @"llvm.x86.sse2.pmulh.w"(@Vector(8, i16), @Vector(8, i16)) @Vector(8, i16);
}.@"llvm.x86.sse2.pmulh.w";

pub inline fn sqrClipPair128(comptime scale_bits: comptime_int, in: *const [32]i32, sqr_out: *[32]u8, clip_out: *[32]u8) void {
    // MulHi strips 16 of the 2*scale_bits+7 square-shift bits; shift out the rest.
    const sqr_shift: @Vector(8, u4) = @splat(2 * scale_bits + 7 - 16);
    const clip_shift: @Vector(8, u4) = @splat(scale_bits);
    const zero: @Vector(8, i16) = @splat(0);
    inline for (0..2) |half| {
        const base = half * 16;
        const words0 = packssdw128(in[base..][0..4].*, in[base + 4 ..][0..4].*);
        const words1 = packssdw128(in[base + 8 ..][0..4].*, in[base + 12 ..][0..4].*);
        const sqr0: @Vector(8, i16) = @bitCast(@as(@Vector(8, u16), @bitCast(pmulhw128(words0, words0))) >> sqr_shift);
        const sqr1: @Vector(8, i16) = @bitCast(@as(@Vector(8, u16), @bitCast(pmulhw128(words1, words1))) >> sqr_shift);
        sqr_out[base..][0..16].* = @bitCast(packsswb128(sqr0, sqr1));
        const relu0: @Vector(8, i16) = @max(words0, zero);
        const relu1: @Vector(8, i16) = @max(words1, zero);
        const clip0: @Vector(8, i16) = @bitCast(@as(@Vector(8, u16), @bitCast(relu0)) >> clip_shift);
        const clip1: @Vector(8, i16) = @bitCast(@as(@Vector(8, u16), @bitCast(relu1)) >> clip_shift);
        clip_out[base..][0..16].* = @bitCast(packsswb128(clip0, clip1));
    }
}

pub inline fn sqrClipPair(comptime scale_bits: comptime_int, in: *const [32]i32, sqr_out: *[32]u8, clip_out: *[32]u8) void {
    // MulHi strips 16 of the 2*scale_bits+7 square-shift bits; shift out the rest.
    const sqr_shift: @Vector(16, u4) = @splat(2 * scale_bits + 7 - 16);
    const clip_shift: @Vector(16, u4) = @splat(scale_bits);
    const zero: @Vector(16, i16) = @splat(0);
    const words0 = packssdw256(in[0..8].*, in[8..16].*);
    const words1 = packssdw256(in[16..24].*, in[24..32].*);
    const sqr0: @Vector(16, i16) = @bitCast(@as(@Vector(16, u16), @bitCast(pmulhw256(words0, words0))) >> sqr_shift);
    const sqr1: @Vector(16, i16) = @bitCast(@as(@Vector(16, u16), @bitCast(pmulhw256(words1, words1))) >> sqr_shift);
    sqr_out.* = @bitCast(packsswb256(sqr0, sqr1));
    const relu0: @Vector(16, i16) = @max(words0, zero);
    const relu1: @Vector(16, i16) = @max(words1, zero);
    const clip0: @Vector(16, i16) = @bitCast(@as(@Vector(16, u16), @bitCast(relu0)) >> clip_shift);
    const clip1: @Vector(16, i16) = @bitCast(@as(@Vector(16, u16), @bitCast(relu1)) >> clip_shift);
    clip_out.* = @bitCast(packsswb256(clip0, clip1));
}

/// Pair the two activations on the AVX-512 tier -- upstream's USE_AVX512 arm of
/// SqrClippedReLU::propagate_pair. Same shape as sqrClipPair above (share the input loads
/// and the signed 32->16 narrowing, square via mulhi, clip via max+shift at i16 width),
/// with ONE difference that decides the whole flag split: vpmovsdw/vpmovswb narrow the
/// register IN ORDER, where AVX2's vpackssdw/vpacksswb interleave per 128-bit lane. So
/// this tier needs no compensating weight scramble -- see nnue_parse.scrambled_activations.
///
/// The narrows are written as clamp-then-@intCast rather than an intrinsic: that IS the
/// definition of a signed saturating narrow, and it stays correct on a backend that
/// lowers it differently. Values are bit-identical to the split
/// sqrClippedReLU/clippedReLU pair by the same argument as sqrClipPair -- the saturating
/// narrow equals their range clamp, mulhi>>N equals (x*x)>>(16+N) for the non-negative
/// square, and the signed byte saturation equals min(127, .) on non-negative inputs.
pub inline fn sqrClipPair512(comptime scale_bits: comptime_int, in: *const [32]i32, sqr_out: *[32]u8, clip_out: *[32]u8) void {
    const lo: @Vector(32, i32) = @splat(-32768);
    const hi: @Vector(32, i32) = @splat(32767);
    const words: @Vector(32, i16) = @intCast(@min(@max(@as(@Vector(32, i32), in.*), lo), hi));

    // MulHi strips 16 of the 2*scale_bits+7 square-shift bits; shift out the rest.
    const sqr_shift: @Vector(32, u4) = @splat(2 * scale_bits + 7 - 16);
    const clip_shift: @Vector(32, u4) = @splat(scale_bits);
    const wide: @Vector(32, i32) = words;
    const mulhi: @Vector(32, i16) = @truncate((wide * wide) >> @as(@Vector(32, u5), @splat(16)));
    const sqr: @Vector(32, i16) = @bitCast(@as(@Vector(32, u16), @bitCast(mulhi)) >> sqr_shift);

    const zero: @Vector(32, i16) = @splat(0);
    const relu: @Vector(32, i16) = @max(words, zero);
    const clip: @Vector(32, i16) = @bitCast(@as(@Vector(32, u16), @bitCast(relu)) >> clip_shift);

    const blo: @Vector(32, i16) = @splat(-128);
    const bhi: @Vector(32, i16) = @splat(127);
    sqr_out.* = @bitCast(@as(@Vector(32, i8), @intCast(@min(@max(sqr, blo), bhi))));
    clip_out.* = @bitCast(@as(@Vector(32, i8), @intCast(@min(@max(clip, blo), bhi))));
}

/// Compute upstream's ClippedReLU: clamp(x >> shift, 0, 127), over 32 outputs.
pub inline fn clippedReLU(comptime shift: u5, in: *const [32]i32, out: *[32]u8) void {
    const V = if (@import("builtin").cpu.arch == .x86_64) 16 else 8;
    const zero: @Vector(V, i32) = @splat(0);
    const cap: @Vector(V, i32) = @splat(127);
    const sh: @Vector(V, u5) = @splat(shift);
    var i: usize = 0;
    while (i < 32) : (i += V) {
        const x: @Vector(V, i32) = in[i..][0..V].*;
        out[i..][0..V].* = @as(@Vector(V, u8), @intCast(@max(zero, @min(cap, x >> sh))));
    }
}
