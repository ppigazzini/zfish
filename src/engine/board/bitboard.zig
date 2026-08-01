const std = @import("std");
const builtin = @import("builtin");

// Gate the PEXT slider-index path on the BMI2 target feature. This tracks the arch matrix's
// USE_PEXT macro 1:1 (every USE_PEXT tier sets .bmi2 in target_features and no other tier
// does), and unlike @import("build_options") it is also visible when this file is compiled as
// a standalone unit-test root -- matching how nnue_affine.zig gates its ISA kernels.
const use_pext = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .bmi2);

// Gate the dual hyperbola quintessence slider path on AVX2, tracking upstream's
// USE_DUAL_HYPERBOLA_QUINT (attacks.h:35, `#elif defined(USE_AVX2)`) 1:1. Below this tier
// upstream runs magic bitboards, same as bothAttacks' fallback below; at and above it,
// upstream does not even compile the magic tables (attacks.cpp:28) -- a footprint win
// this port does not take, since the derived-table bootstrap below (initDerivedTables)
// still walks the magic path unconditionally and reworking that is a separate change.
const use_avx2 = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

// LLVM's BMI2 parallel-bit-extract (PEXT). Referenced only on the use_pext path, behind
// the comptime gate in computeMagicIndex, so non-BMI2 targets never analyse or lower it.
const pext64 = struct {
    extern fn @"llvm.x86.bmi.pext.64"(u64, u64) u64;
}.@"llvm.x86.bmi.pext.64";

// Alias back the geometry/magic-index helpers, which now live in a std-only
// leaf (top-level decls are order-independent).
const bitboard_geom = @import("bitboard_geom.zig");
const PieceType = bitboard_geom.PieceType;
const betweenSquares = bitboard_geom.betweenSquares;
const lineStep = bitboard_geom.lineStep;
const knightAttacks = bitboard_geom.knightAttacks;
const kingAttacks = bitboard_geom.kingAttacks;
const squareAt = bitboard_geom.squareAt;
const safeDestination = bitboard_geom.safeDestination;
const fileBb = bitboard_geom.fileBb;
const rankBb = bitboard_geom.rankBb;
const squareBb = bitboard_geom.squareBb;
const rankOf = bitboard_geom.rankOf;
const fileOf = bitboard_geom.fileOf;
const absDiff = bitboard_geom.absDiff;
const magicIndexForPiece = bitboard_geom.magicIndexForPiece;
const lsb = bitboard_geom.lsb;

pub const Magic = struct {
    mask: u64,
    attacks: [*]u64,
    magic: u64,
    shift: c_uint,
};

const knight_piece: u8 = 2;
const bishop_piece: u8 = 3;
const rook_piece: u8 = 4;
const queen_piece: u8 = 5;
const king_piece: u8 = 6;

// Hold the runtime magic-bitboard attack tables (Stockfish-style): built once at startup by
// initSliderMagics() (invoked from position.initRuntime, before any position setup or
// search), read-only during search. The magic search builds each entry from the
// ray-cast slidingAttack reference, so attacksBb() returns bit-identical attack sets
// while replacing the per-node direction loop with an O(1) mask/multiply/shift/load.
// ~860 KB total; the single-threaded startup init is the only writer.
var rook_magic_attacks: [0x19000]u64 = undefined;
var bishop_magic_attacks: [0x1480]u64 = undefined;
// Align the table to a cache line, as upstream declares it (`alignas(64) Magic
// Magics[SQUARE_NB][2]`, attacks.cpp). @sizeOf(Magic) is 32, so a square's bishop/rook
// pair is exactly one line -- but only if the array starts on one. At the natural
// alignment of 8 that holds only by placement luck; land it at offset 16 and every
// probe of both sliders from one square straddles two lines, because `magic` and
// `shift` of the second entry fall past the boundary. Those two fields are read on the
// non-PEXT path, i.e. the sse41 tier.
var slider_magics: [64][2]Magic align(64) = undefined;

// Return both slider attack sets for a square in one call. At AVX2 and above this is
// upstream's dual hyperbola quintessence (attacks.h:91): the file/diagonal/antidiagonal
// masks for one square load as a single vector, one subtract/byte-reverse/xor pass
// produces all three ray sets at once, and the rank -- the one direction the trick
// cannot fold in, because a rank's eight squares share a byte -- comes from a small
// lookup. Below AVX2 this falls back to two magic lookups, upstream's own non-dual path.
pub const DualAttacks = struct { bishop: u64, rook: u64 };

