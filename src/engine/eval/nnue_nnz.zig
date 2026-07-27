// The NNUE transform's non-zero-chunk record, split out of nnue_accumulator.zig so the
// accumulator facade stays under the god-file line. Upstream's NNZInfo and its NNZCursor
// (nnue/nnz_helper.h): the shape the feature transformer writes so the sparse affine can skip
// all-zero input chunks, plus the one function that writes it. Two shapes, chosen by what the
// tier's affine consumer can read -- an index list where that is upstream's AVX-512 cursor, a
// bitset everywhere else. Pure record-keeping: no arithmetic the eval depends on, and the
// scalar-reference test in nnue_inference.zig pins producer against consumer on every tier.

const std = @import("std");
const builtin = @import("builtin");

const layout = @import("nnue_acc_layout.zig");
const half_dimensions = layout.half_dimensions;

/// Set one bit per 4-byte output chunk when that chunk is non-zero. Upstream's NNZInfo
/// (nnz_helper.h), recorded here rather than re-derived by a later pass: the values are
/// already in a register at the point they are packed.
// half_dimensions output bytes / 4 (bytes per chunk) / 64 (bits per word): the transform
// emits half_dimensions bytes = half_dimensions/4 non-zero-chunk bits, so 4 u64 words cover
// the 256 chunks. (The former `* 2` sized it for 2048 output bytes, twice the real width.)
pub const nnz_word_count: usize = half_dimensions / 4 / 64;
pub const NnzBitset = [nnz_word_count]u64;

// Store each transform step's non-zero mask with a plain byte-offset store, upstream's
// bytewise NNZCursor (nnz_helper.h `*out++ = m1 + (m2 << 4)`): on a little-endian
// target the GMask's bytes at offset bit/8 land exactly where the u64 word's bits
// bit..bit+N-1 live, so the store IS the word-shift OR against a zero seed -- minus
// the load, the variable-cl shift and the read-modify-write. Big-endian targets keep
// the endian-independent word RMW (and the @memset seed it needs).
const nnz_bytewise = @import("builtin").target.cpu.arch.endian() == .little;

/// Emit an INDEX LIST rather than a bitset, which is upstream's shape: at USE_AVX512 NNZInfo
/// holds `count` plus a `u16` index array and never builds a bitset at all (nnz_helper.h).
///
/// Gate it on BOTH avx512vnni and avx512vbmi2, and note that the two conditions are there for
/// different reasons -- neither is redundant:
///
///   * avx512vnni, because that is what selects the affine consumer able to read a list
///     (nnue_affine's `has_vnni`). Producer and consumer must agree here or the transform
///     writes a shape the layer cannot read.
///   * avx512vbmi2, because that is what makes it PAY. VBMI2 compresses 32 u16 lanes in one
///     vpcompressw, matching a whole transform step's mask; without it the step needs two
///     vpcompressd plus two narrowing stores, and that doubled producer cost flips the
///     instruction axis. Measured on x86-64-vnni512, which has VNNI and no VBMI2: instructions
///     1.003 AGAINST, against 0.998 for the same patch at avx512icl -- while branch misses gain
///     0.934 either way. Two tiers, opposite instruction verdicts, so the bitset stays on the
///     tier where the compress cannot be paid for.
pub const use_nnz_index_list = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vnni) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vbmi2);

/// One slot per 4-byte output chunk: the transform emits half_dimensions bytes, so this is the
/// most indices that can exist and the list never needs a bound check.
pub const nnz_group_capacity: usize = half_dimensions / 4;

/// Upstream's NNZInfo at USE_AVX512 (nnz_helper.h). `count` leads so the consumer's first load
/// shares a line with the head of the list.
pub const NnzIndexList = struct {
    count: usize,
    list: [nnz_group_capacity]u16,
};

/// What the transform hands the affine: the tier's consumer decides the shape.
pub const NnzOut = if (use_nnz_index_list) NnzIndexList else NnzBitset;

const compressw512 = struct {
    extern fn @"llvm.x86.avx512.mask.compress.v32i16"(@Vector(32, i16), @Vector(32, i16), @Vector(32, bool)) @Vector(32, i16);
}.@"llvm.x86.avx512.mask.compress.v32i16";

/// Record one transform step's non-zero mask.
///
/// The index-list form is upstream's NNZCursor::record2: compress the step's chunk indices
/// under the mask and store them, advancing `count` by the popcount -- no bitset, no second
/// pass. It runs HERE, in the transform, which is upstream's placement and the one that does
/// the least work: the mask is already in a register, and the bitset store disappears entirely
/// rather than being kept and expanded later at the consumer.
///
/// `count` only ever grows by at most the step's lane count, and a step stores its whole
/// compress register at `count`, so the last store ends at nnz_group_capacity exactly -- the
/// capacity is a proof, not a margin.
///
/// The bitset form is upstream's bytewise NNZCursor (`*out++ = m1 + (m2 << 4)`): on a
/// little-endian target the GMask's bytes at offset bit/8 land exactly where the u64 word's
/// bits bit..bit+N-1 live, so the store IS the word-shift OR against a zero seed -- minus the
/// load, the variable-cl shift and the read-modify-write. Big-endian targets keep the
/// endian-independent word RMW (and the @memset seed it needs).
pub inline fn nnzRecord(comptime GMask: type, nnz: *NnzOut, bit: usize, mask: GMask) void {
    if (comptime use_nnz_index_list) {
        // One vpcompressw per 32 mask bits, which at the shipping transform_vec_width is the
        // whole step in one instruction. The base index is a runtime value (the step's chunk
        // offset), so the index vector is a constant ramp splatted onto it -- upstream carries
        // the same vector and bumps it by `increment` per step instead.
        const lanes = 32;
        comptime std.debug.assert(@bitSizeOf(GMask) % lanes == 0);
        inline for (0..@bitSizeOf(GMask) / lanes) |s| {
            const Slice = @Int(.unsigned, lanes);
            const m: Slice = @truncate(mask >> @intCast(s * lanes));
            const ramp: @Vector(lanes, i16) = comptime blk: {
                var v: [lanes]i16 = undefined;
                for (&v, 0..) |*e, i| e.* = @intCast(i);
                break :blk v;
            };
            const base: u16 = @intCast(bit + s * lanes);
            const idx = ramp + @as(@Vector(lanes, i16), @splat(@bitCast(base)));
            nnz.list[nnz.count..][0..lanes].* = @bitCast(compressw512(idx, @splat(0), @bitCast(m)));
            nnz.count += @popCount(m);
        }
        return;
    }
    if (comptime nnz_bytewise) {
        comptime std.debug.assert(@bitSizeOf(GMask) % 8 == 0);
        std.debug.assert(bit % 8 == 0);
        const bytes: [*]u8 = @ptrCast(nnz);
        bytes[bit / 8 ..][0..@sizeOf(GMask)].* = @bitCast(mask);
    } else {
        nnz[bit / 64] |= @as(u64, mask) << @intCast(bit % 64);
    }
}
/// Seed the record before a transform pass. The bitset's bytewise store writes every byte
/// exactly once ((2*half)/4 bits == the whole NnzBitset), so it needs no seed at all; only the
/// endian-independent word RMW ORs into one. The index list seeds its cursor instead -- its
/// slots are written by position, and only the first `count` of them are ever read.
pub inline fn nnzReset(nnz: *NnzOut) void {
    if (comptime use_nnz_index_list) {
        nnz.count = 0;
    } else if (comptime !nnz_bytewise) {
        @memset(nnz, 0);
    }
}
