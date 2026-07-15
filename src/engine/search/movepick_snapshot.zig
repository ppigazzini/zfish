// Position analysis: the pure read-only board queries + static-exchange-evaluation,
// used by BOTH movepick scoring and SEE. Reads the live *const Position directly, as
// upstream's Position::see_ge does. bitboard + position_types only.

const std = @import("std");
const bitboard = @import("bitboard");
const position_types = @import("position_types");
const Position = position_types.Position;

const white: u8 = 0;
const black: u8 = 1;
const no_piece_type: u8 = 0;
const pawn: u8 = 1;
const knight: u8 = 2;
const bishop: u8 = 3;
const rook: u8 = 4;
const queen: u8 = 5;
const king: u8 = 6;
const normal_move: u16 = 0;
const move_type_mask: u16 = 3 << 14;
const file_a_bb: u64 = 0x0101010101010101;
const file_h_bb: u64 = file_a_bb << 7;
const north_east: i8 = 9;
const north_west: i8 = 7;
const south_east: i8 = -7;
const south_west: i8 = -9;
const piece_values = [_]c_int{
    0, 208, 781, 825, 1276, 2538, 0, 0,
    0, 208, 781, 825, 1276, 2538, 0, 0,
};

pub fn squareMask(square: u8) u64 {
    return @as(u64, 1) << @intCast(square);
}
pub fn otherColor(color: u8) u8 {
    return if (color == white) black else white;
}

pub fn piecesColorType(pos: *const Position, color: u8, piece_type: u8) u64 {
    return pos.by_color_bb[color] & pos.by_type_bb[piece_type];
}

pub fn pieceAt(pos: *const Position, square: u8) u8 {
    return pos.board[@as(usize, square)];
}

pub fn attacksBy(pos: *const Position, color: u8, piece_type: u8) u64 {
    // Pawns shift as a set: every pawn attacks the same two relative squares, so the
    // whole bitboard resolves in two shifts. Upstream's attacks_by<PAWN> does this
    // (pawn_attacks_bb over pieces(c, PAWN)); only the other types walk piece by piece.
    if (piece_type == pawn) {
        const pawns = piecesColorType(pos, color, pawn);
        return if (color == white)
            shift(north_west, pawns) | shift(north_east, pawns)
        else
            shift(south_west, pawns) | shift(south_east, pawns);
    }

    var pieces = piecesColorType(pos, color, piece_type);
    var result: u64 = 0;

    while (pieces != 0) {
        const piece_square_bb = leastSignificantSquareBb(pieces);
        const square: u8 = @intCast(@ctz(piece_square_bb));
        pieces ^= piece_square_bb;

        result |= bitboard.attacks(piece_type, square, pos.by_type_bb[0]);
    }

    return result;
}

pub fn checkSquares(pos: *const Position, piece_type: u8) u64 {
    const them = otherColor(pos.side_to_move);
    const them_king_square: u8 = @intCast(@ctz(pos.by_color_bb[them] & pos.by_type_bb[king]));

    return switch (piece_type) {
        pawn => pawnAttackersTo(them_king_square, pos.side_to_move),
        knight => bitboard.attacks(knight, them_king_square, pos.by_type_bb[0]),
        bishop => bitboard.attacks(bishop, them_king_square, pos.by_type_bb[0]),
        rook => bitboard.attacks(rook, them_king_square, pos.by_type_bb[0]),
        queen => bitboard.attacks(bishop, them_king_square, pos.by_type_bb[0]) |
            bitboard.attacks(rook, them_king_square, pos.by_type_bb[0]),
        king => 0,
        else => 0,
    };
}

pub fn pawnAttackersTo(square: u8, color: u8) u64 {
    const target = squareMask(square);
    return if (color == white)
        shift(south_west, target) | shift(south_east, target)
    else
        shift(north_west, target) | shift(north_east, target);
}

pub fn leastSignificantSquareBb(bitboard_value: u64) u64 {
    return bitboard_value & (~bitboard_value +% 1);
}

pub fn shift(comptime direction: i8, bitboard_value: u64) u64 {
    return switch (direction) {
        north_east => (bitboard_value & ~file_h_bb) << 9,
        north_west => (bitboard_value & ~file_a_bb) << 7,
        south_east => (bitboard_value & ~file_h_bb) >> 7,
        south_west => (bitboard_value & ~file_a_bb) >> 9,
        else => unreachable,
    };
}

test {
    @import("std").testing.refAllDecls(@This());
}
