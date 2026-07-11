// Position-snapshot analysis (ANNEX B.3): the pure PositionSnapshot query helpers +
// static-exchange-evaluation, used by BOTH movepick scoring and SEE. Value snapshot,
// no live-board aliasing. bitboard + snapshot only.

const std = @import("std");
const bitboard = @import("bitboard");
const position_snapshot = @import("position_snapshot");
const PositionSnapshot = position_snapshot.PositionSnapshot;

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

pub fn seeGeWithSnapshot(snapshot: *const PositionSnapshot, raw_move: u16, threshold: c_int) bool {
    if (moveType(raw_move) != normal_move)
        return 0 >= threshold;

    const from = moveFrom(raw_move);
    const to = moveTo(raw_move);
    const moving_piece = pieceAt(snapshot, from);
    const captured_piece = pieceAt(snapshot, to);

    var swap = piece_values[@as(usize, captured_piece)] - threshold;
    if (swap < 0)
        return false;

    swap = piece_values[@as(usize, moving_piece)] - swap;
    if (swap <= 0)
        return true;

    var occupied = snapshot.pieces_all ^ squareMask(from) ^ squareMask(to);
    var stm = snapshot.side_to_move;
    var attackers = attackersTo(to, occupied, snapshot);
    var result: c_int = 1;

    while (true) {
        stm = otherColor(stm);
        attackers &= occupied;

        var stm_attackers = attackers & snapshot.pieces_by_color[stm];
        if (stm_attackers == 0)
            break;

        if ((snapshot.pinners[otherColor(stm)] & occupied) != 0) {
            stm_attackers &= ~snapshot.blockers_for_king[stm];
            if (stm_attackers == 0)
                break;
        }

        result ^= 1;

        var candidates = stm_attackers & snapshot.pieces_by_type[pawn];
        if (candidates != 0) {
            swap = piece_values[pawn] - swap;
            if (swap < result)
                break;
            occupied ^= leastSignificantSquareBb(candidates);
            attackers |= bitboard.attacks(bishop, to, occupied) & piecesByTypes(snapshot, bishop, queen);
            continue;
        }

        candidates = stm_attackers & snapshot.pieces_by_type[knight];
        if (candidates != 0) {
            swap = piece_values[knight] - swap;
            if (swap < result)
                break;
            occupied ^= leastSignificantSquareBb(candidates);
            continue;
        }

        candidates = stm_attackers & snapshot.pieces_by_type[bishop];
        if (candidates != 0) {
            swap = piece_values[bishop] - swap;
            if (swap < result)
                break;
            occupied ^= leastSignificantSquareBb(candidates);
            attackers |= bitboard.attacks(bishop, to, occupied) & piecesByTypes(snapshot, bishop, queen);
            continue;
        }

        candidates = stm_attackers & snapshot.pieces_by_type[rook];
        if (candidates != 0) {
            swap = piece_values[rook] - swap;
            if (swap < result)
                break;
            occupied ^= leastSignificantSquareBb(candidates);
            attackers |= bitboard.attacks(rook, to, occupied) & piecesByTypes(snapshot, rook, queen);
            continue;
        }

        candidates = stm_attackers & snapshot.pieces_by_type[queen];
        if (candidates != 0) {
            swap = piece_values[queen] - swap;
            occupied ^= leastSignificantSquareBb(candidates);
            attackers |= bitboard.attacks(bishop, to, occupied) & piecesByTypes(snapshot, bishop, queen);
            attackers |= bitboard.attacks(rook, to, occupied) & piecesByTypes(snapshot, rook, queen);
            continue;
        }

        return if ((attackers & ~snapshot.pieces_by_color[stm]) != 0)
            (result ^ 1) != 0
        else
            result != 0;
    }

    return result != 0;
}

pub fn attackersTo(square: u8, occupied: u64, snapshot: *const PositionSnapshot) u64 {
    return (bitboard.attacks(rook, square, occupied) & piecesByTypes(snapshot, rook, queen)) |
        (bitboard.attacks(bishop, square, occupied) & piecesByTypes(snapshot, bishop, queen)) |
        (pawnAttackersTo(square, white) & piecesColorType(snapshot, white, pawn)) |
        (pawnAttackersTo(square, black) & piecesColorType(snapshot, black, pawn)) |
        (bitboard.attacks(knight, square, occupied) & snapshot.pieces_by_type[knight]) |
        (bitboard.attacks(king, square, occupied) & snapshot.pieces_by_type[king]);
}

pub fn piecesColorType(snapshot: *const PositionSnapshot, color: u8, piece_type: u8) u64 {
    return snapshot.pieces_by_color[color] & snapshot.pieces_by_type[piece_type];
}

pub fn piecesByTypes(snapshot: *const PositionSnapshot, first: u8, second: u8) u64 {
    return snapshot.pieces_by_type[first] | snapshot.pieces_by_type[second];
}

pub fn pieceAt(snapshot: *const PositionSnapshot, square: u8) u8 {
    return snapshot.board[@as(usize, square)];
}

pub fn attacksBy(snapshot: *const PositionSnapshot, color: u8, piece_type: u8) u64 {
    var pieces = piecesColorType(snapshot, color, piece_type);
    var result: u64 = 0;

    while (pieces != 0) {
        const piece_square_bb = leastSignificantSquareBb(pieces);
        const square: u8 = @intCast(@ctz(piece_square_bb));
        pieces ^= piece_square_bb;

        result |= if (piece_type == pawn)
            pawnAttacksFromSquare(square, color)
        else
            bitboard.attacks(piece_type, square, snapshot.pieces_all);
    }

    return result;
}

pub fn checkSquares(snapshot: *const PositionSnapshot, piece_type: u8) u64 {
    const them_king_square = snapshot.king_square[@as(usize, otherColor(snapshot.side_to_move))];

    return switch (piece_type) {
        pawn => pawnAttackersTo(them_king_square, snapshot.side_to_move),
        knight => bitboard.attacks(knight, them_king_square, snapshot.pieces_all),
        bishop => bitboard.attacks(bishop, them_king_square, snapshot.pieces_all),
        rook => bitboard.attacks(rook, them_king_square, snapshot.pieces_all),
        queen => bitboard.attacks(bishop, them_king_square, snapshot.pieces_all) |
            bitboard.attacks(rook, them_king_square, snapshot.pieces_all),
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
