// Write every threat in a mask in one pass, as upstream's write_multiple_dirties does
// (position.cpp:1157, gated on USE_AVX512ICL). The scalar loop this replaces
// (move_do_threats.zig's addDirtyThreat loops) is up to 16 iterations of
// pop_lsb -> board[sq] -> pack -> append, each dependent on the last, in
// threats_update_piece -- one of the hottest board functions in the profile.
//
// The whole 64-square board is one 64-byte register; `compress` turns the bitboard
// into the packed square list in one instruction, `permute` looks up all 16 pieces
// from the board register with no memory access at all, and a single ternary-logic
// op ORs the constant template together with both shifted fields.
//
// Gated on AVX512VBMI + AVX512VBMI2 -- the permute needs VBMI, the compress needs
// VBMI2, together the x86-64-avx512icl tier upstream gates this to. Below that,
// move_do_threats.zig keeps the scalar pop_lsb loop.
//
// The store is 16 words (64 bytes) UNMASKED, as upstream's is: DirtyThreats.list_values
// is DIRTY_THREAT_MAX(96) wide with a 16-slot tail past ordinary usage precisely so
// this cannot run off the end (position_types.zig). Only the first `count` words are
// meaningful -- list_size only advances by count, so any extra lanes beyond it are
// silently overwritten by the next write.

const std = @import("std");
const builtin = @import("builtin");
const position_types = @import("position_types");

const Position = position_types.Position;
const DirtyThreats = position_types.DirtyThreats;

pub const use_avx512_threats = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vbmi) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vbmi2);

const V64u8 = @Vector(64, u8);
const V64mask = @Vector(64, bool);
const V16i32 = @Vector(16, i32);

// LLVM intrinsic names/argument orders verified empirically: compiled each upstream
// intrinsic call with
//   clang -O2 -mavx512f -mavx512bw -mavx512vbmi -mavx512vbmi2 -S -emit-llvm
// and read the resulting `declare`/`call` lines. Two results were not what the C
// intrinsic names suggest: `_mm512_cvtepi8_epi32(_mm512_castsi512_si128(a))` lowers to
// a plain `shufflevector` (low 16 bytes) + `sext`, no intrinsic call at all; and
// `_mm512_maskz_permutexvar_epi8(k, idx, a)` lowers to an UNMASKED
// `llvm.x86.avx512.permvar.qi.512(a, idx)` (data first, index second) followed by a
// separate `select` against the mask -- the masking is not part of the permute
// intrinsic itself.
extern fn @"llvm.x86.avx512.mask.compress.v64i8"(a: V64u8, src: V64u8, mask: V64mask) V64u8;
extern fn @"llvm.x86.avx512.permvar.qi.512"(a: V64u8, idx: V64u8) V64u8;
extern fn @"llvm.x86.avx512.pternlog.d.512"(a: V16i32, b: V16i32, c: V16i32, imm: i32) V16i32;

const all_squares: V64u8 = blk: {
    var arr: [64]u8 = undefined;
    for (0..64) |i| arr[i] = @intCast(i);
    break :blk arr;
};

// Bit i set iff i % 4 == 0: the byte-level mask that keeps only the low byte of each
// 4-byte (i32) lane after the byte-granularity permute -- the lane's square index,
// zero-extended by cvtepi8_epi32 into the upper 3 bytes, is discarded there so the
// piece lookup below occupies the same low-byte position.
const permute_byte_mask: V64mask = @bitCast(@as(u64, 0x1111111111111111));