const DualMagic = struct {
    // {file, diag, unused, antidiag} rays through the square, excluding it. A `@Vector`
    // field (not a raw byte load) so this needs no manual alignment/intrinsic handling;
    // LLVM picks the AVX2 op set at use_avx2 tiers on its own.
    masks: @Vector(4, u64),
    r: u64, // 2 * squareBb(s)
    rr: u64, // 2 * squareBb(63 - s)
    rank_file: u3, // row into rank_attacks this square's rank ray reads
    shift: u6, // 8 * rankOf(s): the occupancy byte for this square's rank
};

var dual_magics: [64]DualMagic = undefined;
// Sliding attacks within a rank, indexed by [file][6 INNER bits of the rank occupancy].
// A piece on a1 or h1 blocks nothing a rook on that rank can reach past, so the two edge
// bits never change the answer -- dropping them shrinks the table 4x, from 2 KB to 512 B,
// and is what upstream's own index does (attacks.h:107). Reuses slidingAttack(ROOK, file,
// occ6 << 1): occ is zero-extended past bit 7, so the north/south rays run unblocked off
// the top of a u64 and the u8 truncation drops them, leaving only the east/west ray bits.
//
// Built at comptime, so it lands in .rodata rather than being filled at startup.
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

comptime {
    // Keep the two facts joined: the alignment above buys a single-line probe only while
    // a square's bishop/rook pair still fits in one line, so widening Magic must fail the
    // build rather than silently undo it. Assert the SIZE only -- the compiler already
    // enforces the `align(64)` on the declaration, and reading it back by reflection is
    // not portable: `@typeInfo(...).pointer.alignment` exists in 0.16 and moved under
    // `.attrs` in 0.17, which broke the non-blocking Zig-master lane.
    std.debug.assert(@sizeOf([2]Magic) == 64);
}

// Hold the derived square-pair geometry, built once from the magics at startup and read-only during
// search -- the same tables upstream keeps (LineBB / BetweenBB / ray-pass). Without them
// line/between/rayPass each re-ray-cast on every call, and rayPass runs per slider per
// threat update per node.
var line_bb: [64][64]u64 = undefined;
var between_bb: [64][64]u64 = undefined;
var ray_pass_bb: [64][64]u64 = undefined;

// Hold the leaper attack tables -- upstream's PseudoAttacks[KNIGHT|KING][s]. The generators in
// bitboard_geom walk eight offsets through a bounds-checked squareAt() per call, so
// without these attacks() re-derives a leaper attack set on every SEE, movegen and
// threat update. Built once here from those same generators, so the sets are identical.
var knight_attacks_bb: [64]u64 = undefined;
var king_attacks_bb: [64]u64 = undefined;

// Hold the occupancy-free attack sets -- upstream's PseudoAttacks[pt][s]. A slider's empty-board
// reach depends only on its square, so deriving it through the magic pipeline (mask,
// multiply, shift, then a load from the ~860 KB attack table) re-computes a constant and
// touches cold memory. Upstream reads a 64-entry table; attacks_bb<Pt>(s) IS that read.
var pseudo_attacks_bb: [8][64]u64 = undefined;

pub fn initSliderMagics() void {
    initMagics(PieceType.rook, rook_magic_attacks[0..], &slider_magics);
    initMagics(PieceType.bishop, bishop_magic_attacks[0..], &slider_magics);
    // Always built, not just at use_avx2 tiers: bothAttacksAvx2 is exercised directly (not
    // just through the tier-gated bothAttacks dispatch) by the cross-check test below, on
    // every tier, so dual_magics must never be left undefined. (rank_attacks needs no
    // runtime init at all -- it is a comptime table.)
    initDualMagics();
    initLeaperTables();
    initDerivedTables();
}

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

fn initDualMagics() void {
    for (0..64) |s| {
        dual_magics[s] = .{
            .masks = .{
                lineMask(s, north, south),
                lineMask(s, north_east, south_west),
                0,
                lineMask(s, north_west, south_east),
            },
            .r = 2 *% squareBb(s),
            .rr = 2 *% squareBb(63 - s),
            .rank_file = @intCast(fileOf(s)),
            .shift = @intCast(8 * rankOf(s)),
        };
    }
}

