// Query move legality and Static Exchange Evaluation.
//
// Provide the read-only "is this move legal / winning" side of the board, carved out of
// position.zig: attackersTo, legal, seeGe, givesCheck. All take a typed *const Position
// and only read it. This is a leaf over board_core + bitboard + movegen + position_types
// -- it never imports position.zig, so no cycle. position.zig re-exports all four, so the
// search call sites keep resolving through the position surface.

const std = @import("std");
const bitboard = @import("bitboard");
const movegen = @import("movegen");
const board_core = @import("board_core");
const position_types = @import("position_types");

const Position = position_types.Position;
const StateInfo = position_types.StateInfo;

/// Alias the board_core primitives so the moved bodies stay verbatim.
const all_pieces = board_core.all_pieces;
const pawn_pt = board_core.pawn_pt;
const knight_pt = board_core.knight_pt;
const bishop_pt = board_core.bishop_pt;
const rook_pt = board_core.rook_pt;
const queen_pt = board_core.queen_pt;
const king_pt = board_core.king_pt;
const color_white = board_core.color_white;
const color_black = board_core.color_black;
const rank1_bb = board_core.rank1_bb;
const rank8_bb = board_core.rank8_bb;
const mt_normal = board_core.mt_normal;
const mt_promotion = board_core.mt_promotion;
const mt_en_passant = board_core.mt_en_passant;
const mt_castling = board_core.mt_castling;
const piece_value_by_type = board_core.piece_value_by_type;
const sqBb = board_core.sqBb;
const lsbBb = board_core.lsbBb;
const moveFrom = board_core.moveFrom;
const moveTo = board_core.moveTo;
const moveTypeOf = board_core.moveTypeOf;
const movePromotionType = board_core.movePromotionType;
const relativeSquare = board_core.relativeSquare;
const makeSquare = board_core.makeSquare;
const pieceTypeOn = board_core.pieceTypeOn;
const pawnAttacks = board_core.pawnAttacks;
const kingSquare = board_core.kingSquare;
const fileOf = board_core.fileOf;
const rankOf = board_core.rankOf;
const colorOfPiece = board_core.colorOfPiece;
const isEmpty = board_core.isEmpty;

pub fn attackersTo(pos_ptr: *const Position, s: u8, occupied: u64) u64 {
    const pos = pos_ptr;
    const rook_queen = pos.by_type_bb[rook_pt] | pos.by_type_bb[queen_pt];
    const bishop_queen = pos.by_type_bb[bishop_pt] | pos.by_type_bb[queen_pt];
    const white_pawns = pos.by_color_bb[color_white] & pos.by_type_bb[pawn_pt];
    const black_pawns = pos.by_color_bb[color_black] & pos.by_type_bb[pawn_pt];
    // Both ray sets in one pass, as upstream's attackers_to does (position.cpp:645).
    const slider = bitboard.bothAttacks(s, occupied);
    return (slider.rook & rook_queen) |
        (slider.bishop & bishop_queen) |
        (pawnAttacks(color_black, s) & white_pawns) |
        (pawnAttacks(color_white, s) & black_pawns) |
        (bitboard.attacks(knight_pt, s, 0) & pos.by_type_bb[knight_pt]) |
        (bitboard.attacks(king_pt, s, 0) & pos.by_type_bb[king_pt]);
}

