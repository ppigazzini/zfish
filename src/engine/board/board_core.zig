// Define the board primitives: piece/color/file/move-type constants, move-word decoders,
// and the small pure square helpers shared across the board code.
//
// Extract from position.zig so the clusters being split out of that god-file
// (FEN, legality/SEE, move gen, make/unmake) can share one definition of these
// primitives instead of each duplicating them. position.zig re-exports every
// symbol here, so its internal call sites are unchanged. The only dependency is
// position_types (for the Position type in the two board-aware helpers), keeping
// this a near-leaf: position_types <- board_core <- position, a clean DAG.

const std = @import("std");
const position_types = @import("position_types");
const Position = position_types.Position;

// Define the piece types (low 3 bits of a piece code).
pub const pawn_pt: u8 = 1;
pub const knight_pt: u8 = 2;
pub const bishop_pt: u8 = 3;
pub const rook_pt: u8 = 4;
pub const queen_pt: u8 = 5;
pub const king_pt: u8 = 6;

pub const color_white: u8 = 0;
pub const color_black: u8 = 1;

pub const file_a_bb: u64 = 0x0101010101010101;
pub const file_h_bb: u64 = 0x8080808080808080;
pub const rank1_bb: u64 = 0xFF;
pub const rank8_bb: u64 = 0xFF << 56;

// Define the MoveType (top 2 bits of the 16-bit move word).
pub const mt_normal: u16 = 0;
pub const mt_promotion: u16 = 1 << 14;
pub const mt_en_passant: u16 = 2 << 14;
pub const mt_castling: u16 = 3 << 14;

// List the non-pawn material value by piece type (index by piece & 7); pawn/none = 0.
pub const piece_value_by_type = [8]c_int{ 0, 208, 781, 825, 1276, 2538, 0, 0 };

pub inline fn sqBb(s: u8) u64 {
    return @as(u64, 1) << @intCast(s);
}
pub inline fn lsbBb(bb: u64) u64 {
    return bb & (~bb +% 1);
}
pub inline fn moveFrom(m: u16) u8 {
    return @intCast((m >> 6) & 0x3F);
}
pub inline fn moveTo(m: u16) u8 {
    return @intCast(m & 0x3F);
}
pub inline fn moveTypeOf(m: u16) u16 {
    return m & (3 << 14);
}
pub inline fn movePromotionType(m: u16) u8 {
    return @intCast(((m >> 12) & 3) + 2); // + KNIGHT
}
pub inline fn relativeSquare(c: u8, s: u8) u8 {
    return s ^ (c * 56);
}
pub inline fn makeSquare(f: u8, r: u8) u8 {
    return (r << 3) + f;
}
pub inline fn fileOf(square: u8) u8 {
    return square & 7;
}
pub inline fn rankOf(square: u8) u8 {
    return square >> 3;
}
pub inline fn colorOfPiece(pc: u8) u8 {
    return pc >> 3;
}
pub inline fn pieceTypeOn(pos: *const Position, s: u8) u8 {
    return pos.board[s] & 7;
}
pub inline fn isEmpty(pos: *const Position, s: u8) bool {
    return pos.board[s] == 0;
}

// Return the squares a color-c pawn on `s` attacks (attacks_bb<PAWN>(s, c)).
// Hold the pawn attack table -- upstream's PawnAttacks[c][s]. position.initRuntime calls
// initPawnAttacks() before any position setup or search.
var pawn_attacks_bb: [2][64]u64 = undefined;

pub fn initPawnAttacks() void {
    for (0..64) |sq| {
        const b: u64 = @as(u64, 1) << @intCast(sq);
        pawn_attacks_bb[color_white][sq] = ((b & ~file_h_bb) << 9) | ((b & ~file_a_bb) << 7);
        pawn_attacks_bb[color_black][sq] = ((b & ~file_h_bb) >> 7) | ((b & ~file_a_bb) >> 9);
    }
}

pub fn pawnAttacks(color: u8, sq: u8) u64 {
    return pawn_attacks_bb[color][sq];
}

pub inline fn kingSquare(pos: *const Position, c: u8) u8 {
    return @intCast(@ctz(pos.by_color_bb[c] & pos.by_type_bb[king_pt]));
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "move-word decoders split from/to/type" {
    // Encode from e2(12) to e4(28), a normal move.
    const m: u16 = (12 << 6) | 28;
    try testing.expectEqual(@as(u8, 12), moveFrom(m));
    try testing.expectEqual(@as(u8, 28), moveTo(m));
    try testing.expectEqual(mt_normal, moveTypeOf(m));
    // Encode the promo piece type in bits 12-13 of the promotion word (+KNIGHT).
    const promo: u16 = mt_promotion | (2 << 12); // 2 -> ROOK
    try testing.expectEqual(mt_promotion, moveTypeOf(promo));
    try testing.expectEqual(rook_pt, movePromotionType(promo));
}

test "sqBb/relativeSquare/makeSquare basics" {
    try testing.expectEqual(@as(u64, 1) << 5, sqBb(5));
    try testing.expectEqual(@as(u8, 0), relativeSquare(color_white, 0));
    try testing.expectEqual(@as(u8, 56), relativeSquare(color_black, 0));
    try testing.expectEqual(@as(u8, 28), makeSquare(4, 3)); // e4
}