fn bothAttacksAvx2(square: usize, occupied: u64) DualAttacks {
    const m = dual_magics[square];
    const occ_v: @Vector(4, u64) = @splat(occupied);
    const o = occ_v & m.masks;
    const fwd = o -% @as(@Vector(4, u64), @splat(m.r));
    const rev = @byteSwap(@byteSwap(o) -% @as(@Vector(4, u64), @splat(m.rr)));
    const result = (fwd ^ rev) & m.masks;
    // Skip the dead edge bit: shift one further and keep 6 bits, matching the table above.
    const inner_shift: u6 = m.shift + 1;
    const rank_ray = @as(u64, rank_attacks[m.rank_file][@intCast((occupied >> inner_shift) & 0x3f)]) << m.shift;
    // Lane 0 is the file ray (the rook's other direction); lanes 1 and 3 are the two
    // diagonals, ORed into the full bishop attack set (lane 2, mask_none, is always 0).
    return .{ .bishop = result[1] | result[3], .rook = result[0] +% rank_ray };
}

fn bothAttacksMagic(square: usize, occupied: u64) DualAttacks {
    return .{
        .bishop = attacksBb(PieceType.bishop, square, occupied, &slider_magics),
        .rook = attacksBb(PieceType.rook, square, occupied, &slider_magics),
    };
}

pub fn bothAttacks(square: u8, occupied: u64) DualAttacks {
    const sq: usize = square;
    if (comptime use_avx2) return bothAttacksAvx2(sq, occupied);
    return bothAttacksMagic(sq, occupied);
}

fn initLeaperTables() void {
    for (0..64) |s| {
        knight_attacks_bb[s] = knightAttacks(s);
        king_attacks_bb[s] = kingAttacks(s);
        const b = attacksBb(PieceType.bishop, s, 0, &slider_magics);
        const r = attacksBb(PieceType.rook, s, 0, &slider_magics);
        pseudo_attacks_bb[knight_piece][s] = knight_attacks_bb[s];
        pseudo_attacks_bb[bishop_piece][s] = b;
        pseudo_attacks_bb[rook_piece][s] = r;
        pseudo_attacks_bb[queen_piece][s] = b | r;
        pseudo_attacks_bb[king_piece][s] = king_attacks_bb[s];
    }
}

// Return upstream's attacks_bb<Pt>(s): the empty-board attack set, one table read.
pub fn pseudoAttacks(piece_type: u8, square: u8) u64 {
    return pseudo_attacks_bb[piece_type][@as(usize, square)];
}

fn initDerivedTables() void {
    for (0..64) |s1| {
        for (0..64) |s2| {
            line_bb[s1][s2] = 0;
            between_bb[s1][s2] = 0;
            ray_pass_bb[s1][s2] = 0;
        }
    }
    for (0..64) |s1| {
        for (piece_types) |pt| {
            for (0..64) |s2| {
                if ((slidingAttack(pt, s1, 0) & squareBb(s2)) != 0) {
                    line_bb[s1][s2] =
                        (attacksBb(pt, s1, 0, &slider_magics) & attacksBb(pt, s2, 0, &slider_magics)) |
                        squareBb(s1) | squareBb(s2);
                    between_bb[s1][s2] = attacksBb(pt, s1, squareBb(s2), &slider_magics) &
                        attacksBb(pt, s2, squareBb(s1), &slider_magics);
                    ray_pass_bb[s1][s2] = attacksBb(pt, s1, 0, &slider_magics) &
                        (attacksBb(pt, s2, squareBb(s1), &slider_magics) | squareBb(s2));
                }
                between_bb[s1][s2] |= squareBb(s2);
            }
        }
    }
}

pub fn attacks(piece_type: u8, square: u8, occupied: u64) u64 {
    const sq = @as(usize, @intCast(square));
    return switch (piece_type) {
        knight_piece => knight_attacks_bb[sq],
        bishop_piece => attacksBb(PieceType.bishop, sq, occupied, &slider_magics),
        rook_piece => attacksBb(PieceType.rook, sq, occupied, &slider_magics),
        queen_piece => attacksBb(PieceType.bishop, sq, occupied, &slider_magics) |
            attacksBb(PieceType.rook, sq, occupied, &slider_magics),
        king_piece => king_attacks_bb[sq],
        else => 0,
    };
}

