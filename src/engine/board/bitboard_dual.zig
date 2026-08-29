// Answer both slider attack sets for one square in a single vector pass -- upstream's dual
// hyperbola quintessence (attacks.h:91), split out of bitboard.zig as its own leaf.
//
// The file/diagonal/antidiagonal masks for a square load as one @Vector(4, u64), and one
// subtract / reverse / xor pass produces every ray set at once. The RANK is the direction
// the trick historically could not fold in: hyperbola quintessence needs a full bit
// reversal, and the vector reversal is `vpshufb`, which moves whole bytes and so leaves a
// rank's eight bits inside the byte they came from. That is why the fourth lane is zero
// and the rank comes from a small table beside the vector call.
//
// Where the ISA can reverse the bits INSIDE a byte, it can. See `use_gfni_rank`.
//
// Below AVX2 nothing here runs: bitboard.zig falls back to two magic lookups, which is
// upstream's own non-dual path. The tests that check this kernel live in bitboard.zig,
// beside the magic reference and the naive ray walk they check it against.

const std = @import("std");
const builtin = @import("builtin");

const bitboard_geom = @import("bitboard_geom.zig");
const PieceType = bitboard_geom.PieceType;
const safeDestination = bitboard_geom.safeDestination;
const slidingAttack = bitboard_geom.slidingAttack;
const squareBb = bitboard_geom.squareBb;
const rankOf = bitboard_geom.rankOf;
const fileOf = bitboard_geom.fileOf;
const lsb = bitboard_geom.lsb;

const north: i8 = 8;
const east: i8 = 1;
const south: i8 = -north;
const west: i8 = -east;
const north_east: i8 = north + east;
const south_east: i8 = south + east;
const south_west: i8 = south + west;
const north_west: i8 = north + west;

// Gate the dual hyperbola quintessence slider path on AVX2, tracking upstream's
// USE_DUAL_HYPERBOLA_QUINT (attacks.h:35, `#elif defined(USE_AVX2)`) 1:1. Below this tier
// upstream runs magic bitboards, same as bothAttacks' fallback; at and above it, upstream
// does not even compile the magic tables (attacks.cpp:28) -- a footprint win this port
// does not take, since bitboard.zig's derived-table bootstrap (initDerivedTables) still
// walks the magic path unconditionally and reworking that is a separate change.
pub const use_avx2 = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

// Solve the RANK on the lane the other three rays leave empty, where the ISA can reverse
// bits inside a byte. `vgf2p8affineqb` by 0x8040201008040201 reverses the bits within
// every byte in one instruction, so a byte reversal followed by it IS the full 64-bit
// reversal -- and Zig's `@bitReverse` on a @Vector(4, u64) lowers to exactly that pair
// under GFNI (verified on the emitted asm: `vpshufb`, then `vgf2p8affineqb`). With the
// real reversal in hand the rank is no different from the other three rays, so it moves
// into the empty lane and the table, the shift and the scalar load beside every call all
// go. GFNI is enumerated at one tier here, x86-64-avx512icl (build/arch.zig); every other
// tier keeps the table. No branch is added, so there is no taken-rate to predict.
pub const use_gfni_rank = use_avx2 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .gfni);

pub const DualAttacks = struct { bishop: u64, rook: u64 };

const DualMagic = struct {
    // {file, diag, rank, antidiag} rays through the square, excluding it. Lane 2 is ZERO
    // without `use_gfni_rank`, where the reversal is a byte reversal and solves nothing on
    // a rank. A `@Vector` field (not a raw byte load) so this needs no manual
    // alignment/intrinsic handling; LLVM picks the AVX2 op set on its own.
    masks: @Vector(4, u64),
    r: u64, // 2 * squareBb(s)
    // 2 * squareBb(63 - s) -- 2 * the FULL bit reversal of `r`, which is what the GFNI
    // lane performs. The byte-reversing lanes agree with it only because no mask reaches
    // the bits the two disagree on, so this constant is unchanged by the switch.
    rr: u64,
    // Row into rank_attacks, and the occupancy byte for this square's rank. Both exist
    // only where the rank still needs the table.
    rank_file: if (use_gfni_rank) void else u3,
    shift: if (use_gfni_rank) void else u6, // 8 * rankOf(s)
};

