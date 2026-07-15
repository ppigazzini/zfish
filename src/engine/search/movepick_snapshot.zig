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

pub fn moveFrom(raw_move: u16) u8 {
    return @intCast((raw_move >> 6) & 0x3F);
}
pub fn moveTo(raw_move: u16) u8 {
    return @intCast(raw_move & 0x3F);
}
pub fn moveType(raw_move: u16) u16 {
    return raw_move & move_type_mask;
}
pub fn typeOf(piece: u8) u8 {
    return piece & 7;
}
pub fn squareMask(square: u8) u64 {
    return @as(u64, 1) << @intCast(square);
}
pub fn otherColor(color: u8) u8 {
    return if (color == white) black else white;
}

pub fn seeGe(pos: *const Position, raw_move: u16, threshold: c_int) bool {
    if (moveType(raw_move) != normal_move)
        return 0 >= threshold;

    const from = moveFrom(raw_move);
    const to = moveTo(raw_move);
    const moving_piece = pieceAt(pos, from);
    const captured_piece = pieceAt(pos, to);

    var swap = piece_values[@as(usize, captured_piece)] - threshold;
    if (swap < 0)
        return false;

    swap = piece_values[@as(usize, moving_piece)] - swap;
    if (swap <= 0)
        return true;

    var occupied = pos.by_type_bb[0] ^ squareMask(from) ^ squareMask(to);
    var stm = pos.side_to_move;
    var attackers = attackersTo(to, occupied, pos);
    var result: c_int = 1;

    while (true) {
        stm = otherColor(stm);
        attackers &= occupied;

        var stm_attackers = attackers & pos.by_color_bb[stm];
        if (stm_attackers == 0)
            break;

        if ((pos.st.pinners[otherColor(stm)] & occupied) != 0) {
            stm_attackers &= ~pos.st.blockers_for_king[stm];
            if (stm_attackers == 0)
                break;
        }

        result ^= 1;

        var candidates = stm_attackers & pos.by_type_bb[pawn];
        if (candidates != 0) {
            swap = piece_values[pawn] - swap;
            if (swap < result)
                break;
            occupied ^= leastSignificantSquareBb(candidates);
            attackers |= bitboard.attacks(bishop, to, occupied) & piecesByTypes(pos, bishop, queen);
            continue;
        }

        candidates = stm_attackers & pos.by_type_bb[knight];
        if (candidates != 0) {
            swap = piece_values[knight] - swap;
            if (swap < result)
                break;
            occupied ^= leastSignificantSquareBb(candidates);
            continue;
        }

        candidates = stm_attackers & pos.by_type_bb[bishop];
        if (candidates != 0) {
            swap = piece_values[bishop] - swap;
            if (swap < result)
                break;
            occupied ^= leastSignificantSquareBb(candidates);
            attackers |= bitboard.attacks(bishop, to, occupied) & piecesByTypes(pos, bishop, queen);
            continue;
        }

        candidates = stm_attackers & pos.by_type_bb[rook];
        if (candidates != 0) {
            swap = piece_values[rook] - swap;
            if (swap < result)
                break;
            occupied ^= leastSignificantSquareBb(candidates);
            attackers |= bitboard.attacks(rook, to, occupied) & piecesByTypes(pos, rook, queen);
            continue;
        }

        candidates = stm_attackers & pos.by_type_bb[queen];
        if (candidates != 0) {
            swap = piece_values[queen] - swap;
            occupied ^= leastSignificantSquareBb(candidates);
            attackers |= bitboard.attacks(bishop, to, occupied) & piecesByTypes(pos, bishop, queen);
            attackers |= bitboard.attacks(rook, to, occupied) & piecesByTypes(pos, rook, queen);
            continue;
        }

        return if ((attackers & ~pos.by_color_bb[stm]) != 0)
            (result ^ 1) != 0
        else
            result != 0;
    }

    return result != 0;
}

pub fn attackersTo(square: u8, occupied: u64, pos: *const Position) u64 {
    return (bitboard.attacks(rook, square, occupied) & piecesByTypes(pos, rook, queen)) |
        (bitboard.attacks(bishop, square, occupied) & piecesByTypes(pos, bishop, queen)) |
        (pawnAttackersTo(square, white) & piecesColorType(pos, white, pawn)) |
        (pawnAttackersTo(square, black) & piecesColorType(pos, black, pawn)) |
        (bitboard.attacks(knight, square, occupied) & pos.by_type_bb[knight]) |
        (bitboard.attacks(king, square, occupied) & pos.by_type_bb[king]);
}

pub fn piecesColorType(pos: *const Position, color: u8, piece_type: u8) u64 {
    return pos.by_color_bb[color] & pos.by_type_bb[piece_type];
}

pub fn piecesByTypes(pos: *const Position, first: u8, second: u8) u64 {
    return pos.by_type_bb[first] | pos.by_type_bb[second];
}

pub fn pieceAt(pos: *const Position, square: u8) u8 {
    return pos.board[@as(usize, square)];
}

pub fn attacksBy(pos: *const Position, color: u8, piece_type: u8) u64 {
    var pieces = piecesColorType(pos, color, piece_type);
    var result: u64 = 0;

    while (pieces != 0) {
        const piece_square_bb = leastSignificantSquareBb(pieces);
        const square: u8 = @intCast(@ctz(piece_square_bb));
        pieces ^= piece_square_bb;

        result |= if (piece_type == pawn)
            pawnAttacksFromSquare(square, color)
        else
            bitboard.attacks(piece_type, square, pos.by_type_bb[0]);
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

pub fn pawnAttacksFromSquare(square: u8, color: u8) u64 {
    const target = squareMask(square);
    return if (color == white)
        shift(north_west, target) | shift(north_east, target)
    else
        shift(south_west, target) | shift(south_east, target);
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