pub fn between(from: u8, to: u8) u64 {
    return between_bb[from][to];
}

// Return the full line through two squares (both endpoints + the ray extended to the board
// edges) if they are aligned, else 0. Mirrors upstream LineBB construction.
pub fn line(s1: u8, s2: u8) u64 {
    return line_bb[s1][s2];
}

// Return RayPassBB[s1][s2]: from s1's attacks along the s1-s2 line, the squares at or
// beyond s2 (s1 removed from the occupancy). Mirrors the upstream init formula.
pub fn rayPass(s1: u8, s2: u8) u64 {
    return ray_pass_bb[s1][s2];
}

pub fn pretty(bitboard: u64) ?[]u8 {
    return prettyAlloc(bitboard) catch null;
}

fn prettyAlloc(bitboard: u64) ![]u8 {
    const allocator = std.heap.c_allocator;
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "+---+---+---+---+---+---+---+---+\n");

    var rank: i32 = 7;
    while (true) : (rank -= 1) {
        for (0..8) |file| {
            const square = @as(usize, @intCast(rank * 8 + @as(i32, @intCast(file))));
            try buffer.appendSlice(allocator, if ((bitboard & squareBb(square)) != 0) "| X " else "|   ");
        }

        const label = try std.fmt.allocPrint(allocator, "| {d}\n+---+---+---+---+---+---+---+---+\n", .{rank + 1});
        defer allocator.free(label);
        try buffer.appendSlice(allocator, label);

        if (rank == 0) {
            break;
        }
    }

    try buffer.appendSlice(allocator, "  a   b   c   d   e   f   g   h\n");
    return try buffer.toOwnedSlice(allocator);
}

const file_a_bb: u64 = 0x0101010101010101;
const file_h_bb: u64 = file_a_bb << 7;
const rank_1_bb: u64 = 0xff;
const rank_8_bb: u64 = rank_1_bb << (8 * 7);

const north: i8 = 8;
const east: i8 = 1;
const south: i8 = -north;
const west: i8 = -east;
const north_east: i8 = north + east;
const south_east: i8 = south + east;
const south_west: i8 = south + west;
const north_west: i8 = north + west;

const rook_directions = [_]i8{ north, south, east, west };
const bishop_directions = [_]i8{ north_east, south_east, south_west, north_west };
const piece_types = [_]PieceType{ PieceType.bishop, PieceType.rook };

const magic_seeds = [_][8]u64{
    .{ 8977, 44560, 54343, 38998, 5731, 95205, 104912, 17020 },
    .{ 728, 10316, 55013, 32803, 12281, 15100, 16645, 255 },
};

fn initMagics(pt: PieceType, table: []u64, magics: *[64][2]Magic) void {
    var occupancy: [4096]u64 = undefined;
    var epoch: [4096]i32 = @splat(0);
    var reference: [4096]u64 = @splat(0);
    var cnt: i32 = 0;
    var previous_size: usize = 0;
    const table_index = magicIndexForPiece(pt);

    for (0..64) |square| {
        const edges = ((rank_1_bb | rank_8_bb) & ~rankBb(square)) | ((file_a_bb | file_h_bb) & ~fileBb(square));
        var magic_ref = &magics[square][table_index];
        const attack_mask = slidingAttack(pt, square, 0);
        magic_ref.mask = attack_mask & ~edges;
        magic_ref.shift = @intCast(64 - @popCount(magic_ref.mask));
        magic_ref.attacks = if (square == 0)
            table.ptr
        else
            magics[square - 1][table_index].attacks + previous_size;

        var size: usize = 0;
        var subset: u64 = 0;
        while (true) {
            occupancy[size] = subset;
            reference[size] = slidingAttack(pt, square, subset);
            size += 1;
            subset = (subset -% magic_ref.mask) & magic_ref.mask;
            if (subset == 0) {
                break;
            }
        }

        var rng = Prng.init(magic_seeds[1][rankOf(square)]);
        while (true) {
            magic_ref.magic = 0;
            while (@popCount((magic_ref.magic *% magic_ref.mask) >> 56) < 6) {
                magic_ref.magic = rng.sparseRand();
            }

            cnt += 1;
            var entry: usize = 0;
            while (entry < size) : (entry += 1) {
                const idx = computeMagicIndex(magic_ref.*, occupancy[entry]);
                if (epoch[idx] < cnt) {
                    epoch[idx] = cnt;
                    magic_ref.attacks[idx] = reference[entry];
                } else if (magic_ref.attacks[idx] != reference[entry]) {
                    break;
                }
            }

            if (entry == size) {
                break;
            }
        }

        previous_size = size;
    }
}

