// Provide the threat-index lookup tables of the full-threat feature set.
//
// Split from nnue_feature.zig on the 500-line lint: everything here is comptime
// table construction (the threat_lut1/threat_lut2 tables the index formulas read, built
// in one pass) plus the piece/square constants the builder and the index formulas share.
// nnue_feature.zig re-imports the lot; no logic changed in the move.

const std = @import("std");
const dims = @import("nnue_dimensions");

/// Hold the two result shapes BOTH feature sets return. They are not lookup tables, but
/// this is the leaf every feature file already imports, and duplicating a struct across
/// files that must agree on it is how the two silently drift apart.
pub const FullAppendChangedLens = struct {
    removed: usize,
    added: usize,
};

pub const FullAppendResult = struct {
    len: usize,
    // Holds threats AND pawn-pair active indices for one perspective's refresh (both feed
    // the shared threatAndPp weight rows). Upstream's IndexList is ValueList<u16, 256>.
    indices: [256]u32,
};
const nnue_feature_bb = @import("nnue_feature_bb.zig");
const makePiece = nnue_feature_bb.makePiece;
const constexprPopcount = nnue_feature_bb.constexprPopcount;
const typeOf = nnue_feature_bb.typeOf;
const colorOf = nnue_feature_bb.colorOf;
const pawnPushOrAttacks = nnue_feature_bb.pawnPushOrAttacks;
const pawnAttacksOnly = nnue_feature_bb.pawnAttacksOnly;
const pseudoAttacks = nnue_feature_bb.pseudoAttacks;
const squareBb = nnue_feature_bb.squareBb;

/// Hold the two tables a threat index sums -- upstream's ThreatLUTs.
const ThreatLuts = struct {
    /// [attacker][attacked][from < to]
    lut1: [16][16][2]u32,
    /// [piece type][from * 64 + to]
    lut2: [8][64 * 64]u16,
};

/// Build both threat tables in one pass -- upstream's `init_threat_luts` (a1e94f955). The
/// lut2 walk already runs each piece type's feature count up, from by from, so lut1 reads
/// that total instead of recounting it per piece. A white and a black attacker of one type
/// share a plane: a pawn's two colours attack in opposite directions, and `to < from` says
/// which one moved, so the pawn plane counts the black pawn's attacks below `from` and the
/// white pawn's above -- and the two colours' totals agree, so the white walk counts both.
fn initThreatLuts() ThreatLuts {
    @setEvalBranchQuota(4_000_000);
    var tables: ThreatLuts = .{ .lut1 = std.mem.zeroes([16][16][2]u32), .lut2 = std.mem.zeroes([8][64 * 64]u16) };
    var offsets = std.mem.zeroes([8]u32);

    for ([_]u8{ pawn_piece_type, knight_piece_type, bishop_piece_type, rook_piece_type, queen_piece_type, king_piece_type }) |pt| {
        var offset: u32 = 0;
        for (0..64) |from| {
            for (0..64) |to| {
                const attacks = if (pt != pawn_piece_type)
                    pseudoAttacks(pt, from)
                else if (to < from)
                    pawnAttacksOnly(black, from)
                else
                    pawnAttacksOnly(white, from);
                tables.lut2[pt][from * 64 + to] = @intCast(offset + constexprPopcount((squareBb(to) - 1) & attacks));
            }

            if (pt != pawn_piece_type) {
                offset += constexprPopcount(pseudoAttacks(pt, from));
            } else if (from >= sq_a2 and from <= sq_h7) {
                offset += constexprPopcount(pawnAttacksOnly(white, from));
            }
        }
        offsets[pt] = offset;
    }

    var cumulative_offset: u32 = 0;
    for (all_pieces) |attacker| {
        const attacker_type = typeOf(attacker);
        const cumulative_piece_offset = offsets[attacker_type];
        const valid_targets: u32 = @intCast(num_valid_targets[attacker]);

        for (all_pieces) |attacked| {
            const enemy = (attacker ^ attacked) == 8;
            const attacked_type = typeOf(attacked);
            const map_value = full_map[attacker_type - 1][attacked_type - 1];
            const semi_excluded = attacker_type == attacked_type and (enemy or attacker_type != pawn_piece_type);
            // An excluded pair has no feature: its slot would be negative, and a u32 refuses it.
            if (map_value < 0) {
                tables.lut1[attacker][attacked] = .{ full_dimensions, full_dimensions };
                continue;
            }

            const feature_slot: u32 = @intCast(colorOf(attacked) * (valid_targets / 2) + map_value);
            const feature = cumulative_offset + feature_slot * cumulative_piece_offset;
            tables.lut1[attacker][attacked] = .{ feature, if (semi_excluded) full_dimensions else feature };
        }

        cumulative_offset += valid_targets * cumulative_piece_offset;
    }

    return tables;
}