/// Test whether an arbitrary move -- a TT move, which SMP races or key aliasing can corrupt,
/// or a ponder candidate -- is legal here. Every move the generators emit already is, so
/// nothing re-tests those (upstream 400c23f97 merged pseudo_legal into this).
pub fn legal(pos: *const Position, m: u16) bool {
    const us = pos.side_to_move;
    const them = us ^ 1;
    const from = moveFrom(m);
    const to = moveTo(m);
    const pc = pos.board[from];
    const all = pos.by_type_bb[0];

    // Use the slower but simpler path for non-NORMAL moves: membership in the generator.
    if (moveTypeOf(m) != mt_normal) {
        var buf: [256]u16 = undefined;
        const n = movegen.generateLegal(pos, &buf);
        for (buf[0..n]) |mv| {
            if (mv == m) return true;
        }
        return false;
    }

    if (pc == 0 or colorOfPiece(pc) != us) return false;
    if ((pos.by_color_bb[us] & sqBb(to)) != 0) return false;

    if ((pc & 7) == pawn_pt) {
        if (((rank8_bb | rank1_bb) & sqBb(to)) != 0) return false;

        const push: i16 = if (us == color_white) 8 else -8;
        const is_capture = (pawnAttacks(us, from) & pos.by_color_bb[them] & sqBb(to)) != 0;
        const is_single_push = (@as(i16, from) + push == @as(i16, to)) and isEmpty(pos, to);
        const rel_rank = rankOf(from) ^ (us * 7);
        const is_double_push = (@as(i16, from) + 2 * push == @as(i16, to)) and rel_rank == 1 and
            isEmpty(pos, to) and isEmpty(pos, @intCast(@as(i16, to) - push));
        if (!(is_capture or is_single_push or is_double_push)) return false;
    } else if ((bitboard.attacks(pc & 7, from, all) & sqBb(to)) == 0) {
        return false;
    }

    // A king may step onto any square the other side does not threaten -- the threats ray
    // through the king itself, so stepping back along a checking line is refused too.
    if ((pc & 7) == king_pt) return (sqBb(to) & pos.st.threats[all_pieces]) == 0;

    const checkers = pos.st.checkers_bb;
    if (checkers != 0) {
        if ((checkers & (checkers -% 1)) != 0) return false; // double check: only the king
        // The move must block the check or capture the checker.
        const checker_sq: u8 = @intCast(@ctz(checkers));
        if ((bitboard.between(kingSquare(pos, us), checker_sq) & sqBb(to)) == 0) return false;
    }
    // A non-king move is legal iff its piece is not pinned or it keeps to the pin line.
    return (pos.st.blockers_for_king[us] & sqBb(from)) == 0 or
        (bitboard.line(from, to) & (pos.by_color_bb[us] & pos.by_type_bb[king_pt])) != 0;
}

pub fn seeGe(pos_ptr: *const Position, m: u16, threshold: i32) bool {
    const pos = pos_ptr;
    if (moveTypeOf(m) != mt_normal) return 0 >= threshold;

    const from = moveFrom(m);
    const to = moveTo(m);

    var swap: i32 = piece_value_by_type[pos.board[to] & 7] - threshold;
    if (swap < 0) return false;
    swap = piece_value_by_type[pos.board[from] & 7] - swap;
    if (swap <= 0) return true;

    var occupied = pos.by_type_bb[0] ^ sqBb(from) ^ sqBb(to);
    var stm = pos.side_to_move;
    var attackers = attackersTo(pos_ptr, to, occupied);
    var res: i32 = 1;

    const bishops_queens = pos.by_type_bb[bishop_pt] | pos.by_type_bb[queen_pt];
    const rooks_queens = pos.by_type_bb[rook_pt] | pos.by_type_bb[queen_pt];

    while (true) {
        stm ^= 1;
        attackers &= occupied;

        var stm_attackers = attackers & pos.by_color_bb[stm];
        if (stm_attackers == 0) break;

        if ((pos.st.pinners[stm ^ 1] & occupied) != 0) {
            stm_attackers &= ~pos.st.blockers_for_king[stm];
            if (stm_attackers == 0) break;
        }

        res ^= 1;
        var bb = stm_attackers & pos.by_type_bb[pawn_pt];
        if (bb != 0) {
            swap = 208 - swap;
            if (swap < res) break;
            occupied ^= lsbBb(bb);
            attackers |= bitboard.attacks(bishop_pt, to, occupied) & bishops_queens;
        } else if (blk: {
            bb = stm_attackers & pos.by_type_bb[knight_pt];
            break :blk bb != 0;
        }) {
            swap = 781 - swap;
            if (swap < res) break;
            occupied ^= lsbBb(bb);
        } else if (blk: {
            bb = stm_attackers & pos.by_type_bb[bishop_pt];
            break :blk bb != 0;
        }) {
            swap = 825 - swap;
            if (swap < res) break;
            occupied ^= lsbBb(bb);
            attackers |= bitboard.attacks(bishop_pt, to, occupied) & bishops_queens;
        } else if (blk: {
            bb = stm_attackers & pos.by_type_bb[rook_pt];
            break :blk bb != 0;
        }) {
            swap = 1276 - swap;
            if (swap < res) break;
            occupied ^= lsbBb(bb);
            attackers |= bitboard.attacks(rook_pt, to, occupied) & rooks_queens;
        } else if (blk: {
            bb = stm_attackers & pos.by_type_bb[queen_pt];
            break :blk bb != 0;
        }) {
            swap = 2538 - swap;
            occupied ^= lsbBb(bb);
            // Both ray sets in one pass, as upstream does here (position.cpp:1505). Only
            // this branch needs both: the pawn/bishop branches above uncover diagonals
            // alone and the rook branch files alone, so they stay single-ray, exactly
            // as upstream leaves them.
            const slider = bitboard.bothAttacks(to, occupied);
            attackers |= (slider.bishop & bishops_queens) | (slider.rook & rooks_queens);
        } else {
            // Reverse the result on a king capture if the opponent still has attackers.
            return if ((attackers & ~pos.by_color_bb[stm]) != 0) (res ^ 1) != 0 else res != 0;
        }
    }

    return res != 0;
}