fn attacksBb(pt: PieceType, square: usize, occupied: u64, magics: *[64][2]Magic) u64 {
    const magic_ref = magics[square][magicIndexForPiece(pt)];
    return magic_ref.attacks[computeMagicIndex(magic_ref, occupied)];
}

// Index the shared magic attack table. On BMI2 targets (use_pext) upstream drops the magic
// multiply and per-square shift entirely: @pext(occupied, mask) compacts the masked-occupancy
// bits into a dense [0, 2^popcount(mask)) index directly -- fewer per-node instructions.
// initMagics fills the table by this same index, so both paths return the bit-identical attack
// set (the bench signature is unchanged on every tier). Non-BMI2 targets keep the fixed-shift
// magic multiply.
fn computeMagicIndex(magic_ref: Magic, occupied: u64) usize {
    if (comptime use_pext) {
        return @intCast(pext64(occupied, magic_ref.mask));
    }
    return @intCast(((occupied & magic_ref.mask) *% magic_ref.magic) >> @as(u6, @intCast(magic_ref.shift)));
}

fn slidingAttack(pt: PieceType, square: usize, occupied: u64) u64 {
    var result: u64 = 0;
    const directions = if (pt == PieceType.rook) rook_directions[0..] else bishop_directions[0..];
    for (directions) |direction| {
        var current = square;
        while (true) {
            const destination = safeDestination(current, direction);
            if (destination == 0) {
                break;
            }
            result |= destination;
            current = lsb(destination);
            if ((occupied & destination) != 0) {
                break;
            }
        }
    }
    return result;
}

const Prng = struct {
    state: u64,

    fn init(seed: u64) Prng {
        return .{ .state = seed };
    }

    fn rand64(self: *Prng) u64 {
        self.state ^= self.state >> 12;
        self.state ^= self.state << 25;
        self.state ^= self.state >> 27;
        return self.state *% 2685821657736338717;
    }

    fn sparseRand(self: *Prng) u64 {
        return self.rand64() & self.rand64() & self.rand64();
    }
};

test "bothAttacksAvx2 matches the magic reference on every square, every rank/file/diagonal occupancy pattern, and 10000 random ones" {
    initSliderMagics();
    var rng = Prng.init(0xD1A6_0E1D_A9A2_11C5);
    for (0..64) |s| {
        const magic = bothAttacksMagic(s, 0);
        const avx2 = bothAttacksAvx2(s, 0);
        try std.testing.expectEqual(magic.bishop, avx2.bishop);
        try std.testing.expectEqual(magic.rook, avx2.rook);

        // Every single-bit occupancy: exercises each ray-blocking square individually,
        // including the square itself and every edge/corner case the rays can reach.
        for (0..64) |blocker| {
            const occ = squareBb(blocker);
            const m = bothAttacksMagic(s, occ);
            const a = bothAttacksAvx2(s, occ);
            try std.testing.expectEqual(m.bishop, a.bishop);
            try std.testing.expectEqual(m.rook, a.rook);
        }

        // Random full-board occupancies, biased dense (AND of three) and sparse (OR of
        // three) so both light and heavy occupancy regimes are covered.
        for (0..5000) |_| {
            const dense = rng.rand64() & rng.rand64() & rng.rand64();
            const sparse = rng.rand64() | rng.rand64() | rng.rand64();
            inline for (.{ dense, sparse }) |occ| {
                const m = bothAttacksMagic(s, occ);
                const a = bothAttacksAvx2(s, occ);
                try std.testing.expectEqual(m.bishop, a.bishop);
                try std.testing.expectEqual(m.rook, a.rook);
            }
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
