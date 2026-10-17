// Generate LEGAL moves only (upstream 400c23f97): a pinned piece moves along its pin line,
// the king steps only onto squares the other side does not threaten, and castling checks its
// path while it is generated. Nothing downstream filters a list or re-tests a move it was
// handed.

const std = @import("std");
const board_core = @import("board_core");
const bitboard = @import("bitboard");
const position_types = @import("position_types");
const movegen_splat_avx512 = @import("movegen_splat_avx512.zig");

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

const sq_none = board_core.sq_none;

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

const all_pieces = board_core.all_pieces;
const kingSquare = board_core.kingSquare;
const relativeSquare = board_core.relativeSquare;

const file_a_bb: u64 = 0x0101010101010101;
const file_h_bb: u64 = file_a_bb << 7;
const rank_2_bb: u64 = 0x000000000000ff00;
const rank_3_bb: u64 = 0x0000000000ff0000;
const rank_6_bb: u64 = 0x0000ff0000000000;
const rank_7_bb: u64 = 0x00ff000000000000;

/// Read what the side not to move attacks with piece type `pt`, or with every piece at
/// `all_pieces` -- upstream's Position::threats_by. The make leaves the sets unfilled and
/// marks them so with an empty total (state_setup.setExtraBitboards), and the first read
/// fills them (upstream 6a9ec5c33): a node that never generates a king move or scores a
/// quiet never pays for them. An empty total is never a real one -- the side not to move
/// always has a king, and a king attacks three squares at least.
pub inline fn threatsBy(pos: *const Position, comptime pt: u8) u64 {
    if (pos.st.threats[all_pieces] == 0) computeThreats(pos);
    return pos.st.threats[pt];
}

/// Fill StateInfo.threats -- upstream's Position::compute_threats. The mover's own king is
/// lifted off the board, so a slider's ray runs THROUGH it: a king that steps back along a
/// checking ray is still in check. It changes nothing when the mover is not in check, since
/// then no ray reaches that king. Queen and king attacks reach the total alone.
fn computeThreats(pos: *const Position) void {
    const them = pos.side_to_move ^ 1;
    const occ = pos.by_type_bb[0] ^ squareBb(kingSquare(pos, pos.side_to_move));
    const theirs = pos.by_color_bb[them];
    const threats = &pos.st.threats;
    threats[pawn] = pawnAttacksSet(them, theirs & pos.by_type_bb[pawn]);
    threats[knight] = attacksFrom(knight, theirs & pos.by_type_bb[knight], occ);
    threats[bishop] = attacksFrom(bishop, theirs & pos.by_type_bb[bishop], occ);
    threats[rook] = attacksFrom(rook, theirs & pos.by_type_bb[rook], occ);
    threats[all_pieces] = threats[pawn] | threats[knight] | threats[bishop] | threats[rook] |
        attacksFrom(queen, theirs & pos.by_type_bb[queen], occ) |
        bitboard.attacks(king, kingSquare(pos, them), 0);
}

/// Shift a pawn SET to the squares it attacks: every pawn of a colour attacks the same two
/// relative squares, so the whole bitboard resolves in two shifts (upstream pawn_attacks_bb).
fn pawnAttacksSet(color: u8, pawns: u64) u64 {
    return if (color == white)
        ((pawns & ~file_h_bb) << 9) | ((pawns & ~file_a_bb) << 7)
    else
        ((pawns & ~file_h_bb) >> 7) | ((pawns & ~file_a_bb) >> 9);
}

/// Union the attacks of every piece of type `pt` in `pieces` over occupancy `occ`.
inline fn attacksFrom(comptime pt: u8, pieces: u64, occ: u64) u64 {
    var b = pieces;
    var result: u64 = 0;
    while (b != 0) {
        const s: u8 = @intCast(@ctz(b));
        b &= b - 1;
        result |= bitboard.attacks(pt, s, occ);
    }
    return result;
}

const GenType = enum {
    captures,
    quiets,
    evasions,
};

const MoveWriter = struct {
    moves: []u16,
    len: usize = 0,

    /// Keep the caller's length: every caller passes a [256]u16 and 218 is the true legal
    /// maximum, but a many-pointer means no build mode -- including the ReleaseSafe fuzz
    /// artifact that exists for this class -- can trap a generator that over-emits.
    fn push(self: *MoveWriter, raw: u16) void {
        self.moves[self.len] = raw;
        self.len += 1;
    }
};

pub fn generateCaptures(pos: *const Position, move_list: []u16) usize {
    return generate(.captures, pos, move_list);
}

pub fn generateQuiets(pos: *const Position, move_list: []u16) usize {
    return generate(.quiets, pos, move_list);
}

