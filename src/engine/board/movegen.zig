const std = @import("std");
const bitboard = @import("bitboard");
const position_snapshot = @import("position_snapshot");
const position_types = @import("position_types");

// The `pos` threaded through every generator is the board's typed Position (M18.7):
// each function hands it to position_snapshot.fill()/moveIsLegal(), which take it as
// the concrete type now. position_types is a pure std leaf, so no import cycle.
const Position = position_types.Position;

const white: u8 = 0;
const black: u8 = 1;

const pawn: u8 = 1;
const knight: u8 = 2;
const bishop: u8 = 3;
const rook: u8 = 4;
const queen: u8 = 5;
const king: u8 = 6;

const white_oo: u8 = 1;
const white_ooo: u8 = 2;
const black_oo: u8 = 4;
const black_ooo: u8 = 8;
const white_castling: u8 = white_oo | white_ooo;
const black_castling: u8 = black_oo | black_ooo;

const sq_none: u8 = 64;

const north: i8 = 8;
const east: i8 = 1;
const south: i8 = -8;
const west: i8 = -1;
const north_east: i8 = north + east;
const south_east: i8 = south + east;
const south_west: i8 = south + west;
const north_west: i8 = north + west;

const promotion: u16 = 1 << 14;
const en_passant: u16 = 2 << 14;
const castling: u16 = 3 << 14;
const move_type_mask: u16 = 3 << 14;

const file_a_bb: u64 = 0x0101010101010101;
const file_h_bb: u64 = file_a_bb << 7;
const rank_2_bb: u64 = 0x000000000000ff00;
const rank_3_bb: u64 = 0x0000000000ff0000;
const rank_6_bb: u64 = 0x0000ff0000000000;
const rank_7_bb: u64 = 0x00ff000000000000;

pub const PositionSnapshot = position_snapshot.PositionSnapshot;

const GenType = enum {
    captures,
    quiets,
    evasions,
    non_evasions,
};

const MoveWriter = struct {
    moves: [*]u16,
    len: usize = 0,

    fn push(self: *MoveWriter, raw: u16) void {
        self.moves[self.len] = raw;
        self.len += 1;
    }
};

pub fn generateCaptures(pos: *const Position, move_list: [*]u16) usize {
    return generate(.captures, pos, move_list);
}

pub fn generateQuiets(pos: *const Position, move_list: [*]u16) usize {
    return generate(.quiets, pos, move_list);
}

pub fn generateEvasions(pos: *const Position, move_list: [*]u16) usize {
    return generate(.evasions, pos, move_list);
}

pub fn generateNonEvasions(pos: *const Position, move_list: [*]u16) usize {
    return generate(.non_evasions, pos, move_list);
}

pub fn generateLegal(pos: *const Position, move_list: [*]u16) usize {
    var snapshot = loadSnapshot(pos);

    const count = if (snapshot.checkers != 0)
        generateWithSnapshot(.evasions, &snapshot, move_list)
    else
        generateWithSnapshot(.non_evasions, &snapshot, move_list);

    return filterLegalMoves(pos, &snapshot, move_list, count);
}

fn generate(comptime kind: GenType, pos: *const Position, move_list: [*]u16) usize {
    var snapshot = loadSnapshot(pos);

    return generateWithSnapshot(kind, &snapshot, move_list);
}

fn loadSnapshot(pos: *const Position) PositionSnapshot {
    var snapshot = std.mem.zeroes(PositionSnapshot);
    position_snapshot.fill(pos, &snapshot);
    snapshot.pieces_by_type[0] = snapshot.pieces_all;

    return snapshot;
}

fn generateWithSnapshot(
    comptime kind: GenType,
    snapshot: *const PositionSnapshot,
    move_list: [*]u16,
) usize {
    var writer = MoveWriter{ .moves = move_list };
    switch (snapshot.side_to_move) {
        white => generateAll(white, kind, snapshot, &writer),
        black => generateAll(black, kind, snapshot, &writer),
        else => unreachable,
    }

    return writer.len;
}

fn generateAll(
    comptime us: u8,
    comptime kind: GenType,
    snapshot: *const PositionSnapshot,
    writer: *MoveWriter,
) void {
    const them = otherColor(us);
    const ksq = snapshot.king_square[us];
    var target: u64 = 0;

    if (kind != .evasions or !moreThanOne(snapshot.checkers)) {
        target = switch (kind) {
            .evasions => bitboard.between(ksq, lsb(snapshot.checkers)),
            .non_evasions => ~piecesColor(snapshot, us),
            .captures => piecesColor(snapshot, them),
            .quiets => ~snapshot.pieces_all,
        };

        generatePawnMoves(us, kind, snapshot, writer, target);
        generateMoves(us, kind, knight, snapshot, writer, target);
        generateMoves(us, kind, bishop, snapshot, writer, target);
        generateMoves(us, kind, rook, snapshot, writer, target);
        generateMoves(us, kind, queen, snapshot, writer, target);
    }

    const king_target = if (kind == .evasions) ~piecesColor(snapshot, us) else target;
    splatMoves(writer, ksq, bitboard.attacks(king, ksq, 0) & king_target);

    if ((kind == .quiets or kind == .non_evasions) and canCastleAny(snapshot, us)) {
        const king_side = kingSideRight(us);
        if (!isCastlingImpeded(snapshot, king_side) and canCastle(snapshot, king_side)) {
            writer.push(makeSpecialMove(castling, ksq, castlingRookSquare(snapshot, king_side), knight));
        }

        const queen_side = queenSideRight(us);
        if (!isCastlingImpeded(snapshot, queen_side) and canCastle(snapshot, queen_side)) {
            writer.push(makeSpecialMove(castling, ksq, castlingRookSquare(snapshot, queen_side), knight));
        }
    }
}

