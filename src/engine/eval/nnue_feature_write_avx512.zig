// Write the removed/added HalfKAv2_hm feature indices for a Finny-cache refresh in
// one vector pass, as upstream's HalfKAv2_hm::write_indices does
// (nnue/features/half_ka_v2_hm.cpp:32-79, gated USE_AVX512ICL). The scalar loop this
// replaces (nnue_acc_update.zig's refreshCombined) is one ctz + halfMakeIndex call per
// changed square, each dependent on the last.
//
// Ports the identity from upstream's own comment: PieceSquareIndex and KingBuckets are
// both multiples of 64 (verified against nnue_feature_luts.zig's actual table values --
// piece_square_index entries are 0/64/128/.../640, king_buckets entries are N*ps_nb with
// ps_nb=704, both always 0 mod 64), and orient/square only ever use the low 6 bits, so
// no carry crosses bit 6: (square ^ orient) + psi[pc] + bucket == square ^ (psi[pc] +
// bucket + orient). Folding bucket+orient into a per-piece lookup once per call turns
// every active feature's index into one XOR against a gather.
//
// Gated on AVX512VBMI + AVX512VBMI2, the tier movegen_splat_avx512.zig,
// threats_write_avx512.zig and movepick_sort_avx512.zig already gate the analogous
// ISA-tier algorithm switches on.

const std = @import("std");
const builtin = @import("builtin");
const luts = @import("nnue_feature_luts.zig");

pub const use_avx512_nnue_feature = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vbmi) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vbmi2);

const V64u8 = @Vector(64, u8);
const V64mask = @Vector(64, bool);
const V32u16 = @Vector(32, u16);

// LLVM intrinsic names/argument orders verified empirically (clang -O2 -mavx512f
// -mavx512bw -mavx512vbmi -mavx512vbmi2 -S -emit-llvm), same protocol as the other
// avx512-tier ports on this branch. `_mm512_permutexvar_epi16(idx, table)` lowers to
// `llvm.x86.avx512.permvar.hi.512(table, idx)` -- table and idx SWAP position relative
// to the C wrapper, same class of surprise `mask.expand.v16i32` had for the move
// sorter. `_mm512_cvtepu16_epi32`/`_mm512_cvtepi8_epi16`/`_mm512_extracti64x4_epi64`
// all lower to plain shufflevector(+zext/sext), no intrinsic; `_mm512_add_epi16`/
// `_mm512_xor_si512` are plain add/xor. Only compress (already verified for the
// dirty-threat writer) and this permute need raw declarations.
extern fn @"llvm.x86.avx512.mask.compress.v64i8"(a: V64u8, src: V64u8, mask: V64mask) V64u8;
extern fn @"llvm.x86.avx512.permvar.hi.512"(table: V32u16, idx: V32u16) V32u16;

const all_squares: V64u8 = blk: {
    var arr: [64]u8 = undefined;
    for (0..64) |i| arr[i] = @intCast(i);
    break :blk arr;
};

fn compressBytes(mask: u64, data: V64u8) V64u8 {
    const mask_v: V64mask = @bitCast(mask);
    return @"llvm.x86.avx512.mask.compress.v64i8"(data, @splat(0), mask_v);
}

// The low 32 (of 64) compressed bytes, zero-extended to u16 lanes. Values are always
// square indices (0-63) or piece codes (0-15), so zero- vs upstream's sign-extension
// (`_mm512_cvtepi8_epi16`) is identical for every value either can ever hold.
fn widenLow32(bytes: V64u8) V32u16 {
    var low: [32]u8 = undefined;
    inline for (0..32) |i| low[i] = bytes[i];
    return low;
}

pub const WriteResult = struct { removed_len: usize, added_len: usize };