pub fn generateEvasions(pos: *const Position, move_list: []u16) usize {
    return generate(.evasions, pos, move_list);
}

/// Generate every legal move: the evasions when in check, otherwise the captures followed by
/// the quiets -- upstream's generate<ALL>. The ORDER is observable: root moves are built from
/// this list, and its order is the tiebreak between equal-scoring moves.
pub fn generateLegal(pos: *const Position, move_list: []u16) usize {
    if (pos.st.checkers_bb != 0) return generateFor(.evasions, pos, move_list);
    const count = generateFor(.captures, pos, move_list);
    return count + generateFor(.quiets, pos, move_list[count..]);
}

fn generate(comptime kind: GenType, pos: *const Position, move_list: []u16) usize {
    return generateFor(kind, pos, move_list);
}

fn generateFor(
    comptime kind: GenType,
    pos: *const Position,
    move_list: []u16,
) usize {
    var writer = MoveWriter{ .moves = move_list };
    switch (pos.side_to_move) {
        white => generateAll(white, kind, pos, &writer),
        black => generateAll(black, kind, pos, &writer),
        else => unreachable,
    }

    return writer.len;
}

fn generateAll(
    comptime us: u8,
    comptime kind: GenType,
    pos: *const Position,
    writer: *MoveWriter,
) void {
    const them = otherColor(us);
    const ksq = kingSquare(pos, us);
    var target: u64 = 0;

    if (kind != .evasions or !moreThanOne(pos.st.checkers_bb)) {
        target = switch (kind) {
            .evasions => bitboard.between(ksq, lsb(pos.st.checkers_bb)),
            .captures => piecesColor(pos, them),
            .quiets => ~pos.by_type_bb[0],
        };

        generatePawnMoves(us, kind, pos, writer, target);
        generateMoves(us, knight, pos, writer, target);
        generateMoves(us, bishop, pos, writer, target);
        generateMoves(us, rook, pos, writer, target);
        generateMoves(us, queen, pos, writer, target);
    }

    if (kind == .evasions) target = ~piecesColor(pos, us);
    target &= ~threatsBy(pos, all_pieces);
    splatMoves(writer, ksq, bitboard.attacks(king, ksq, 0) & target);

    if (kind == .quiets and canCastleAny(pos, us)) {
        inline for (.{ kingSideRight(us), queenSideRight(us) }) |right| {
            const rook_square = castlingRookSquare(pos, right);
            const to = relativeSquare(us, if (rook_square > ksq) 6 else 2); // SQ_G1 : SQ_C1
            // Test the ROOK'S GEOMETRY, whatever UCI_Chess960 says: `set` adopts the first rook
            // it meets for a `K`/`Q` token, so `... w Q ...` over a rook on b1 records a 960
            // geometry under the standard option, and a castle screening an enemy slider on a1
            // behind that rook would leave the king capturable. A corner rook in standard
            // geometry lies on no line from its own king to a slider, so the test always passes
            // there.
            if (!isCastlingImpeded(pos, right) and canCastle(pos, right) and
                (bitboard.between(ksq, to) & threatsBy(pos, all_pieces)) == 0 and
                (pos.st.blockers_for_king[us] & squareBb(rook_square)) == 0)
            {
                writer.push(makeSpecialMove(castling, ksq, rook_square, knight));
            }
        }
    }
}

