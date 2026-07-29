// Splat pawn-push and single-piece moves in one vector pass, as upstream's
// splat_pawn_moves/splat_moves do (movegen.cpp:36-84, gated USE_AVX512ICL). The
// scalar loop this replaces (movegen.zig's splatPawnMoves/splatMoves) is one pop_lsb
// + pack + append per destination square, each dependent on the last.
//
// Gated on AVX512VBMI + AVX512VBMI2, the same x86-64-avx512icl tier
// threats_write_avx512.zig and movepick_sort_avx512.zig already gate on: the compress
// needs VBMI2, matching write_multiple_dirties' compress use exactly (same intrinsic,
// same verified signature, re-derived here rather than imported since this file is a
// sibling of movegen.zig -- a different registered module than move_do_threats.zig's
// "move_do" -- and the shared iota table is three lines, not worth a cross-module edge).

const std = @import("std");
const builtin = @import("builtin");

pub const use_avx512_movegen = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vbmi) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vbmi2);

const V64u8 = @Vector(64, u8);
const V64mask = @Vector(64, bool);

// Verified via clang -O2 -mavx512f -mavx512bw -mavx512vbmi -mavx512vbmi2 -msse4.1
// -S -emit-llvm (same protocol as threats_write_avx512.zig): compress is the one op
// here that needs a raw intrinsic. `_mm_cvtepi8_epi16`/`_mm512_cvtepi8_epi16` lower to
// a plain shufflevector+sext (no intrinsic), `_mm_subs_epi16` lowers to the PORTABLE
// `llvm.ssub.sat.v8i16` (not x86-specific) which Zig's `-|` operator already emits
// directly on an integer vector, and `_mm_slli_epi16`/`_mm_or_si128` are plain
// shl/or -- all four are ordinary Zig vector operators below, not extern calls.
extern fn @"llvm.x86.avx512.mask.compress.v64i8"(a: V64u8, src: V64u8, mask: V64mask) V64u8;

const all_squares: V64u8 = blk: {
    var arr: [64]u8 = undefined;
    for (0..64) |i| arr[i] = @intCast(i);
    break :blk arr;
};

fn compressSquares(mask: u64) V64u8 {
    const mask_v: V64mask = @bitCast(mask);
    return @"llvm.x86.avx512.mask.compress.v64i8"(all_squares, @splat(0), mask_v);
}

// Write up to 8 pawn-push moves (from = to - offset for every set bit of to_bb) to
// moves_ptr[0..8), UNMASKED -- callers must have at least 8 slots of headroom past
// their current write position (movegen.zig's MoveWriter always does: true legal-move
// max is 218, the shared scratch buffer is 256). Returns the true count
// (popCount(to_bb) <= 8, upstream's own asserted bound for pawn pushes); only that
// many of the 8 written words are meaningful, matching upstream's own unmasked
// 128-bit store (movegen.cpp:44).
pub fn splatPawnMoves(comptime offset: i8, moves_ptr: [*]u16, to_bb: u64) usize {
    const count: usize = @popCount(to_bb);
    const compressed = compressSquares(to_bb);
    var low8: [8]i8 = undefined;
    inline for (0..8) |i| low8[i] = @bitCast(compressed[i]);
    const to_squares: @Vector(8, i16) = low8;
    const from_squares = to_squares -| @as(@Vector(8, i16), @splat(@as(i16, offset)));
    const words: @Vector(8, i16) = (from_squares << @as(@Vector(8, u4), @splat(6))) | to_squares;
    const words_u16: [8]u16 = @bitCast(words);
    inline for (0..8) |i| moves_ptr[i] = words_u16[i];
    return count;
}

