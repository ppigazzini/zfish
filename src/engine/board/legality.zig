// Query move legality and Static Exchange Evaluation.
//
// Provide the read-only "is this move legal / winning" side of the board, carved out of
// position.zig: attackersTo, legal, seeGe, pseudoLegal, givesCheck,
// attackersToExist. All take a typed *const Position and only read it -- including
// legal, now that the move_is_legal_fn snapshot hook is itself typed. This
// is a leaf over board_core + bitboard + movegen + position_types -- it never imports
// position.zig, so no cycle.
// position.zig re-exports all six, so the search/movegen call sites and the
// move_is_legal_fn hook keep resolving through the position surface.

const std = @import("std");
const bitboard = @import("bitboard");
const movegen = @import("movegen");
const board_core = @import("board_core");
const position_types = @import("position_types");

const Position = position_types.Position;
const StateInfo = position_types.StateInfo;

// Alias the board_core primitives so the moved bodies stay verbatim.
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
    return (bitboard.attacks(rook_pt, s, occupied) & rook_queen) |
        (bitboard.attacks(bishop_pt, s, occupied) & bishop_queen) |
        (pawnAttacks(color_black, s) & white_pawns) |
        (pawnAttacks(color_white, s) & black_pawns) |
        (bitboard.attacks(knight_pt, s, 0) & pos.by_type_bb[knight_pt]) |
        (bitboard.attacks(king_pt, s, 0) & pos.by_type_bb[king_pt]);
}

pub fn legal(pos: *const Position, m: u16) bool {
    const us = pos.side_to_move;
    const from = moveFrom(m);
    const orig_to = moveTo(m);

    // Compute the occupancy and opponent operands inside the branches that need them,
    // as upstream does: the dominant not-pinned exit below reads neither, and LLVM
    // measurably does not sink the hoisted loads past the early returns.
    if (moveTypeOf(m) == mt_castling) {
        const them = us ^ 1;
        const all = pos.by_type_bb[0];
        const king_dest_rel: u8 = if (orig_to > from) 6 else 2; // SQ_G1 : SQ_C1
        const to = relativeSquare(us, king_dest_rel);
        const step: i8 = if (to > from) -1 else 1; // WEST : EAST
        var s: u8 = to;
        while (s != from) : (s = @intCast(@as(i16, s) + step)) {
            if (attackersToExist(pos, s, all, them)) return false;
        }
        if (!pos.chess960) return true;
        return (pos.st.blockers_for_king[us] & sqBb(orig_to)) == 0;
    }

    if (pieceTypeOn(pos, from) == king_pt) {
        return !attackersToExist(pos, orig_to, pos.by_type_bb[0] ^ sqBb(from), us ^ 1);
    }

    return (pos.st.blockers_for_king[us] & sqBb(from)) == 0 or
        (bitboard.line(from, orig_to) & (pos.by_color_bb[us] & pos.by_type_bb[king_pt])) != 0;
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
            attackers |= (bitboard.attacks(bishop_pt, to, occupied) & bishops_queens) |
                (bitboard.attacks(rook_pt, to, occupied) & rooks_queens);
        } else {
            // Reverse the result on a king capture if the opponent still has attackers.
            return if ((attackers & ~pos.by_color_bb[stm]) != 0) (res ^ 1) != 0 else res != 0;
        }
    }

    return res != 0;
}

pub fn pseudoLegal(pos_ptr: *const Position, m: u16) bool {
    const pos = pos_ptr;
    const us = pos.side_to_move;
    const them = us ^ 1;
    const from = moveFrom(m);
    const to = moveTo(m);
    const pc = pos.board[from];
    const all = pos.by_type_bb[0];

    // Use the slower but simpler path for non-NORMAL moves: membership in the generator.
    if (moveTypeOf(m) != mt_normal) {
        var buf: [256]u16 = undefined;
        const n = if (pos.st.checkers_bb != 0)
            movegen.generateEvasions(pos_ptr, &buf)
        else
            movegen.generateNonEvasions(pos_ptr, &buf);
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

    // upstream position.cpp:748 -- `if (checkers() && type_of(pc) != KING)`: for a KING move
    // while in check, pseudo_legal does nothing (the destination-safety is left to legal()),
    // so do NOT reject a king landing on an attacked square here.
    const checkers = pos.st.checkers_bb;
    if (checkers != 0 and (pc & 7) != king_pt) {
        if ((checkers & (checkers -% 1)) != 0) return false; // double check
        const ksq = kingSquare(pos, us);
        const checker_sq: u8 = @intCast(@ctz(checkers));
        if ((bitboard.between(ksq, checker_sq) & sqBb(to)) == 0) return false;
    }

    return true;
}

pub fn givesCheck(pos_ptr: *const Position, m: u16) bool {
    const pos = pos_ptr;
    const stm = pos.side_to_move;
    const them = stm ^ 1;
    const from = moveFrom(m);
    const to = moveTo(m);

    // Detect a direct check. Compute the move type, occupancy and king bitboard lazily
    // in the branches below, as upstream does: this hit and the mt_normal fall-through
    // dominate, need none of them, and LLVM measurably does not sink the hoisted loads.
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
            return ((bitboard.attacks(rook_pt, ksq, b) & our_qr) |
                (bitboard.attacks(bishop_pt, ksq, b) & our_qb)) != 0;
        },
        else => { // castling
            const rto = relativeSquare(stm, if (to > from) 5 else 3); // SQ_F1 : SQ_D1
            return (pos.st.check_squares[rook_pt] & sqBb(rto)) != 0;
        },
    }
}

pub fn attackersToExist(pos_ptr: *const Position, s: u8, occupied: u64, c: u8) bool {
    const pos = pos_ptr;
    const them = pos.by_color_bb[c];
    const rook_queen = them & (pos.by_type_bb[rook_pt] | pos.by_type_bb[queen_pt]);
    const bishop_queen = them & (pos.by_type_bb[bishop_pt] | pos.by_type_bb[queen_pt]);
    if ((bitboard.attacks(rook_pt, s, occupied) & rook_queen) != 0) return true;
    if ((bitboard.attacks(bishop_pt, s, occupied) & bishop_queen) != 0) return true;
    if ((pawnAttacks(c ^ 1, s) & (them & pos.by_type_bb[pawn_pt])) != 0) return true;
    if ((bitboard.attacks(knight_pt, s, 0) & (them & pos.by_type_bb[knight_pt])) != 0) return true;
    if ((bitboard.attacks(king_pt, s, 0) & (them & pos.by_type_bb[king_pt])) != 0) return true;
    return false;
}

comptime {
    // Keep the import live, since StateInfo is reached through Position.st in these
    // readers, so a layout change to it is seen here too.
    std.debug.assert(@sizeOf(StateInfo) == 192);
}

test {
    @import("std").testing.refAllDecls(@This());
}
