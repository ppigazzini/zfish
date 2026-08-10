// The NNUE affine layer's AVX-512 VNNI kernel, split out of nnue_affine.zig so that file stays
// under the god-file line. One tier, two sparse shapes: this is the only kernel that can consume
// upstream's non-zero INDEX LIST, and the only one that has a measured reason to prefer a
// different sparse walk per sub-tier -- which is why it is the piece that grew past the split.
// Bit-identical to every other tier's dot (2884956 on each); the scalar-reference unit test in
// nnue_inference.zig pins this path too.

const std = @import("std");
const builtin = @import("builtin");
const nnue_accumulator_port = @import("nnue_accumulator");
const loadW = @import("nnue_affine_load.zig").loadW;

// Work around LLVM's refusal to lower the portable @Vector int8-dot pattern to `vpdpbusd`:
// on an AVX-512-VNNI target the affine reaches the instruction through the vpdpbusd512
// LLVM intrinsic below. Every tier computes the same pure integer dot, so all paths are
// bit-identical and the bench signature holds on each.
pub const has_vnni = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vnni);

const vpdpbusd512 = struct {
    extern fn @"llvm.x86.avx512.vpdpbusd.512"(@Vector(16, i32), @Vector(16, i32), @Vector(16, i32)) @Vector(16, i32);
}.@"llvm.x86.avx512.vpdpbusd.512";