fn generatePawnMoves(
    comptime us: u8,
    comptime kind: GenType,
    snapshot: *const PositionSnapshot,
    writer: *MoveWriter,
    target: u64,
) void {
    const them = otherColor(us);
    const empty_squares = ~snapshot.pieces_all;
    const enemies = if (kind == .evasions) snapshot.checkers else piecesColor(snapshot, them);
    const t_rank_7 = if (us == white) rank_7_bb else rank_2_bb;
    const t_rank_3 = if (us == white) rank_3_bb else rank_6_bb;
    const up: i8 = if (us == white) north else south;
    const up_right: i8 = if (us == white) north_east else south_west;
    const up_left: i8 = if (us == white) north_west else south_east;

    const pawns_on_7 = piecesColorType(snapshot, us, pawn) & t_rank_7;
    const pawns_not_on_7 = piecesColorType(snapshot, us, pawn) & ~t_rank_7;

    if (kind != .captures) {
        var b1 = shift(up, pawns_not_on_7) & empty_squares;
        var b2 = shift(up, b1 & t_rank_3) & empty_squares;

        if (kind == .evasions) {
            b1 &= target;
            b2 &= target;
        }

        splatPawnMoves(writer, up, b1);
        splatPawnMoves(writer, up + up, b2);
    }

    if (pawns_on_7 != 0) {
        var b1 = shift(up_right, pawns_on_7) & enemies;
        var b2 = shift(up_left, pawns_on_7) & enemies;
        var b3 = shift(up, pawns_on_7) & empty_squares;

        if (kind == .evasions) {
            b3 &= target;
        }

        while (b1 != 0) {
            makePromotions(kind, up_right, true, writer, popLsb(&b1));
        }

        while (b2 != 0) {
            makePromotions(kind, up_left, true, writer, popLsb(&b2));
        }

        while (b3 != 0) {
            makePromotions(kind, up, false, writer, popLsb(&b3));
        }
    }

    if (kind == .captures or kind == .evasions or kind == .non_evasions) {
        const b1 = shift(up_right, pawns_not_on_7) & enemies;
        const b2 = shift(up_left, pawns_not_on_7) & enemies;

        splatPawnMoves(writer, up_right, b1);
        splatPawnMoves(writer, up_left, b2);

        if (snapshot.ep_square != sq_none) {
            if (kind == .evasions and (target & squareBb(addDirection(snapshot.ep_square, up))) != 0) {
                return;
            }

            var ep_attackers = pawns_not_on_7 & pawnAttacksFromSquare(snapshot.ep_square, them);
            while (ep_attackers != 0) {
                const from = popLsb(&ep_attackers);
                writer.push(makeSpecialMove(en_passant, from, snapshot.ep_square, knight));
            }
        }
    }
}

fn generateMoves(
    comptime us: u8,
    comptime kind: GenType,
    comptime piece_type: u8,
    snapshot: *const PositionSnapshot,
    writer: *MoveWriter,
    target: u64,
) void {
    _ = kind;

    var pieces = piecesColorType(snapshot, us, piece_type);
    while (pieces != 0) {
        const from = popLsb(&pieces);
        const attacks = bitboard.attacks(piece_type, from, snapshot.pieces_all) & target;
        splatMoves(writer, from, attacks);
    }
}

fn makePromotions(
    comptime kind: GenType,
    comptime offset: i8,
    comptime enemy: bool,
    writer: *MoveWriter,
    to: u8,
) void {
    const from = subtractDirection(to, offset);
    const all = kind == .evasions or kind == .non_evasions;

    if (kind == .captures or all) {
        writer.push(makeSpecialMove(promotion, from, to, queen));
    }

    if ((kind == .captures and enemy) or (kind == .quiets and !enemy) or all) {
        writer.push(makeSpecialMove(promotion, from, to, rook));
        writer.push(makeSpecialMove(promotion, from, to, bishop));
        writer.push(makeSpecialMove(promotion, from, to, knight));
    }
}

