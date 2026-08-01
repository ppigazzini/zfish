// The NNUE affine (fully-connected) layer SIMD kernels, split out of nnue_inference.zig so the
// forward driver stays under the god-file line. Pure compute: the int8 weight dot-product over a
// scrambled layout, honouring the sparse-input skip. Three arch-tiered paths -- vpdpbusd (VNNI),
// pmaddubsw+pmaddwd (SSSE3), and a portable vpmaddwd deinterleave -- all bit-identical integer
// dots, selected at comptime by the target features. Bench-verified bit-exact (2508687 on every
// arch); the scalar-reference unit test in nnue_inference.zig pins every path.

const std = @import("std");
const builtin = @import("builtin");
const nnue_accumulator_port = @import("nnue_accumulator");

// Alias the AVX-512 VNNI tier from its own leaf: the vpdpbusd kernel, its feature gate and the
// dot helper the OUT==1 path shares with it.
const nnue_affine_vnni = @import("nnue_affine_vnni.zig");
const has_vnni = nnue_affine_vnni.has_vnni;
const vpdpbusd16 = nnue_affine_vnni.vpdpbusd16;
const affineVnni = nnue_affine_vnni.affineVnni;
const loadW = @import("nnue_affine_load.zig").loadW;

// Handle the AVX2 tier (no VNNI): the same maddubs dot as SSSE3 but 256-bit, so 8 outputs per
// step. Without it an AVX2 target with no VNNI falls to the portable vpmaddwd deinterleave, which
// measured +32% instructions in evaluateBucketRaw over the SSSE3 maddubs path (the affine went
// 2.55B sse41 -> 3.38B avx2). mcfish tiers the dot the same way: vpdpbusd / vpmaddubsw / pmaddubsw.
const use_avx2_madd = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

// Handle the SSSE3 tier: the pmaddwd reduction is 128-bit and widens the u8 inputs to i16;
// pmaddubsw multiplies u8*i8 directly, twice the lanes per register. Reach it through the
// LLVM intrinsic rather than inline asm: asm is an optimization barrier LLVM cannot
// schedule or reorder across, the intrinsic it can. Serves as the AVX2 fallback for an OUT the
// 256-bit path cannot tile (OUT % 8 != 0 but OUT % 4 == 0); the dispatch prefers the wider path.
const use_maddubs = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3);

const pmaddubsw128 = struct {
    extern fn @"llvm.x86.ssse3.pmadd.ub.sw.128"(@Vector(16, i8), @Vector(16, i8)) @Vector(8, i16);
}.@"llvm.x86.ssse3.pmadd.ub.sw.128";

const pmaddwd128 = struct {
    extern fn @"llvm.x86.sse2.pmadd.wd"(@Vector(8, i16), @Vector(8, i16)) @Vector(4, i32);
}.@"llvm.x86.sse2.pmadd.wd";

// AVX2 widens the SSSE3 maddubs dot to 256 bits: 8 outputs per pmaddubsw+pmaddwd step, not 4.
const pmaddubsw256 = struct {
    extern fn @"llvm.x86.avx2.pmadd.ub.sw"(@Vector(32, i8), @Vector(32, i8)) @Vector(16, i16);
}.@"llvm.x86.avx2.pmadd.ub.sw";

const pmaddwd256 = struct {
    extern fn @"llvm.x86.avx2.pmadd.wd"(@Vector(16, i16), @Vector(16, i16)) @Vector(8, i32);
}.@"llvm.x86.avx2.pmadd.wd";