var dual_magics: [64]DualMagic = undefined;

// Sliding attacks within a rank, indexed by [file][6 INNER bits of the rank occupancy].
// A piece on a1 or h1 blocks nothing a rook on that rank can reach past, so the two edge
// bits never change the answer -- dropping them shrinks the table 4x, from 2 KB to 512 B,
// and is what upstream's own index does (attacks.h:107). Reuses slidingAttack(ROOK, file,
// occ6 << 1): occ is zero-extended past bit 7, so the north/south rays run unblocked off
// the top of a u64 and the u8 truncation drops them, leaving only the east/west ray bits.
//
// Built at comptime, so it lands in .rodata rather than being filled at startup -- and
// under `use_gfni_rank` nothing references it, so it lands nowhere at all.
const rank_attacks: [8][64]u8 = blk: {
    @setEvalBranchQuota(200_000);
    var table: [8][64]u8 = undefined;
    for (0..8) |file| {
        for (0..64) |occ6| {
            table[file][occ6] = @truncate(slidingAttack(PieceType.rook, file, @as(u64, occ6) << 1));
        }
    }
    break :blk table;
};

// The ray through `square` along d1/d2, excluding `square` -- upstream's line_mask
// (attacks.cpp:81). Two directions only (not the full 4 slidingAttack sums per piece
// type), so the file ray and each diagonal stay separable in the DualMagic masks.
fn lineMask(square: usize, d1: i8, d2: i8) u64 {
    var mask: u64 = 0;
    inline for (.{ d1, d2 }) |d| {
        var s = square;
        while (true) {
            const dest = safeDestination(s, d);
            if (dest == 0) break;
            mask |= dest;
            s = lsb(dest);
        }
    }
    return mask;
}

pub fn initDualMagics() void {
    for (0..64) |s| {
        dual_magics[s] = .{
            .masks = .{
                lineMask(s, north, south),
                lineMask(s, north_east, south_west),
                if (comptime use_gfni_rank) lineMask(s, east, west) else 0,
                lineMask(s, north_west, south_east),
            },
            .r = 2 *% squareBb(s),
            .rr = 2 *% squareBb(63 - s),
            .rank_file = if (comptime use_gfni_rank) {} else @intCast(fileOf(s)),
            .shift = if (comptime use_gfni_rank) {} else @intCast(8 * rankOf(s)),
        };
    }
}

pub fn bothAttacksAvx2(square: usize, occupied: u64) DualAttacks {
    const m = dual_magics[square];
    const occ_v: @Vector(4, u64) = @splat(occupied);
    const o = occ_v & m.masks;
    const fwd = o -% @as(@Vector(4, u64), @splat(m.r));
    const rr: @Vector(4, u64) = @splat(m.rr);
    // The full bit reversal is the one hyperbola quintessence actually asks for; the byte
    // reversal is the cheap stand-in that happens to agree on the three rays whose squares
    // all sit in different bytes. Where the ISA does the real thing in one extra
    // instruction, take it -- and the rank becomes solvable on the lane that was zero.
    const rev = if (comptime use_gfni_rank)
        @bitReverse(@bitReverse(o) -% rr)
    else
        @byteSwap(@byteSwap(o) -% rr);
    const result = (fwd ^ rev) & m.masks;
    // Lane 0 is the file ray (the rook's other direction); lanes 1 and 3 are the two
    // diagonals, ORed into the full bishop attack set.
    const bishop = result[1] | result[3];
    if (comptime use_gfni_rank) {
        // Lane 2 carries the rank, so the rook falls out of the same vector as the rest.
        return .{ .bishop = bishop, .rook = result[0] | result[2] };
    }
    // Skip the dead edge bit: shift one further and keep 6 bits, matching the table above.
    const inner_shift: u6 = m.shift + 1;
    const rank_ray = @as(u64, rank_attacks[m.rank_file][@intCast((occupied >> inner_shift) & 0x3f)]) << m.shift;
    return .{ .bishop = bishop, .rook = result[0] +% rank_ray };
}