fn splatPawnMoves(writer: *MoveWriter, comptime offset: i8, to_bb: u64) void {
    var targets = to_bb;
    while (targets != 0) {
        const to = popLsb(&targets);
        writer.push(makeMove(subtractDirection(to, offset), to));
    }
}

fn splatMoves(writer: *MoveWriter, from: u8, to_bb: u64) void {
    var targets = to_bb;
    while (targets != 0) {
        writer.push(makeMove(from, popLsb(&targets)));
    }
}

fn makeMove(from: u8, to: u8) u16 {
    return (@as(u16, from) << 6) | @as(u16, to);
}

fn makeSpecialMove(kind: u16, from: u8, to: u8, promotion_piece: u8) u16 {
    const promotion_bits: u16 = if (kind == promotion)
        @as(u16, promotion_piece - knight) << 12
    else
        0;
    return kind | promotion_bits | (@as(u16, from) << 6) | @as(u16, to);
}

fn piecesColor(snapshot: *const PositionSnapshot, color: u8) u64 {
    return snapshot.pieces_by_color[color];
}

fn piecesColorType(snapshot: *const PositionSnapshot, color: u8, piece_type: u8) u64 {
    return snapshot.pieces_by_color[color] & snapshot.pieces_by_type[piece_type];
}

fn otherColor(color: u8) u8 {
    return color ^ 1;
}

fn canCastle(snapshot: *const PositionSnapshot, right: u8) bool {
    return (snapshot.castling_rights & right) != 0;
}

fn canCastleAny(snapshot: *const PositionSnapshot, color: u8) bool {
    const mask = if (color == white) white_castling else black_castling;
    return (snapshot.castling_rights & mask) != 0;
}

fn isCastlingImpeded(snapshot: *const PositionSnapshot, right: u8) bool {
    return snapshot.castling_impeded[right] != 0;
}

fn castlingRookSquare(snapshot: *const PositionSnapshot, right: u8) u8 {
    return snapshot.castling_rook_square[right];
}

fn kingSideRight(color: u8) u8 {
    return if (color == white) white_oo else black_oo;
}

fn queenSideRight(color: u8) u8 {
    return if (color == white) white_ooo else black_ooo;
}

fn addDirection(square: u8, dir: i8) u8 {
    return @intCast(@as(i16, @intCast(square)) + @as(i16, dir));
}

fn subtractDirection(square: u8, dir: i8) u8 {
    return @intCast(@as(i16, @intCast(square)) - @as(i16, dir));
}

fn moreThanOne(bb: u64) bool {
    return (bb & (bb - 1)) != 0;
}

fn squareBb(square: u8) u64 {
    return @as(u64, 1) << @as(u6, @intCast(square));
}

fn filterLegalMoves(
    pos: *const Position,
    snapshot: *const PositionSnapshot,
    move_list: [*]u16,
    count: usize,
) usize {
    const us = snapshot.side_to_move;
    const pinned = snapshot.blockers_for_king[us] & piecesColor(snapshot, us);
    const king_square = snapshot.king_square[us];

    var keep_count: usize = 0;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const raw_move = move_list[index];
        if (!requiresLegalCheck(raw_move, pinned, king_square) or
            position_snapshot.moveIsLegal(pos, raw_move))
        {
            move_list[keep_count] = raw_move;
            keep_count += 1;
        }
    }

    return keep_count;
}

fn requiresLegalCheck(raw_move: u16, pinned: u64, king_square: u8) bool {
    const from = moveFrom(raw_move);
    return ((pinned & squareBb(from)) != 0) or from == king_square or moveType(raw_move) == en_passant;
}

fn moveFrom(raw_move: u16) u8 {
    return @intCast((raw_move >> 6) & 0x3f);
}

fn moveType(raw_move: u16) u16 {
    return raw_move & move_type_mask;
}

fn lsb(bb: u64) u8 {
    return @intCast(@ctz(bb));
}

fn popLsb(bb: *u64) u8 {
    const square = lsb(bb.*);
    bb.* &= bb.* - 1;
    return square;
}

fn shift(comptime dir: i8, bb: u64) u64 {
    return switch (dir) {
        north => bb << 8,
        south => bb >> 8,
        north + north => bb << 16,
        south + south => bb >> 16,
        east => (bb & ~file_h_bb) << 1,
        west => (bb & ~file_a_bb) >> 1,
        north_east => (bb & ~file_h_bb) << 9,
        north_west => (bb & ~file_a_bb) << 7,
        south_east => (bb & ~file_h_bb) >> 7,
        south_west => (bb & ~file_a_bb) >> 9,
        else => unreachable,
    };
}

fn pawnAttacksFromSquare(square: u8, color: u8) u64 {
    const bb = squareBb(square);
    return if (color == white)
        shift(north_west, bb) | shift(north_east, bb)
    else
        shift(south_west, bb) | shift(south_east, bb);
}

test {
    @import("std").testing.refAllDecls(@This());
}