pub const piece_square_index = [2][16]u32{
    .{ 0, 0, 128, 256, 384, 512, 640, 0, 0, 64, 192, 320, 448, 576, 640, 0 },
    .{ 0, 64, 192, 320, 448, 576, 640, 0, 0, 0, 128, 256, 384, 512, 640, 0 },
};

/// Space the 32 own-king buckets two piece-square blocks apart (K32Q2's `B(v) = v * 2 *
/// PS_NB`): the second block of each bucket is the opponent-has-a-queen state, reached by
/// adding `queen_offset`.
const kb_stride: u32 = 2 * ps_nb;

/// Offset a K32Q2 index into its bucket's second block when the opponent has a queen.
pub const queen_offset: u32 = ps_nb;

pub const king_buckets = [64]u32{
    28 * kb_stride, 29 * kb_stride, 30 * kb_stride, 31 * kb_stride, 31 * kb_stride, 30 * kb_stride, 29 * kb_stride, 28 * kb_stride,
    24 * kb_stride, 25 * kb_stride, 26 * kb_stride, 27 * kb_stride, 27 * kb_stride, 26 * kb_stride, 25 * kb_stride, 24 * kb_stride,
    20 * kb_stride, 21 * kb_stride, 22 * kb_stride, 23 * kb_stride, 23 * kb_stride, 22 * kb_stride, 21 * kb_stride, 20 * kb_stride,
    16 * kb_stride, 17 * kb_stride, 18 * kb_stride, 19 * kb_stride, 19 * kb_stride, 18 * kb_stride, 17 * kb_stride, 16 * kb_stride,
    12 * kb_stride, 13 * kb_stride, 14 * kb_stride, 15 * kb_stride, 15 * kb_stride, 14 * kb_stride, 13 * kb_stride, 12 * kb_stride,
    8 * kb_stride,  9 * kb_stride,  10 * kb_stride, 11 * kb_stride, 11 * kb_stride, 10 * kb_stride, 9 * kb_stride,  8 * kb_stride,
    4 * kb_stride,  5 * kb_stride,  6 * kb_stride,  7 * kb_stride,  7 * kb_stride,  6 * kb_stride,  5 * kb_stride,  4 * kb_stride,
    0 * kb_stride,  1 * kb_stride,  2 * kb_stride,  3 * kb_stride,  3 * kb_stride,  2 * kb_stride,  1 * kb_stride,  0 * kb_stride,
};

pub const orient_tbl_half = [64]u32{
    7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,
};

/// Fold every term halfMakeIndex adds to the square into one entry per (opponent-queen
/// state, perspective, king square, piece): upstream K32Q2::make_index's `offsets`, indexed
/// [(queen * 2 + perspective) * 64 + ksq][piece]. The index then costs one xor and one load
/// instead of two xors, three adds and three loads.
///
/// The xor is only an add in disguise because the carry cannot reach the square's bits:
/// piece_square_index, king_buckets and queen_offset are all multiples of 64 and the
/// orientation is below 64, so the entry's low six bits ARE the orientation. The comptime
/// check below holds that for every entry, and the largest (45055) is what makes u16
/// lossless.
pub const half_offsets: [2 * 2 * 64][16]u16 align(64) = blk: {
    @setEvalBranchQuota(20_000);
    var table: [2 * 2 * 64][16]u16 = undefined;
    for (0..2) |q| {
        for (0..2) |c| {
            const flip: u32 = 56 * c;
            for (0..64) |sq| {
                const orient: u32 = orient_tbl_half[sq] ^ flip;
                for (0..16) |pc| {
                    const base = piece_square_index[c][pc] + king_buckets[sq ^ flip] + q * queen_offset;
                    if (base % 64 != 0 or orient >= 64) @compileError("half_offsets: xor is not an add");
                    table[(q * 2 + c) * 64 + sq][pc] = @intCast(base + orient);
                }
            }
        }
    }
    break :blk table;
};

pub const orient_tbl_full = [64]i8{
    0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,
};

/// Pawn diagonal threats target only knights and rooks now (pawn-pawn relationships moved
/// to the PP_3Wide feature set), so a pawn has 4 valid targets (2 types x 2 colors) instead
/// of 6. Upstream SFNNv16 numValidTargets.
pub const num_valid_targets = [16]i32{ 0, 4, 10, 8, 8, 10, 0, 0, 0, 4, 10, 8, 8, 10, 0, 0 };

/// map[attackerType-1][attackedType-1]. The pawn row (attacker PAWN) now maps only KNIGHT
/// (slot 0) and ROOK (slot 1); PAWN/BISHOP/QUEEN/KING are excluded (-1).
pub const full_map = [6][6]i32{
    .{ -1, 0, -1, 1, -1, -1 },
    .{ 0, 1, 2, 3, 4, -1 },
    .{ 0, 1, 2, 3, -1, -1 },
    .{ 0, 1, 2, 3, -1, -1 },
    .{ 0, 1, 2, 3, 4, -1 },
    .{ -1, -1, -1, -1, -1, -1 },
};

