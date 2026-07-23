// Provide the threat-index lookup tables of the full-threat feature set.
//
// Split from nnue_feature.zig on the 500-line lint: everything here is comptime
// table construction (index_lut1/index_lut2/offsets and the colocated
// ThreatRouteBlock planes) plus the piece/square constants the builders and the
// index formulas share. nnue_feature.zig re-imports the lot; no logic changed
// in the move.

const std = @import("std");
const nnue_feature_bb = @import("nnue_feature_bb.zig");
const makePiece = nnue_feature_bb.makePiece;
const constexprPopcount = nnue_feature_bb.constexprPopcount;
const typeOf = nnue_feature_bb.typeOf;
const colorOf = nnue_feature_bb.colorOf;
const pawnPushOrAttacks = nnue_feature_bb.pawnPushOrAttacks;
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
    var piece_index: usize = 0;
    while (piece_index < all_pieces.len) : (piece_index += 1) {
        const piece = all_pieces[piece_index];
        var cumulative_piece_offset: u32 = 0;
        var from: usize = 0;
        while (from < 64) : (from += 1) {
            local_offsets[piece][from] = cumulative_piece_offset;
            if (typeOf(piece) != pawn_piece_type) {
                cumulative_piece_offset += constexprPopcount(pseudoAttacks(typeOf(piece), from));
            } else if (from >= sq_a2 and from <= sq_h7) {
                const attacks = if (piece < 8) pawnPushOrAttacks(white, from) else pawnPushOrAttacks(black, from);
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
    var attacker_idx: usize = 0;
    while (attacker_idx < all_pieces.len) : (attacker_idx += 1) {
        const attacker = all_pieces[attacker_idx];
        var attacked_idx: usize = 0;
        while (attacked_idx < all_pieces.len) : (attacked_idx += 1) {
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

pub const king_buckets = [64]u32{
    28 * ps_nb, 29 * ps_nb, 30 * ps_nb, 31 * ps_nb, 31 * ps_nb, 30 * ps_nb, 29 * ps_nb, 28 * ps_nb,
    24 * ps_nb, 25 * ps_nb, 26 * ps_nb, 27 * ps_nb, 27 * ps_nb, 26 * ps_nb, 25 * ps_nb, 24 * ps_nb,
    20 * ps_nb, 21 * ps_nb, 22 * ps_nb, 23 * ps_nb, 23 * ps_nb, 22 * ps_nb, 21 * ps_nb, 20 * ps_nb,
    16 * ps_nb, 17 * ps_nb, 18 * ps_nb, 19 * ps_nb, 19 * ps_nb, 18 * ps_nb, 17 * ps_nb, 16 * ps_nb,
    12 * ps_nb, 13 * ps_nb, 14 * ps_nb, 15 * ps_nb, 15 * ps_nb, 14 * ps_nb, 13 * ps_nb, 12 * ps_nb,
    8 * ps_nb,  9 * ps_nb,  10 * ps_nb, 11 * ps_nb, 11 * ps_nb, 10 * ps_nb, 9 * ps_nb,  8 * ps_nb,
    4 * ps_nb,  5 * ps_nb,  6 * ps_nb,  7 * ps_nb,  7 * ps_nb,  6 * ps_nb,  5 * ps_nb,  4 * ps_nb,
    0 * ps_nb,  1 * ps_nb,  2 * ps_nb,  3 * ps_nb,  3 * ps_nb,  2 * ps_nb,  1 * ps_nb,  0 * ps_nb,
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

pub const num_valid_targets = [16]i32{ 0, 6, 10, 8, 8, 10, 0, 0, 0, 6, 10, 8, 8, 10, 0, 0 };

pub const full_map = [6][6]i32{
    .{ 0, 1, -1, 2, -1, -1 },
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

// Colocate one attacker's whole lookup state -- its flattened index_lut1 row
// ([attacked * 2 + less] addresses one element with one scaled index) and a
// merged u16 `offsets[from] + index_lut2[from][to]` plane -- so a threat index
// costs one block base plus two loads instead of three loads behind three
// separately scaled bases. The merge fits u16 with a wide margin: the largest
// per-from offset (queen, 1455) plus the largest within-from index still sits
// far below 65535, and the builder asserts every sum. The source tables above
// remain the comptime input; only the blocks are referenced at runtime.
pub const ThreatRouteBlock = extern struct {
    lut1: [32]u32,
    comb: [64 * 64]u16,
};

fn buildThreatRouteBlocks() [16]ThreatRouteBlock {
    @setEvalBranchQuota(4000000);
    var blocks = std.mem.zeroes([16]ThreatRouteBlock);
    for (&blocks, 0..) |*block, attacker| {
        block.lut1 = @bitCast(index_lut1[attacker]);
        for (0..64) |from| {
            for (0..64) |to| {
                const merged: u32 = offsets[attacker][from] + index_lut2[attacker][from][to];
                std.debug.assert(merged <= std.math.maxInt(u16));
                block.comb[from * 64 + to] = @intCast(merged);
            }
        }
    }
    return blocks;
}

pub const threat_route_blocks = buildThreatRouteBlocks();

pub const ps_nb: u32 = 11 * 64;
pub const full_dimensions: u32 = 60720;

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