pub fn givesCheck(pos_ptr: *const Position, m: u16) bool {
    const pos = pos_ptr;
    const stm = pos.side_to_move;
    const them = stm ^ 1;
    const from = moveFrom(m);
    const to = moveTo(m);

    // Detect a direct check. Compute the move type, occupancy and king bitboard in the
    // branches below; this hit and the mt_normal fall-through need none of them.
    if ((pos.st.check_squares[pieceTypeOn(pos, from)] & sqBb(to)) != 0) return true;

    // Detect a discovered check.
    if ((pos.st.blockers_for_king[them] & sqBb(from)) != 0) {
        const their_king_bb = pos.by_color_bb[them] & pos.by_type_bb[king_pt];
        return (bitboard.line(from, to) & their_king_bb) == 0 or moveTypeOf(m) == mt_castling;
    }

    switch (moveTypeOf(m)) {
        mt_normal => return false,
        mt_promotion => return (bitboard.attacks(movePromotionType(m), to, pos.by_type_bb[0] ^ sqBb(from)) &
            (pos.by_color_bb[them] & pos.by_type_bb[king_pt])) != 0,
        mt_en_passant => {
            const capsq = makeSquare(fileOf(to), rankOf(from));
            const b = (pos.by_type_bb[0] ^ sqBb(from) ^ sqBb(capsq)) | sqBb(to);
            const ksq = kingSquare(pos, them);
            const our = pos.by_color_bb[stm];
            const our_qr = our & (pos.by_type_bb[queen_pt] | pos.by_type_bb[rook_pt]);
            const our_qb = our & (pos.by_type_bb[queen_pt] | pos.by_type_bb[bishop_pt]);
            // One pass for both, as upstream's gives_check does (position.cpp:796).
            const slider = bitboard.bothAttacks(ksq, b);
            return ((slider.rook & our_qr) | (slider.bishop & our_qb)) != 0;
        },
        else => { // castling
            const rto = relativeSquare(stm, if (to > from) 5 else 3); // SQ_F1 : SQ_D1
            return (pos.st.check_squares[rook_pt] & sqBb(rto)) != 0;
        },
    }
}

comptime {
    // Keep the import live, since StateInfo is reached through Position.st in these
    // readers, so a layout change to it is seen here too.
    std.debug.assert(@sizeOf(StateInfo) == 232);
}

test {
    @import("std").testing.refAllDecls(@This());
}