const threat_luts = initThreatLuts();

/// Flatten lut1 by the byte a dirty-threat record already carries in bits 16-23,
/// `attacker << 4 | attacked`: threat_lut1[pair * 2 + less] -- upstream's ThreatLUTs.lut1,
/// read through `&lut1[0][0]` (b877fbde5).
pub const threat_lut1: [16 * 16 * 2]u32 align(64) = @bitCast(threat_luts.lut1);

/// Read one u16 plane per attacker piece TYPE, with the per-from offset folded in --
/// upstream's ThreatLUTs.lut2: threat_lut2[type][from * 64 + to] (b877fbde5).
pub const threat_lut2: [8][64 * 64]u16 align(64) = threat_luts.lut2;

pub const ps_nb: u32 = 11 * 64;
/// FullThreats::Dimensions (SFNNv16): the threat feature count, also PP_3Wide's IndexBase.
pub const full_dimensions: u32 = dims.threat_dimensions;

// ---- PP_3Wide (pawn-pair) feature set ---------------------------------------
// Pawn ids run over ranks 2-7 (48 squares) per color: id = 48*color + (square - SQ_A2).
pub const pp_pawn_ids: u32 = dims.pp_pawn_ids;
/// Dimensions = C(PawnIds, 2): every unordered pair of pawn ids.
pub const pp_dimensions: u32 = dims.pp_dimensions;
/// Pair features are concatenated onto threats in the shared weight array; the first pair
/// feature sits at index full_dimensions (== ThreatFeatureSet::Dimensions).
pub const pp_index_base: u32 = dims.pp_index_base;
pub const threat_and_pp_dimensions: u32 = dims.threat_and_pp_dimensions;

pub const rank1_bb: u64 = 0xff;
pub const rank8_bb: u64 = rank1_bb << (8 * 7);

/// PawnPairBB[s]: the squares that can host a pawn forming a pair with a pawn on s -- own
/// file plus the two adjacent files, restricted to ranks 2-7, excluding s. Color-independent.
/// Upstream bitboard.h PawnPairBB; built here since it is consumed only by the PP feature set.
pub const pawn_pair_bb: [64]u64 = blk: {
    @setEvalBranchQuota(200000);
    var out: [64]u64 = undefined;
    for (0..64) |s| {
        const file = file_a_bb << @intCast(s % 8);
        const files = file | ((file & ~file_h_bb) << 1) | ((file & ~file_a_bb) >> 1);
        out[s] = files & ~(rank1_bb | rank8_bb) & ~(@as(u64, 1) << @intCast(s));
    }
    break :blk out;
};

pub const white: u8 = 0;
pub const black: u8 = 1;

pub const pawn_piece_type: u8 = 1;
pub const knight_piece_type: u8 = 2;
pub const bishop_piece_type: u8 = 3;
pub const rook_piece_type: u8 = 4;
pub const queen_piece_type: u8 = 5;
pub const king_piece_type: u8 = 6;

pub const w_pawn: usize = 1;
pub const w_knight: usize = 2;
pub const w_bishop: usize = 3;
pub const w_rook: usize = 4;
pub const w_queen: usize = 5;
pub const w_king: usize = 6;
pub const b_pawn: usize = 9;
pub const b_knight: usize = 10;
pub const b_bishop: usize = 11;
pub const b_rook: usize = 12;
pub const b_queen: usize = 13;
pub const b_king: usize = 14;

pub const all_pieces = [_]usize{ w_pawn, w_knight, w_bishop, w_rook, w_queen, w_king, b_pawn, b_knight, b_bishop, b_rook, b_queen, b_king };

pub const no_piece: u8 = 0;
pub const sq_none: u8 = 64;
pub const square_count: usize = 64;
pub const sq_a2: usize = 8;
pub const sq_h7: usize = 55;

pub const file_a_bb: u64 = 0x0101010101010101;
pub const file_h_bb: u64 = file_a_bb << 7;

pub const north: i8 = 8;
pub const east: i8 = 1;
pub const south: i8 = -8;
pub const west: i8 = -1;
pub const north_east: i8 = 9;
pub const north_west: i8 = 7;
pub const south_east: i8 = -7;
pub const south_west: i8 = -9;

pub const rook_dirs = [_]i8{ north, south, east, west };
pub const bishop_dirs = [_]i8{ north_east, south_east, south_west, north_west };
pub const queen_dirs = [_]i8{ north, south, east, west, north_east, south_east, south_west, north_west };
pub const knight_steps = [_]i8{ -17, -15, -10, -6, 6, 10, 15, 17 };
pub const king_steps = [_]i8{ -9, -8, -7, -1, 1, 7, 8, 9 };