// removed_out/added_out must have 32 slots of headroom past the caller's write
// position -- the store is unmasked, upstream's own shape (half_ka_v2_hm.cpp:73-79);
// only the first popCount(removed_bb)/popCount(added_bb) of the 32 written words are
// meaningful.
//
// The real body is gated on `use_avx512_nnue_feature` INSIDE the function, not just at
// its call sites: nnue_feature.zig re-exports this function by value
// (`writeIndicesAvx512`), and that file's own (unconditional) `refAllDecls` reaches the
// re-export regardless of target -- a comptime guard on the call site alone doesn't
// stop refAllDecls from forcing this body to compile on a target that can't lower the
// AVX-512 intrinsics inside it. Gating the body itself means the function is safe to
// reference from anywhere, on any target: the `unreachable` arm has no intrinsics to
// lower, and it is provably never taken (every real call site also checks
// `use_avx512_nnue_feature` before calling, per this branch's established pattern).
pub fn writeIndices(
    old_pieces: []const u8,
    new_pieces: []const u8,
    removed_bb: u64,
    added_bb: u64,
    perspective: u8,
    king_square: u8,
    removed_out: [*]u32,
    added_out: [*]u32,
) WriteResult {
    if (comptime !use_avx512_nnue_feature) unreachable;

    const removed_len: usize = @popCount(removed_bb);
    const added_len: usize = @popCount(added_bb);

    // Mirror nnue_feature.halfMakeIndex's own flip/orient/bucket expressions exactly
    // (nnue_feature.zig:59-62), just factored so bucket+orient is computed once
    // instead of once per active feature.
    const flip: u16 = 56 * @as(u16, perspective);
    const orient: u16 = @as(u16, @intCast(luts.orient_tbl_half[king_square])) ^ flip;
    const bucket: u16 = @as(u16, @intCast(luts.king_buckets[king_square ^ perspective * 56]));
    const offset = bucket +% orient;

    var psi_arr: [32]u16 = undefined;
    inline for (0..16) |i| psi_arr[i] = @as(u16, @intCast(luts.piece_square_index[perspective][i])) +% offset;
    inline for (16..32) |i| psi_arr[i] = 0; // never indexed: piece codes are always < 16
    const psi_plus_offset: V32u16 = psi_arr;

    const old_board: V64u8 = old_pieces[0..64].*;
    const new_board: V64u8 = new_pieces[0..64].*;

    const removed_squares = widenLow32(compressBytes(removed_bb, all_squares));
    const added_squares = widenLow32(compressBytes(added_bb, all_squares));
    const removed_pieces = widenLow32(compressBytes(removed_bb, old_board));
    const added_pieces = widenLow32(compressBytes(added_bb, new_board));

    const removed_indices = removed_squares ^ @"llvm.x86.avx512.permvar.hi.512"(psi_plus_offset, removed_pieces);
    const added_indices = added_squares ^ @"llvm.x86.avx512.permvar.hi.512"(psi_plus_offset, added_pieces);

    const removed_arr: [32]u16 = removed_indices;
    const added_arr: [32]u16 = added_indices;
    inline for (0..32) |i| removed_out[i] = removed_arr[i];
    inline for (0..32) |i| added_out[i] = added_arr[i];

    return .{ .removed_len = removed_len, .added_len = added_len };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

// An independent re-derivation of nnue_feature.halfMakeIndex's formula (not a call to
// it -- this file would need to import the "nnue_feature" module back to reach it,
// which its sibling nnue_feature.zig already imports THIS file from; duplicating three
// lines keeps the module graph acyclic and this test provably can't pass by sharing a
// bug with the code under test).
fn referenceIndex(perspective: u8, square: u8, piece: u8, king_square: u8) u32 {
    const flip: u32 = 56 * perspective;
    return (@as(u32, square) ^ luts.orient_tbl_half[king_square] ^ flip) +
        luts.piece_square_index[perspective][piece] + luts.king_buckets[king_square ^ perspective * 56];
}

fn referenceWrite(old_pieces: []const u8, new_pieces: []const u8, removed_bb_in: u64, added_bb_in: u64, perspective: u8, king_square: u8, removed_out: []u32, added_out: []u32) WriteResult {
    var removed_bb = removed_bb_in;
    var n: usize = 0;
    while (removed_bb != 0) {
        const sq: u8 = @intCast(@ctz(removed_bb));
        removed_bb &= removed_bb - 1;
        removed_out[n] = referenceIndex(perspective, sq, old_pieces[sq], king_square);
        n += 1;
    }
    var added_bb = added_bb_in;
    var m: usize = 0;
    while (added_bb != 0) {
        const sq: u8 = @intCast(@ctz(added_bb));
        added_bb &= added_bb - 1;
        added_out[m] = referenceIndex(perspective, sq, new_pieces[sq], king_square);
        m += 1;
    }
    return .{ .removed_len = n, .added_len = m };
}

test "writeIndices matches an independent scalar reference over random boards/masks" {
    if (comptime !use_avx512_nnue_feature) return error.SkipZigTest;
    var rng = std.Random.DefaultPrng.init(0xFEED_FACE_0BAD_C0DE);
    const random = rng.random();

    var trial: usize = 0;
    while (trial < 20000) : (trial += 1) {
        var old_pieces: [64]u8 = undefined;
        var new_pieces: [64]u8 = undefined;
        for (0..64) |i| {
            old_pieces[i] = @intCast(random.uintLessThan(u32, 16));
            new_pieces[i] = @intCast(random.uintLessThan(u32, 16));
        }
        // Real refresh events touch far fewer than 32 squares; bias low but also
        // exercise the full 32-lane capacity (a position has at most 32 pieces).
        const removed_bits = random.uintLessThan(u32, 33);
        const added_bits = random.uintLessThan(u32, 33);
        var removed_bb: u64 = 0;
        var placed: u32 = 0;
        while (placed < removed_bits) {
            const bit = @as(u64, 1) << @intCast(random.uintLessThan(u32, 64));
            if (removed_bb & bit == 0) {
                removed_bb |= bit;
                placed += 1;
            }
        }
        var added_bb: u64 = 0;
        placed = 0;
        while (placed < added_bits) {
            const bit = @as(u64, 1) << @intCast(random.uintLessThan(u32, 64));
            if (added_bb & bit == 0) {
                added_bb |= bit;
                placed += 1;
            }
        }
        const perspective: u8 = @intCast(random.uintLessThan(u32, 2));
        const king_square: u8 = @intCast(random.uintLessThan(u32, 64));

        var removed_ref: [32]u32 = undefined;
        var added_ref: [32]u32 = undefined;
        const ref_result = referenceWrite(&old_pieces, &new_pieces, removed_bb, added_bb, perspective, king_square, removed_ref[0..], added_ref[0..]);

        var removed_vec: [32]u32 = undefined;
        var added_vec: [32]u32 = undefined;
        const vec_result = writeIndices(&old_pieces, &new_pieces, removed_bb, added_bb, perspective, king_square, &removed_vec, &added_vec);

        try testing.expectEqual(ref_result.removed_len, vec_result.removed_len);
        try testing.expectEqual(ref_result.added_len, vec_result.added_len);
        for (0..ref_result.removed_len) |i| {
            testing.expectEqual(removed_ref[i], removed_vec[i]) catch |err| {
                std.debug.print("trial {d} removed mismatch at {d}: ref {d} vec {d}\n", .{ trial, i, removed_ref[i], removed_vec[i] });
                return err;
            };
        }
        for (0..ref_result.added_len) |i| {
            testing.expectEqual(added_ref[i], added_vec[i]) catch |err| {
                std.debug.print("trial {d} added mismatch at {d}: ref {d} vec {d}\n", .{ trial, i, added_ref[i], added_vec[i] });
                return err;
            };
        }
    }
}

test {
    // Gate refAllDecls too, not just the cross-check test above: refAllDecls forces
    // analysis of every declaration in this file regardless of runtime reachability,
    // which would still try to codegen the AVX-512 intrinsic calls inside writeIndices on
    // a target that can't lower them -- a comptime guard on the call site alone (the
    // test above) does not stop that.
    if (comptime use_avx512_nnue_feature) std.testing.refAllDecls(@This());
}