pub fn writeMultipleDirties(
    pos: *const Position,
    mask: u64,
    template_word: u32,
    comptime sq_shift: u5,
    comptime pc_shift: u5,
    dts: *DirtyThreats,
) void {
    if (mask == 0) return;
    const count: usize = @popCount(mask);

    const board: V64u8 = pos.board;
    const mask_v: V64mask = @bitCast(mask);

    // Compress: the compacted list of set-bit square indices, in order, in the low
    // `count` lanes; the rest (from the maskz zero passthru) are 0.
    const compressed = @"llvm.x86.avx512.mask.compress.v64i8"(all_squares, @splat(0), mask_v);

    // cvtepi8_epi32(castsi512_si128(compressed)): widen the low 16 (of 64) compressed
    // bytes to i32 lanes. Values are always in [0,63] (never negative as i8), so
    // sign- vs zero-extension is equivalent here.
    var low16: [16]i8 = undefined;
    inline for (0..16) |i| low16[i] = @bitCast(compressed[i]);
    const squares_i32: V16i32 = low16;

    // Permute: gather board[square] for each of the 16 lanes, masked to keep only the
    // low byte of each 4-byte group (the real lookup), zeroing the rest.
    const squares_bytes: V64u8 = @bitCast(squares_i32);
    const permuted = @"llvm.x86.avx512.permvar.qi.512"(board, squares_bytes);
    const pieces_bytes = @select(u8, permute_byte_mask, permuted, @as(V64u8, @splat(0)));
    const pieces_v: V16i32 = @bitCast(pieces_bytes);

    const shifted_sq = squares_i32 << @as(@Vector(16, u5), @splat(sq_shift));
    const shifted_pc = pieces_v << @as(@Vector(16, u5), @splat(pc_shift));
    const template_v: V16i32 = @splat(@bitCast(template_word));
    // 254 is A | B | C (upstream's own comment, taken as-is: the ternary-logic truth
    // table byte for bitwise OR of all three operands).
    const dirties = @"llvm.x86.avx512.pternlog.d.512"(template_v, shifted_sq, shifted_pc, 254);

    const dirties_u32: [16]u32 = @bitCast(dirties);
    inline for (0..16) |i| dts.list_values[dts.list_size + i] = dirties_u32[i];
    dts.list_size += count;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

// A pure-scalar reference over the same {mask, template_word, sq_shift, pc_shift}
// contract, independent of writeMultipleDirties, so the test cannot pass by both
// sides sharing a bug.
fn referenceWrite(pos: *const Position, mask_in: u64, template_word: u32, sq_shift: u5, pc_shift: u5, dts: *DirtyThreats) void {
    var mask = mask_in;
    while (mask != 0) {
        const sq: u32 = @ctz(mask);
        mask &= mask - 1;
        const piece: u32 = pos.board[sq];
        dts.list_values[dts.list_size] = template_word | (sq << sq_shift) | (piece << pc_shift);
        dts.list_size += 1;
    }
}

fn randomPosition(random: std.Random) Position {
    var pos: Position = undefined;
    for (0..64) |i| pos.board[i] = @intCast(random.uintLessThan(u32, 16));
    return pos;
}

test "writeMultipleDirties matches a scalar reference over random boards/masks/shifts" {
    if (comptime !use_avx512_threats) return error.SkipZigTest;
    var rng = std.Random.DefaultPrng.init(0xDEAD_BEEF_CAFE_F00D);
    const random = rng.random();

    const shift_pairs = [_][2]u5{ .{ 8, 16 }, .{ 0, 20 } };

    var trial: usize = 0;
    while (trial < 20000) : (trial += 1) {
        const pos = randomPosition(random);
        // Real call sites only ever mask down to <= 16 set bits (single-piece reach /
        // slider-attacker sets); bias toward that range but also cover 0 and the full
        // 64-bit sparse case.
        const bit_count = random.uintLessThan(u32, 17);
        var mask: u64 = 0;
        var placed: u32 = 0;
        while (placed < bit_count) {
            const sq = random.uintLessThan(u32, 64);
            const bit = @as(u64, 1) << @intCast(sq);
            if (mask & bit == 0) {
                mask |= bit;
                placed += 1;
            }
        }
        const template_word = random.int(u32) & 0x800F_0F00; // add + pc + threatened_pc bits only, leaving the varying fields clear
        const shift_pair = shift_pairs[random.uintLessThan(usize, shift_pairs.len)];

        var dts_ref: DirtyThreats = undefined;
        dts_ref.list_size = 0;
        var dts_vec: DirtyThreats = undefined;
        dts_vec.list_size = 0;

        switch (shift_pair[0]) {
            8 => {
                referenceWrite(&pos, mask, template_word, 8, 16, &dts_ref);
                writeMultipleDirties(&pos, mask, template_word, 8, 16, &dts_vec);
            },
            else => {
                referenceWrite(&pos, mask, template_word, 0, 20, &dts_ref);
                writeMultipleDirties(&pos, mask, template_word, 0, 20, &dts_vec);
            },
        }

        try testing.expectEqual(dts_ref.list_size, dts_vec.list_size);
        for (0..dts_ref.list_size) |i| {
            testing.expectEqual(dts_ref.list_values[i], dts_vec.list_values[i]) catch |err| {
                std.debug.print("trial {d} mask {x} mismatch at {d}\n", .{ trial, mask, i });
                return err;
            };
        }
    }
}

test {
    // Gate refAllDecls too, not just the cross-check test above: refAllDecls forces
    // analysis of every declaration in this file regardless of runtime reachability,
    // which would still try to codegen the AVX-512 intrinsic calls inside writeMultipleDirties on
    // a target that can't lower them -- a comptime guard on the call site alone (the
    // test above) does not stop that.
    if (comptime use_avx512_threats) std.testing.refAllDecls(@This());
}
