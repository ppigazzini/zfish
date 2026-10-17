// Provide the threat-index lookup tables of the full-threat feature set.
//
// Split from nnue_feature.zig on the 500-line lint: everything here is comptime
// table construction (index_lut1/index_lut2/offsets and the threat_lut1/threat_lut2
// tables the index formulas read) plus the piece/square constants the builders and
// the index formulas share. nnue_feature.zig re-imports the lot; no logic changed
// in the move.

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
const makePieceIndicesType = nnue_feature_bb.makePieceIndicesType;
const makePieceIndicesPawn = nnue_feature_bb.makePieceIndicesPawn;
fn indexLut2Array() [16][64][64]u8 {
    @setEvalBranchQuota(200000);
    const knight_attacks = makePieceIndicesType(knight_piece_type);
    const bishop_attacks = makePieceIndicesType(bishop_piece_type);
    const rook_attacks = makePieceIndicesType(rook_piece_type);
    const queen_attacks = makePieceIndicesType(queen_piece_type);
    const king_attacks = makePieceIndicesType(king_piece_type);

    var indices = std.mem.zeroes([16][64][64]u8);
    indices[w_pawn] = makePieceIndicesPawn(w_pawn);
    indices[b_pawn] = makePieceIndicesPawn(b_pawn);
    indices[w_knight] = knight_attacks;
    indices[b_knight] = knight_attacks;
    indices[w_bishop] = bishop_attacks;
    indices[b_bishop] = bishop_attacks;
    indices[w_rook] = rook_attacks;
    indices[b_rook] = rook_attacks;
    indices[w_queen] = queen_attacks;
    indices[b_queen] = queen_attacks;
    indices[w_king] = king_attacks;
    indices[b_king] = king_attacks;
    return indices;
}

const HelperOffsets = struct {
    cumulative_piece_offset: u32,
    cumulative_offset: u32,
};

fn initThreatOffsets() struct { first: [16]HelperOffsets, second: [16][64]u32 } {
    @setEvalBranchQuota(200000);
    var indices = std.mem.zeroes([16]HelperOffsets);
    var local_offsets = std.mem.zeroes([16][64]u32);
    var cumulative_offset: u32 = 0;
    for (0..all_pieces.len) |piece_index| {
        const piece = all_pieces[piece_index];
        var cumulative_piece_offset: u32 = 0;
        for (0..64) |from| {
            local_offsets[piece][from] = cumulative_piece_offset;
            if (typeOf(piece) != pawn_piece_type) {
                cumulative_piece_offset += constexprPopcount(pseudoAttacks(typeOf(piece), from));
            } else if (from >= sq_a2 and from <= sq_h7) {
                const attacks = if (piece < 8) pawnAttacksOnly(white, from) else pawnAttacksOnly(black, from);
                cumulative_piece_offset += constexprPopcount(attacks);
            }
        }
        indices[piece] = .{
            .cumulative_piece_offset = cumulative_piece_offset,
            .cumulative_offset = cumulative_offset,
        };
        cumulative_offset += @as(u32, num_valid_targets[piece]) * cumulative_piece_offset;
    }
    return .{ .first = indices, .second = local_offsets };
}

fn initIndexLuts() [16][16][2]u32 {
    @setEvalBranchQuota(200000);
    var indices = std.mem.zeroes([16][16][2]u32);
    for (0..all_pieces.len) |attacker_idx| {
        const attacker = all_pieces[attacker_idx];
        for (0..all_pieces.len) |attacked_idx| {
            const attacked = all_pieces[attacked_idx];
            const enemy = (attacker ^ attacked) == 8;
            const attacker_type = typeOf(attacker);
            const attacked_type = typeOf(attacked);
            const map_value = full_map[attacker_type - 1][attacked_type - 1];
            const semi_excluded = attacker_type == attacked_type and (enemy or attacker_type != pawn_piece_type);
            const excluded = map_value < 0;
            if (excluded) {
                indices[attacker][attacked][0] = full_dimensions;
                indices[attacker][attacked][1] = full_dimensions;
                continue;
            }

            const feature_slot: u32 = @intCast(colorOf(attacked) * (num_valid_targets[attacker] / 2) + map_value);
            const feature = helper_offsets[attacker].cumulative_offset + feature_slot * helper_offsets[attacker].cumulative_piece_offset;

            indices[attacker][attacked][0] = feature;
            indices[attacker][attacked][1] = if (semi_excluded) full_dimensions else feature;
        }
    }
    return indices;
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

pub const helper_offsets_and_offsets = initThreatOffsets();
pub const helper_offsets = helper_offsets_and_offsets.first;
pub const offsets = helper_offsets_and_offsets.second;
pub const index_lut1 = initIndexLuts();
pub const index_lut2 = indexLut2Array();

/// Flatten index_lut1 by the byte a dirty-threat record already carries in bits 16-23,
/// `attacker << 4 | attacked`: threat_lut1[pair * 2 + less] -- upstream b877fbde5's
/// ThreatLUTs.lut1, read through `&lut1[0][0]`.
pub const threat_lut1: [16 * 16 * 2]u32 align(64) = @bitCast(index_lut1);

/// Fold the per-from offset into one u16 plane per attacker piece TYPE -- upstream
/// b877fbde5's ThreatLUTs.lut2: threat_lut2[type][from * 64 + to]. A white and a black
/// attacker of one type share their offsets and their within-from indices, except a pawn,
/// whose two colours attack in opposite directions; `to < from` says which one moved, so the
/// pawn plane reads the black pawn's indices below `from` and the white pawn's above.
pub const threat_lut2: [8][64 * 64]u16 align(64) = blk: {
    @setEvalBranchQuota(4_000_000);
    var planes = std.mem.zeroes([8][64 * 64]u16);
    for (all_pieces[0..6]) |white_piece| {
        const pt = typeOf(white_piece);
        const black_piece = white_piece + 8;
        for (0..64) |from| {
            if (offsets[white_piece][from] != offsets[black_piece][from])
                @compileError("threat_lut2: the two colours' offsets differ");
            for (0..64) |to| {
                const source = if (pt == pawn_piece_type and to < from) black_piece else white_piece;
                const merged: u32 = offsets[white_piece][from] + index_lut2[source][from][to];
                planes[pt][from * 64 + to] = @intCast(merged);
            }
        }
    }
    break :blk planes;
};

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