/// Yield the input groups a layer must accumulate: every group when dense, only the
/// non-zero ones when sparse. Sparse walks a BITSET the feature transformer records while
/// the mask is still in a register, so the per-group data-dependent test does not exist.
/// Indices ascend either way, so the accumulation order, and the result, is unchanged.
///
/// This is the shape the tiers WITHOUT upstream's AVX-512 cursor use; where `has_vnni` holds,
/// the transform writes an index list instead (nnue_nnz.zig) and the sparse walk below never
/// runs. Popping a bitset is upstream's own non-AVX-512 spelling, so the two agree tier for
/// tier; what is local to zfish is the hoist -- the callers form the input/weight base
/// pointers once per 64-group word and pop bits with a WORD-LOCAL index.
///
/// WHERE the index list is built decides whether it pays:
///
///   * PRODUCER-side (in the transform, no bitset at all) is what ships on avx512icl:
///     instructions 0.998 (deterministic, -32.9M absolute) and branch misses 0.945.
///   * CONSUMER-side (keep the bitset, expand it here, then run the same cursor) is NOT taken.
///     It measured the same two wins -- instructions 0.998, branch misses 0.949 -- so the case
///     against it is not a measured deficit: it is that it does strictly more work for them. It
///     retains the bitset store the producer-side build deletes, and adds the expansion on top,
///     and it is not the placement upstream uses. Prefer the one that removes a pass.
///
/// Do NOT reach for cycles, IPC or cache misses to separate these two, in either direction.
/// A/A calibration on this box -- one binary against ITSELF, 20 rounds, both orientations --
/// reads cycles 0.986/0.999, IPC 1.014/1.001 and cache misses 0.983/1.014. Those three axes
/// cannot resolve anything near a percent here, so any such reading about a change this size is
/// the instrument, not the change. Instructions and branch misses can: their A/A floors are
/// exact and 0.997/1.001 respectively.
///
/// It yields an index rather than taking the accumulator, so the accumulator stays a local
/// the caller can keep in registers.
fn GroupIter(comptime sparse: bool) type {
    return struct {
        nnz: *const nnue_accumulator_port.NnzOut,
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

// Compute the SSSE3 affine via the LLVM pmaddubsw/pmaddwd intrinsics: each 128-bit weight chunk (16
// bytes = 4 outputs' 4 sublanes) is one pmaddubsw of the group's 4 input bytes (broadcast
// x4), then pmaddwd against ones folds each output's two i16 partials into its i32.
// pmaddubsw saturates at i16, but our products span [-16256,16129] and a pair sums inside
// i16, so it never saturates -- bit-identical to the pmaddwd path.
inline fn affineSsse3(
    comptime OUT: usize,
    comptime sparse: bool,
    out: *[OUT]i32,
    biases: [*]align(64) const i32,
    weights: [*]align(64) const i8,
    input: []const u8,
    nnz: *const nnue_accumulator_port.NnzOut,
) void {
    var acc: [OUT]i32 = biases[0..OUT].*;
    const ones: @Vector(8, i16) = @splat(1);
    const groups = input.len / 4;
    if (sparse) {
        // Walk the nnz bitset in upstream's shape (affine_transform_sparse_input.h): load a whole
        // 64-group word, hoist the input/weight base pointers ONCE per word, then pop set bits with
        // a LOCAL index. GroupIter instead returned the ABSOLUTE group and re-scaled it by `*4` /
        // `*OUT*4` per group -- the per-group re-indexing the profile charged to the iterator
        // (~7 instr/group vs upstream's ~3). Single chain here, so no per-group branch is added.
        var k: usize = 0;
        while (k * 64 < groups) : (k += 1) {
            var bits = nnz[k];
            const in_base = input.ptr + k * 64 * 4;
            const w_base = weights + k * 64 * OUT * 4;
            while (bits != 0) {
                const i: usize = @ctz(bits);
                bits &= bits - 1;
                const in4: [4]u8 = in_base[i * 4 ..][0..4].*;
                const inpat: @Vector(16, i8) = @bitCast(@as(@Vector(4, u32), @splat(@as(u32, @bitCast(in4)))));
                inline for (0..OUT / 4) |c| {
                    const w: @Vector(16, i8) = loadW(16, 16, w_base, i * OUT * 4 + c * 16);
                    const p: @Vector(4, i32) = pmaddwd128(pmaddubsw128(inpat, w), ones);
                    acc[c * 4 ..][0..4].* = @as(@Vector(4, i32), acc[c * 4 ..][0..4].*) + p;
                }
            }
        }
    } else {
        var g: usize = 0;
        while (g < groups) : (g += 1) {
            const in4: [4]u8 = input[g * 4 ..][0..4].*;
            const inpat: @Vector(16, i8) = @bitCast(@as(@Vector(4, u32), @splat(@as(u32, @bitCast(in4)))));
            inline for (0..OUT / 4) |c| {
                const w: @Vector(16, i8) = loadW(16, 16, weights, g * OUT * 4 + c * 16);
                const p: @Vector(4, i32) = pmaddwd128(pmaddubsw128(inpat, w), ones);
                acc[c * 4 ..][0..4].* = @as(@Vector(4, i32), acc[c * 4 ..][0..4].*) + p;
            }
        }
    }
    out.* = acc;
}

// Widen affineSsse3 to 256 bits for the AVX2 tier: each chunk (32 weight bytes = 8 outputs' 4
// sublanes) is one 256-bit pmaddubsw of the group's 4 input bytes (broadcast x8), then pmaddwd
// against ones folds each output's two i16 partials into its i32. Same non-saturation argument
// as the SSSE3 path (a pair sums inside i16), so it is bit-identical -- signature 2508687 holds.
inline fn affineAvx2(
    comptime OUT: usize,
    comptime sparse: bool,
    out: *[OUT]i32,
    biases: [*]align(64) const i32,
    weights: [*]align(64) const i8,
    input: []const u8,
    nnz: *const nnue_accumulator_port.NnzOut,
) void {
    // Split the accumulator into two dependency chains, mcfish's measured optimum at plain
    // AVX2 (0aafad9: three chains held 12 of 16 ymm live and spilled, one lost the
    // maddubs->madd->add overlap; two converts). Chain indices come from an `inline for`,
    // so every acc index is comptime and the block stays in registers; i32 wrapping adds
    // commute, so the end merge is bit-identical whatever the group partition.
    const chains = 2;
    var acc: [chains][OUT]i32 = undefined;
    acc[0] = biases[0..OUT].*;
    inline for (0..OUT / 8) |c| acc[1][c * 8 ..][0..8].* = @as(@Vector(8, i32), @splat(0));
    const ones: @Vector(16, i16) = @splat(1);
    const groups = input.len / 4;
    if (sparse) {
        // Same nnz-word hoist as affineSsse3: load a 64-group word, hoist the input/weight bases
        // once, pop set bits with a LOCAL index (affine_transform_sparse_input.h).
        var k: usize = 0;
        while (k * 64 < groups) : (k += 1) {
            var bits = nnz[k];
            const in_base = input.ptr + k * 64 * 4;
            const w_base = weights + k * 64 * OUT * 4;
            while (bits != 0) {
                inline for (0..chains) |ch| {
                    if (bits != 0) {
                        const i: usize = @ctz(bits);
                        bits &= bits - 1;
                        const in4: [4]u8 = in_base[i * 4 ..][0..4].*;
                        const inpat: @Vector(32, i8) = @bitCast(@as(@Vector(8, u32), @splat(@as(u32, @bitCast(in4)))));
                        inline for (0..OUT / 8) |c| {
                            const w: @Vector(32, i8) = loadW(32, 32, w_base, i * OUT * 4 + c * 32);
                            const p: @Vector(8, i32) = pmaddwd256(pmaddubsw256(inpat, w), ones);
                            acc[ch][c * 8 ..][0..8].* = @as(@Vector(8, i32), acc[ch][c * 8 ..][0..8].*) + p;
                        }
                    }
                }
            }
        }
    } else {
        var g: usize = 0;
        outer: while (true) {
            inline for (0..chains) |ch| {
                if (g >= groups) break :outer;
                const in4: [4]u8 = input[g * 4 ..][0..4].*;
                g += 1;
                const inpat: @Vector(32, i8) = @bitCast(@as(@Vector(8, u32), @splat(@as(u32, @bitCast(in4)))));
                inline for (0..OUT / 8) |c| {
                    const w: @Vector(32, i8) = loadW(32, 32, weights, (g - 1) * OUT * 4 + c * 32);
                    const p: @Vector(8, i32) = pmaddwd256(pmaddubsw256(inpat, w), ones);
                    acc[ch][c * 8 ..][0..8].* = @as(@Vector(8, i32), acc[ch][c * 8 ..][0..8].*) + p;
                }
            }
        }
    }
    inline for (0..OUT / 8) |c| {
        const merged = @as(@Vector(8, i32), acc[0][c * 8 ..][0..8].*) + @as(@Vector(8, i32), acc[1][c * 8 ..][0..8].*);
        out[c * 8 ..][0..8].* = merged;
    }
}

// Compute the OUT==1 affine as one contiguous int8 dot. For a single output the scrambled
// weight layout is the identity (weight[i] pairs with input[i]), so fc_2 (128->1) is a plain
// dot upstream vectorises with vpdpbusd/maddubs + a horizontal add -- zfish's OUT==1 otherwise
// falls to the portable per-group deinterleave (measured ~116 M Ir at avx2, the 2nd-largest
// affine cost). Dense only: fc_2 is the sole OUT==1 layer and always passes sparse=false. A pure
// integer dot, so the reduction order is irrelevant and it stays bit-exact (signature 2508687);
// pmaddubsw never saturates here (u8*i8 in [-16256,16129], a pair sums inside i16).
inline fn affineOut1(
    out: *[1]i32,
    bias: i32,
    weights: [*]align(64) const i8,
    input: []const u8,
) void {
    const n = input.len;
    var sum: i32 = bias;
    var i: usize = 0;
    if (comptime has_vnni) {
        var acc: @Vector(16, i32) = @splat(0);
        while (i + 64 <= n) : (i += 64) {
            const a: @Vector(64, u8) = input[i..][0..64].*;
            const b: @Vector(64, i8) = loadW(64, 64, weights, i);
            acc = vpdpbusd16(acc, a, b);
        }
        sum += @reduce(.Add, acc);
    } else if (comptime use_avx2_madd) {
        const ones: @Vector(16, i16) = @splat(1);
        var acc: @Vector(8, i32) = @splat(0);
        while (i + 32 <= n) : (i += 32) {
            const a: @Vector(32, i8) = @bitCast(@as(@Vector(32, u8), input[i..][0..32].*));
            const b: @Vector(32, i8) = loadW(32, 32, weights, i);
            acc += pmaddwd256(pmaddubsw256(a, b), ones);
        }
        sum += @reduce(.Add, acc);
    } else {
        const ones: @Vector(8, i16) = @splat(1);
        var acc: @Vector(4, i32) = @splat(0);
        while (i + 16 <= n) : (i += 16) {
            const a: @Vector(16, i8) = @bitCast(@as(@Vector(16, u8), input[i..][0..16].*));
            const b: @Vector(16, i8) = loadW(16, 16, weights, i);
            acc += pmaddwd128(pmaddubsw128(a, b), ones);
        }
        sum += @reduce(.Add, acc);
    }
    // Add any inputs the vector step could not cover (fc_2 is 128, so the tail is empty).
    while (i < n) : (i += 1) sum += @as(i32, input[i]) * @as(i32, weights[i]);
    out[0] = sum;
}

pub inline fn affineDpbusd(
    comptime OUT: usize,
    comptime sparse: bool,
    out: *[OUT]i32,
    biases: [*]align(64) const i32,
    weights: [*]align(64) const i8,
    input: []const u8,
    nnz: *const nnue_accumulator_port.NnzOut,
) void {
    if (comptime (OUT == 1 and !sparse and use_maddubs)) {
        affineOut1(out, biases[0], weights, input);
        return;
    }
    if (comptime (has_vnni and OUT % 16 == 0)) {
        affineVnni(OUT, sparse, out, biases, weights, input, nnz);
        return;
    }
    if (comptime (use_avx2_madd and OUT % 8 == 0)) {
        affineAvx2(OUT, sparse, out, biases, weights, input, nnz);
        return;
    }
    if (comptime (use_maddubs and OUT % 4 == 0)) {
        affineSsse3(OUT, sparse, out, biases, weights, input, nnz);
        return;
    }
    const N = OUT * 4;
    const Vi16 = @Vector(N, i16);
    const Vo = @Vector(OUT, i32);
    // Build the broadcast mask: lane k takes input sublane k%4 (repeats the 4 input bytes OUT×).
    const rep_mask: @Vector(N, i32) = comptime blk: {
        var m: [N]i32 = undefined;
        for (0..N) |k| m[k] = @intCast(k % 4);
        break :blk m;
    };
    // Build the two-stage vpmaddwd reduction masks. Stage 1: deinterleave the N interleaved
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
    const Vh = @Vector(N2, i32);
    const groups = input.len / 4;
    // Hoist the input/weight base per 64-group nnz word and pop bits with a LOCAL index
    // (affine_transform_sparse_input.h), rather than GroupIter's absolute re-scale per group. The
    // body is inlined into both branches (not factored behind a `&acc` helper: taking the
    // accumulator's address spills it out of registers -- D8). The deinterleave+widen+mul+add
    // folds into pmaddwd per register (exact: |in|<=127, |w|<=128).
    if (sparse) {
        var k: usize = 0;
        while (k * 64 < groups) : (k += 1) {
            var bits = nnz[k];
            const in_base = input.ptr + k * 64 * 4;
            const w_base = weights + k * 64 * N;
            while (bits != 0) {
                const i: usize = @ctz(bits);
                bits &= bits - 1;
                const in4: @Vector(4, i16) = .{
                    @intCast(in_base[i * 4]),     @intCast(in_base[i * 4 + 1]),
                    @intCast(in_base[i * 4 + 2]), @intCast(in_base[i * 4 + 3]),
                };
                const inpat: Vi16 = @shuffle(i16, in4, @as(@Vector(4, i16), undefined), rep_mask);
                const wq: @Vector(N, i8) = (w_base + i * N)[0..N].*;
                const w16: Vi16 = wq;
                const in_e: @Vector(N2, i16) = @shuffle(i16, inpat, @as(Vi16, undefined), even_n);
                const in_o: @Vector(N2, i16) = @shuffle(i16, inpat, @as(Vi16, undefined), odd_n);
                const w_e: @Vector(N2, i16) = @shuffle(i16, w16, @as(Vi16, undefined), even_n);
                const w_o: @Vector(N2, i16) = @shuffle(i16, w16, @as(Vi16, undefined), odd_n);
                const madd: Vh = @as(Vh, in_e) * @as(Vh, w_e) + @as(Vh, in_o) * @as(Vh, w_o);
                const m_e: Vo = @shuffle(i32, madd, @as(Vh, undefined), even_out);
                const m_o: Vo = @shuffle(i32, madd, @as(Vh, undefined), odd_out);
                acc += m_e + m_o;
            }
        }
    } else {
        var g: usize = 0;
        while (g < groups) : (g += 1) {
            const in4: @Vector(4, i16) = .{
                @intCast(input[g * 4]),     @intCast(input[g * 4 + 1]),
                @intCast(input[g * 4 + 2]), @intCast(input[g * 4 + 3]),
            };
            const inpat: Vi16 = @shuffle(i16, in4, @as(@Vector(4, i16), undefined), rep_mask);
            const wq: @Vector(N, i8) = weights[g * N ..][0..N].*;
            const w16: Vi16 = wq;
            const in_e: @Vector(N2, i16) = @shuffle(i16, inpat, @as(Vi16, undefined), even_n);
            const in_o: @Vector(N2, i16) = @shuffle(i16, inpat, @as(Vi16, undefined), odd_n);
            const w_e: @Vector(N2, i16) = @shuffle(i16, w16, @as(Vi16, undefined), even_n);
            const w_o: @Vector(N2, i16) = @shuffle(i16, w16, @as(Vi16, undefined), odd_n);
            const madd: Vh = @as(Vh, in_e) * @as(Vh, w_e) + @as(Vh, in_o) * @as(Vh, w_o);
            const m_e: Vo = @shuffle(i32, madd, @as(Vh, undefined), even_out);
            const m_o: Vo = @shuffle(i32, madd, @as(Vh, undefined), odd_out);
            acc += m_e + m_o;
        }
    }
    out.* = acc;
}