// Write up to 32 moves (from is fixed, to varies over to_bb) to moves_ptr[0..32),
// UNMASKED -- same headroom contract as splatPawnMoves. Returns the true count
// (popCount(to_bb) <= 32, upstream's own asserted bound -- a queen can reach at most
// 27 squares); only that many of the 32 written words are meaningful, matching
// upstream's own unmasked 512-bit store (movegen.cpp:63).
pub fn splatMoves(from: u8, moves_ptr: [*]u16, to_bb: u64) usize {
    const count: usize = @popCount(to_bb);
    const compressed = compressSquares(to_bb);
    var low32: [32]i8 = undefined;
    inline for (0..32) |i| low32[i] = @bitCast(compressed[i]);
    const to_squares: @Vector(32, i16) = low32;
    const from_vec: @Vector(32, i16) = @splat(@as(i16, from) << 6);
    const words: @Vector(32, i16) = from_vec | to_squares;
    const words_u16: [32]u16 = @bitCast(words);
    inline for (0..32) |i| moves_ptr[i] = words_u16[i];
    return count;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn referencePawnMoves(comptime offset: i8, moves: []u16, to_bb_in: u64) usize {
    var to_bb = to_bb_in;
    var n: usize = 0;
    while (to_bb != 0) {
        const to: u8 = @ctz(to_bb);
        to_bb &= to_bb - 1;
        const from: u8 = @intCast(@as(i16, to) - offset);
        moves[n] = (@as(u16, from) << 6) | to;
        n += 1;
    }
    return n;
}

fn referenceMoves(from: u8, moves: []u16, to_bb_in: u64) usize {
    var to_bb = to_bb_in;
    var n: usize = 0;
    while (to_bb != 0) {
        const to: u8 = @ctz(to_bb);
        to_bb &= to_bb - 1;
        moves[n] = (@as(u16, from) << 6) | to;
        n += 1;
    }
    return n;
}

test "splatPawnMoves/splatMoves match scalar references over random masks" {
    if (!use_avx512_movegen) return error.SkipZigTest;
    var rng = std.Random.DefaultPrng.init(0xF00D_BABE_1234_5678);
    const random = rng.random();

    var trial: usize = 0;
    while (trial < 20000) : (trial += 1) {
        // Real callers only ever pass masks with <= 8 (pawn) or <= 32 (piece) bits
        // set (upstream's own asserted bounds); bias there but also cover 0 and the
        // full 64-bit sparse case as an extra margin.
        const bit_count = random.uintLessThan(u32, 33);
        var to_bb: u64 = 0;
        var placed: u32 = 0;
        while (placed < bit_count) {
            const sq = random.uintLessThan(u32, 64);
            const bit = @as(u64, 1) << @intCast(sq);
            if (to_bb & bit == 0) {
                to_bb |= bit;
                placed += 1;
            }
        }

        // Every offset a real caller instantiates (movegen.zig:189-220): single/double
        // pushes and both capture diagonals, both colors. Build to_bb FROM valid `from`
        // squares (from + offset, kept only if in [0,63]) rather than picking `to` bits
        // freely: a synthetic (to, offset) pair with no in-range `from` would trap
        // referencePawnMoves' cast on an input the real generator can never produce
        // (every real `to` bit already came from a real `from` square shifted by this
        // exact offset), not a case the vectorized code needs to handle either.
        inline for (.{ 8, -8, 16, -16, 7, -7, 9, -9 }) |offset| {
            var pawn_to_bb: u64 = 0;
            var pawn_placed: u32 = 0;
            while (pawn_placed < @min(bit_count, 8)) {
                const from_sq: i16 = @intCast(random.uintLessThan(u32, 64));
                const to_sq = from_sq + offset;
                if (to_sq < 0 or to_sq > 63) continue;
                const bit = @as(u64, 1) << @intCast(to_sq);
                if (pawn_to_bb & bit == 0) {
                    pawn_to_bb |= bit;
                    pawn_placed += 1;
                }
            }
            var ref: [40]u16 = undefined;
            var vec: [40]u16 = undefined;
            const n_ref = referencePawnMoves(offset, ref[0..], pawn_to_bb);
            const n_vec = splatPawnMoves(offset, &vec, pawn_to_bb);
            try testing.expectEqual(n_ref, n_vec);
            for (0..n_ref) |i| {
                testing.expectEqual(ref[i], vec[i]) catch |err| {
                    std.debug.print("pawn trial {d} offset {d} to_bb {x} mismatch at {d}\n", .{ trial, offset, pawn_to_bb, i });
                    return err;
                };
            }
        }

        const from: u8 = @intCast(random.uintLessThan(u32, 64));
        var ref2: [40]u16 = undefined;
        var vec2: [40]u16 = undefined;
        const n_ref2 = referenceMoves(from, ref2[0..], to_bb);
        const n_vec2 = splatMoves(from, &vec2, to_bb);
        try testing.expectEqual(n_ref2, n_vec2);
        for (0..n_ref2) |i| {
            testing.expectEqual(ref2[i], vec2[i]) catch |err| {
                std.debug.print("piece trial {d} from {d} to_bb {x} mismatch at {d}\n", .{ trial, from, to_bb, i });
                return err;
            };
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