fn generatePawnMoves(
    comptime us: u8,
    comptime kind: GenType,
    pos: *const Position,
    writer: *MoveWriter,
    target: u64,
) void {
    const them = otherColor(us);
    const empty_squares = ~pos.by_type_bb[0];
    const enemies = if (kind == .evasions) pos.st.checkers_bb else piecesColor(pos, them);
    const t_rank_7 = if (us == white) rank_7_bb else rank_2_bb;
    const t_rank_3 = if (us == white) rank_3_bb else rank_6_bb;
    const up: i8 = if (us == white) north else south;
    const up_right: i8 = if (us == white) north_east else south_west;
    const up_left: i8 = if (us == white) north_west else south_east;

    const pinned = pos.st.blockers_for_king[us];
    const ksq = kingSquare(pos, us);

    const pawns_on_7 = piecesColorType(pos, us, pawn) & t_rank_7;
    const pawns_not_on_7 = piecesColorType(pos, us, pawn) & ~t_rank_7;
    // A pinned pawn moves only along its pin line: it pushes when pinned on the king's file,
    // and captures toward one side when pinned on the diagonal running that way.
    const pushable = ~pinned | (file_a_bb << @intCast(ksq % 8));
    const can_capture_left = ~pinned | bitboard.antiDiag(ksq);
    const can_capture_right = ~pinned | bitboard.diag(ksq);

    if (kind != .captures) {
        var b1 = shift(up, pawns_not_on_7 & pushable) & empty_squares;
        var b2 = shift(up, b1 & t_rank_3) & empty_squares;

        if (kind == .evasions) {
            b1 &= target;
            b2 &= target;
        }

        splatPawnMoves(writer, up, b1);
        splatPawnMoves(writer, up + up, b2);
    }

    if (pawns_on_7 != 0) {
        var b1 = shift(up_right, pawns_on_7 & can_capture_right) & enemies;
        var b2 = shift(up_left, pawns_on_7 & can_capture_left) & enemies;
        var b3 = shift(up, pawns_on_7 & pushable) & empty_squares;

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

    if (kind == .captures or kind == .evasions) {
        const b1 = shift(up_right, pawns_not_on_7 & can_capture_right) & enemies;
        const b2 = shift(up_left, pawns_not_on_7 & can_capture_left) & enemies;

        splatPawnMoves(writer, up_right, b1);
        splatPawnMoves(writer, up_left, b2);

        const ep_square = pos.st.ep_square;
        // An en passant capture cannot resolve a discovered check.
        if (ep_square != sq_none and
            !(kind == .evasions and (target & squareBb(addDirection(ep_square, up))) != 0))
        {
            const ep_bb = squareBb(ep_square);
            var ep_attackers = pawns_not_on_7 &
                ((can_capture_right & shift(-up_right, ep_bb)) | (can_capture_left & shift(-up_left, ep_bb)));
            while (ep_attackers != 0) {
                const from = popLsb(&ep_attackers);
                writer.push(makeSpecialMove(en_passant, from, ep_square, knight));
            }
        }
    }
}

fn generateMoves(
    comptime us: u8,
    comptime piece_type: u8,
    pos: *const Position,
    writer: *MoveWriter,
    target: u64,
) void {
    const pinned = pos.st.blockers_for_king[us];

    // Emit every unpinned piece of the type before any pinned one, as upstream does: the
    // order a list is generated in is the order equal-scoring moves are tried in.
    var pieces = piecesColorType(pos, us, piece_type) & ~pinned;
    while (pieces != 0) {
        const from = popLsb(&pieces);
        const attacks = bitboard.attacks(piece_type, from, pos.by_type_bb[0]) & target;
        splatMoves(writer, from, attacks);
    }

    // A pinned knight cannot move; a pinned slider keeps to the line through its king.
    if (piece_type != knight) {
        const ksq = kingSquare(pos, us);
        pieces = piecesColorType(pos, us, piece_type) & pinned;
        while (pieces != 0) {
            const from = popLsb(&pieces);
            const attacks = bitboard.attacks(piece_type, from, pos.by_type_bb[0]) & target &
                bitboard.line(ksq, from);
            splatMoves(writer, from, attacks);
        }
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
    const all = kind == .evasions;

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
    if (comptime movegen_splat_avx512.use_avx512_movegen) {
        const count = movegen_splat_avx512.splatPawnMoves(offset, writer.moves.ptr + writer.len, to_bb);
        writer.len += count;
        return;
    }
    var targets = to_bb;
    while (targets != 0) {
        const to = popLsb(&targets);
        writer.push(makeMove(subtractDirection(to, offset), to));
    }
}

fn splatMoves(writer: *MoveWriter, from: u8, to_bb: u64) void {
    if (comptime movegen_splat_avx512.use_avx512_movegen) {
        const count = movegen_splat_avx512.splatMoves(from, writer.moves.ptr + writer.len, to_bb);
        writer.len += count;
        return;
    }
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

fn piecesColor(pos: *const Position, color: u8) u64 {
    return pos.by_color_bb[color];
}

fn piecesColorType(pos: *const Position, color: u8, piece_type: u8) u64 {
    return pos.by_color_bb[color] & pos.by_type_bb[piece_type];
}

fn otherColor(color: u8) u8 {
    return color ^ 1;
}

fn canCastle(pos: *const Position, right: u8) bool {
    return (pos.st.castling_rights & right) != 0;
}

fn canCastleAny(pos: *const Position, color: u8) bool {
    const mask = if (color == white) white_castling else black_castling;
    return (pos.st.castling_rights & mask) != 0;
}

fn isCastlingImpeded(pos: *const Position, right: u8) bool {
    return (pos.by_type_bb[0] & pos.castling_path[right]) != 0;
}

fn castlingRookSquare(pos: *const Position, right: u8) u8 {
    return pos.castling_rook_square[right];
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

test {
    @import("std").testing.refAllDecls(@This());
}