// acc(i32x16) += the 4-way int8 dot of a(u8x64) and b(i8x64) over its 16 groups of 4.
pub inline fn vpdpbusd16(acc: @Vector(16, i32), a: @Vector(64, u8), b: @Vector(64, i8)) @Vector(16, i32) {
    return vpdpbusd512(acc, @bitCast(a), @bitCast(b));
}
// Compute the VNNI affine: the scrambled layout stores each group's OUT*4 weights contiguously, so a
// 16-output chunk is one vpdpbusd with the group's 4 input bytes broadcast across the 16
// outputs. Honor the sparse-input skip.
pub inline fn affineVnni(
    comptime OUT: usize,
    comptime sparse: bool,
    out: *[OUT]i32,
    biases: [*]align(64) const i32,
    weights: [*]align(64) const i8,
    input: []const u8,
    nnz: *const nnue_accumulator_port.NnzOut,
) void {
    const chunks = OUT / 16;
    // Split into dependency chains because vpdpbusd is high-latency: one accumulator serialises
    // the whole layer, each group's dot waits on the previous group's. Upstream splits into
    // independent chains and merges at the end (affine_transform_sparse_input.h: "If we're
    // using high-latency dot product instructions, split the accumulators into separate
    // dependency chains and merge at the end", NumRegs = 3 * NumAccums under VNNI).
    //
    // Derive `ch` from an `inline for`, so every acc index is comptime and the array stays in
    // registers. A runtime chain counter spills it, which is the whole reason this is unrolled
    // rather than rotated. Integer adds commute, so the merge is bit-identical.
    const chains = 3;
    var acc: [chunks * chains]@Vector(16, i32) = undefined;
    inline for (0..chunks) |c| acc[c] = biases[c * 16 ..][0..16].*;
    inline for (chunks..chunks * chains) |c| acc[c] = @splat(0);

    if (sparse and comptime nnue_accumulator_port.use_nnz_index_list) {
        // Read the transform's non-zero INDEX LIST straight through, upstream's cursor
        // (affine_transform_sparse_input.h, the `#if defined(USE_AVX512)` propagate): three
        // indices per iteration, one per dependency chain, and the only branch is the loop
        // back-edge. The bitset walk below spends @ctz + blsr + a DATA-DEPENDENT `bits != 0`
        // guard per group, and with the 3-chain split that guard is paid once per chain slot --
        // three unpredictable branches for every three groups.
        //
        // The list is built in the transform, where the mask is still in a register, so nothing
        // here re-derives it and the stores have long drained by the time these loads issue.
        const count = nnz.count;
        var t: usize = 0;
        while (t + chains <= count) : (t += chains) {
            inline for (0..chains) |ch| {
                const i: usize = nnz.list[t + ch];
                const in4: [4]u8 = input[i * 4 ..][0..4].*;
                const a: @Vector(64, u8) = @bitCast(@as(@Vector(16, u32), @splat(@as(u32, @bitCast(in4)))));
                inline for (0..chunks) |c| {
                    const b: @Vector(64, i8) = loadW(64, 64, weights, i * OUT * 4 + c * 64);
                    acc[ch * chunks + c] = vpdpbusd16(acc[ch * chunks + c], a, b);
                }
            }
        }
        // Run the 0..2 leftover groups into chain 0. Upstream merges the chains before its own
        // tail loop; merging after it instead is the same i32 sum, and the shared merge below
        // already covers every chain. i32 wrapping adds commute, so whatever the partition the
        // result is bit-identical -- the signature is the proof.
        while (t < count) : (t += 1) {
            const i: usize = nnz.list[t];
            const in4: [4]u8 = input[i * 4 ..][0..4].*;
            const a: @Vector(64, u8) = @bitCast(@as(@Vector(16, u32), @splat(@as(u32, @bitCast(in4)))));
            inline for (0..chunks) |c| {
                const b: @Vector(64, i8) = loadW(64, 64, weights, i * OUT * 4 + c * 64);
                acc[c] = vpdpbusd16(acc[c], a, b);
            }
        }
    } else if (sparse) {
        // VNNI without VBMI2 (x86-64-vnni512): the transform cannot build the index list for
        // less than it costs here, so walk the bitset. Hoist the input/weight base pointers
        // ONCE per 64-group nnz word and pop set bits with a LOCAL index, as the SSSE3 and
        // portable paths do (5.99: measured -3.9% / -1.9% there). Keep the 3-chain split: `ch`
        // still comes from an `inline for`, so every acc index stays comptime and the array
        // stays in registers -- the rotation is guarded per group instead. Chain ASSIGNMENT
        // shifts at word boundaries; i32 wrapping adds commute, so the merged sum is
        // bit-identical whatever the partition -- the signature is the proof.
        //
        // FALSIFIED, do not retry without new evidence: peeling `popCount(bits) / chains` full
        // rounds off the front to drop the per-lane guard from the hot loop does cut retired
        // branches (paired A/B vs this shape: branches 0.955, landing vnni512 exactly on
        // avx512icl's 1.040 against upstream). It does not pay. The peeled loop's trip count is
        // data-dependent where the guard it replaces is usually-taken, so the branches that
        // remain predict WORSE -- branch misses 1.022, miss rate 5.84% against 5.42% -- and it
        // costs +0.5% instructions for the popCount. Net cycles 0.997, inside this box's noise
        // floor. Fewer branches is not the same as fewer mispredicts.
        for (nnz, 0..) |word, k| {
            var bits = word;
            if (bits == 0) continue;
            // Form the bases only after the zero-word skip: the always-empty top words would
            // put both offsets past their buffers, and an out-of-bounds pointer must not be
            // formed even if never read.
            const in_base = input.ptr + k * 64 * 4;
            const w_base = weights + k * 64 * OUT * 4;
            while (bits != 0) {
                inline for (0..chains) |ch| {
                    if (bits != 0) {
                        const i: usize = @ctz(bits);
                        bits &= bits - 1;
                        const in4: [4]u8 = in_base[i * 4 ..][0..4].*;
                        const a: @Vector(64, u8) = @bitCast(@as(@Vector(16, u32), @splat(@as(u32, @bitCast(in4)))));
                        inline for (0..chunks) |c| {
                            const b: @Vector(64, i8) = loadW(64, 64, w_base, i * OUT * 4 + c * 64);
                            acc[ch * chunks + c] = vpdpbusd16(acc[ch * chunks + c], a, b);
                        }
                    }
                }
            }
        }
    } else {
        // Dense: every group, rotated across the chains the same way affineAvx2 does. This was
        // a GroupIter(false), whose whole body was `return g++` -- a plain counter is the same
        // ascending sequence, and it keeps this leaf independent of the bitset iterator that
        // now lives next to the tiers that still walk one.
        const groups = input.len / 4;
        var g: usize = 0;
        outer: while (true) {
            inline for (0..chains) |ch| {
                if (g >= groups) break :outer;
                defer g += 1;
                const in4: [4]u8 = input[g * 4 ..][0..4].*;
                const a: @Vector(64, u8) = @bitCast(@as(@Vector(16, u32), @splat(@as(u32, @bitCast(in4)))));
                inline for (0..chunks) |c| {
                    const b: @Vector(64, i8) = loadW(64, 64, weights, g * OUT * 4 + c * 64);
                    acc[ch * chunks + c] = vpdpbusd16(acc[ch * chunks + c], a, b);
                }
            }
        }
    }
    inline for (0..chunks) |c| {
        var sum = acc[c];
        inline for (1..chains) |ch| sum += acc[ch * chunks + c];
        out[c * 16 ..][0..16].* = sum;
    }
}
