// Make and unmake moves.
//
// Own the mutating side of the board: applying and reverting moves on a live
// Position -- do/undo-null, doMove/undoMove, the board+DirtyThreats mutators, and
// putPiece. Every dependency is a leaf (board_core primitives, the zobrist keys,
// state_setup.setCheckInfo, legality.attackersTo), so move_do imports no
// position.zig -- no cycle. position.zig re-exports the public entry points
// (doMove/undoMove/doNullMove/undoNullMove/putPiece) so the search + FEN-setup
// callers resolve through the position surface.

const std = @import("std");
const bitboard = @import("bitboard");
const board_core = @import("board_core");
const zobrist = @import("zobrist");
const state_setup = @import("state_setup");
const legality = @import("legality");
const move_do_threats = @import("move_do_threats.zig");
const position_types = @import("position_types");

const Position = position_types.Position;
const StateInfo = position_types.StateInfo;
const DirtyPiece = position_types.DirtyPiece;
const DirtyThreats = position_types.DirtyThreats;

const sq_none_u8 = board_core.sq_none;
const max_u64: u64 = 0xFFFFFFFFFFFFFFFF;

const pawn_pt = board_core.pawn_pt;
const knight_pt = board_core.knight_pt;
const bishop_pt = board_core.bishop_pt;
const rook_pt = board_core.rook_pt;
const queen_pt = board_core.queen_pt;
const king_pt = board_core.king_pt;
const color_white = board_core.color_white;
const color_black = board_core.color_black;
const mt_promotion = board_core.mt_promotion;
const mt_en_passant = board_core.mt_en_passant;
const mt_castling = board_core.mt_castling;
const piece_value_by_type = board_core.piece_value_by_type;
const sqBb = board_core.sqBb;
const moveFrom = board_core.moveFrom;
const moveTo = board_core.moveTo;
const moveTypeOf = board_core.moveTypeOf;
const movePromotionType = board_core.movePromotionType;
const relativeSquare = board_core.relativeSquare;
const pawnAttacks = board_core.pawnAttacks;
const kingSquare = board_core.kingSquare;
const fileOf = board_core.fileOf;
const psqIdx = zobrist.psqIdx;
const setCheckInfo = state_setup.setCheckInfo;
const attackersTo = legality.attackersTo;

inline fn pawnPush(c: u8) i16 {
    return if (c == color_white) 8 else -8;
}

pub fn doNullMove(pos_ptr: *Position, new_st_ptr: *StateInfo) void {
    const pos = pos_ptr;
    const new_st = new_st_ptr;

    new_st.* = pos.st.*; // memcpy(&newSt, st, sizeof(StateInfo))
    new_st.previous = pos.st;
    pos.st = new_st;

    if (pos.st.ep_square != sq_none_u8) {
        pos.st.key ^= zobrist.zob_enpassant[fileOf(pos.st.ep_square)];
        pos.st.ep_square = sq_none_u8;
    }
    pos.st.key ^= zobrist.zob_side_val;
    pos.st.plies_from_null = 0;

    // Clear the captured piece (upstream 782852b26): the StateInfo was copied from the previous ply
    // (incl. its capturedPiece), and a null move captures nothing, so otherwise prior_capture detection reads a stale value.
    pos.st.captured_piece = 0; // NO_PIECE

    pos.side_to_move ^= 1;
    setCheckInfo(pos_ptr);
    pos.st.repetition = 0;
}

pub fn undoNullMove(pos_ptr: *Position) void {
    const pos = pos_ptr;
    pos.st = pos.st.previous.?;
    pos.side_to_move ^= 1;
}

fn removePieceDts(pos: *Position, s: u8, dts: *DirtyThreats) void {
    const pc = pos.board[s];
    move_do_threats.updatePieceThreats(true, pos, pc, false, s, dts, max_u64);
    const bb = sqBb(s);
    pos.by_type_bb[0] ^= bb;
    pos.by_type_bb[pc & 7] ^= bb;
    pos.by_color_bb[pc >> 3] ^= bb;
    pos.board[s] = 0;
    pos.piece_count[pc] -= 1;
    pos.piece_count[(pc >> 3) << 3] -= 1;
}

fn putPieceDts(pos: *Position, pc: u8, s: u8, dts: *DirtyThreats) void {
    const bb = sqBb(s);
    pos.board[s] = pc;
    pos.by_type_bb[pc & 7] |= bb;
    pos.by_type_bb[0] |= pos.by_type_bb[pc & 7];
    pos.by_color_bb[pc >> 3] |= bb;
    pos.piece_count[pc] += 1;
    pos.piece_count[(pc >> 3) << 3] += 1;
    move_do_threats.updatePieceThreats(true, pos, pc, true, s, dts, max_u64);
}

fn movePieceDts(pos: *Position, from: u8, to: u8, dts: *DirtyThreats) void {
    const pc = pos.board[from];
    const from_to = sqBb(from) | sqBb(to);
    move_do_threats.updatePieceThreats(true, pos, pc, false, from, dts, from_to);
    pos.by_type_bb[0] ^= from_to;
    pos.by_type_bb[pc & 7] ^= from_to;
    pos.by_color_bb[pc >> 3] ^= from_to;
    pos.board[from] = 0;
    pos.board[to] = pc;
    move_do_threats.updatePieceThreats(true, pos, pc, true, to, dts, from_to);
}

fn swapPieceDts(pos: *Position, s: u8, pc: u8, dts: *DirtyThreats) void {
    const old = pos.board[s];
    removePiece(pos, s); // dts=nullptr in swap_piece
    move_do_threats.updatePieceThreats(false, pos, old, false, s, dts, max_u64);
    putPiece(pos, pc, s);
    move_do_threats.updatePieceThreats(false, pos, pc, true, s, dts, max_u64);
}

fn removePiece(pos: *Position, s: u8) void {
    const pc = pos.board[s];
    const bb = sqBb(s);
    pos.by_type_bb[0] ^= bb;
    pos.by_type_bb[pc & 7] ^= bb;
    pos.by_color_bb[pc >> 3] ^= bb;
    pos.board[s] = 0;
    pos.piece_count[pc] -= 1;
    pos.piece_count[(pc >> 3) << 3] -= 1;
}

fn movePieceQuiet(pos: *Position, from: u8, to: u8) void {
    const pc = pos.board[from];
    const from_to = sqBb(from) | sqBb(to);
    pos.by_type_bb[0] ^= from_to;
    pos.by_type_bb[pc & 7] ^= from_to;
    pos.by_color_bb[pc >> 3] ^= from_to;
    pos.board[from] = 0;
    pos.board[to] = pc;
}

fn swapPiece(pos: *Position, s: u8, pc: u8) void {
    removePiece(pos, s);
    putPiece(pos, pc, s);
}

const CastleSquares = struct { to: u8, rfrom: u8, rto: u8 };

fn doCastlingDo(pos: *Position, us: u8, from: u8, to_in: u8, dp: *DirtyPiece, dts: *DirtyThreats) CastleSquares {
    const king_side = to_in > from;
    const rfrom = to_in; // king-captures-rook encoding
    const rto = relativeSquare(us, if (king_side) 5 else 3); // SQ_F1 : SQ_D1
    const to = relativeSquare(us, if (king_side) 6 else 2); // SQ_G1 : SQ_C1
    dp.to = to;
    dp.remove_pc = (us << 3) | rook_pt;
    dp.add_pc = (us << 3) | rook_pt;
    dp.remove_sq = rfrom;
    dp.add_sq = rto;
    removePieceDts(pos, from, dts);
    removePieceDts(pos, rfrom, dts);
    putPieceDts(pos, (us << 3) | king_pt, to, dts);
    putPieceDts(pos, (us << 3) | rook_pt, rto, dts);
    return .{ .to = to, .rfrom = rfrom, .rto = rto };
}

pub fn doMove(
    pos_ptr: *Position,
    m: u16,
    new_st_ptr: *StateInfo,
    gives_check: u8,
    dp_ptr: *DirtyPiece,
    dts_ptr: *DirtyThreats,
) void {
    const psq: [*]const u64 = &zobrist.zob_psq;
    const enpassant: [*]const u64 = &zobrist.zob_enpassant;
    const castling: [*]const u64 = &zobrist.zob_castling;
    const zob_side = zobrist.zob_side_val;
    const pos = pos_ptr;
    const new_st = new_st_ptr;
    const dp = dp_ptr;
    const dts = dts_ptr;

    var k = pos.st.key ^ zob_side;

    // Carry the StateInfo fields that are copied when making a move (up to key); copy
    // them by field rather than assuming a byte-contiguous prefix.
    new_st.material_key = pos.st.material_key;
    new_st.pawn_key = pos.st.pawn_key;
    new_st.minor_piece_key = pos.st.minor_piece_key;
    new_st.non_pawn_key = pos.st.non_pawn_key;
    new_st.non_pawn_material = pos.st.non_pawn_material;
    new_st.castling_rights = pos.st.castling_rights;
    new_st.rule50 = pos.st.rule50;
    new_st.plies_from_null = pos.st.plies_from_null;
    new_st.ep_square = pos.st.ep_square;
    new_st.previous = pos.st;
    pos.st = new_st;

    pos.game_ply += 1;
    pos.st.rule50 += 1;
    pos.st.plies_from_null += 1;

    const us = pos.side_to_move;
    const them = us ^ 1;
    const from = moveFrom(m);
    var to = moveTo(m);
    const mt = moveTypeOf(m);
    const pc = pos.board[from];
    var captured: u8 = if (mt == mt_en_passant) (them << 3) | pawn_pt else pos.board[to];

    dp.pc = pc;
    dp.from = from;
    dp.to = to;
    dp.add_sq = sq_none_u8;
    dts.us = us;
    dts.prev_ksq = kingSquare(pos, us);

    if (mt == mt_castling) {
        const r = doCastlingDo(pos, us, from, to, dp, dts);
        to = r.to; // do_castling takes `to` by reference and sets it to the king's destination
        k ^= psq[psqIdx(captured, r.rfrom)] ^ psq[psqIdx(captured, r.rto)];
        pos.st.non_pawn_key[us] ^= psq[psqIdx(captured, r.rfrom)] ^ psq[psqIdx(captured, r.rto)];
        captured = 0;
    } else if (captured != 0) {
        var capsq = to;
        if ((captured & 7) == pawn_pt) {
            if (mt == mt_en_passant) {
                capsq = @intCast(@as(i16, to) - pawnPush(us));
                removePieceDts(pos, capsq, dts);
            }
            pos.st.pawn_key ^= psq[psqIdx(captured, capsq)];
        } else {
            pos.st.non_pawn_material[them] -= piece_value_by_type[captured & 7];
            pos.st.non_pawn_key[them] ^= psq[psqIdx(captured, capsq)];
            if ((captured & 7) <= bishop_pt) pos.st.minor_piece_key ^= psq[psqIdx(captured, capsq)];
        }
        dp.remove_pc = captured;
        dp.remove_sq = capsq;
        k ^= psq[psqIdx(captured, capsq)];
        const mat_slot: u8 = @intCast(8 + pos.piece_count[captured] - @as(i32, if (mt != mt_en_passant) 1 else 0));
        pos.st.material_key ^= psq[psqIdx(captured, mat_slot)];
        pos.st.rule50 = 0;
    } else {
        dp.remove_sq = sq_none_u8;
    }

    k ^= psq[psqIdx(pc, from)] ^ psq[psqIdx(pc, to)];

    if (pos.st.ep_square != sq_none_u8) {
        k ^= enpassant[fileOf(pos.st.ep_square)];
        pos.st.ep_square = sq_none_u8;
    }

    k ^= castling[@intCast(pos.st.castling_rights)];
    pos.st.castling_rights &= ~(pos.castling_rights_mask[from] | pos.castling_rights_mask[to]);
    k ^= castling[@intCast(pos.st.castling_rights)];

    if (mt != mt_castling) {
        var to_pc = pc;
        if (mt == mt_promotion) to_pc = (us << 3) | movePromotionType(m);
        if (captured != 0 and mt != mt_en_passant) {
            removePieceDts(pos, from, dts);
            swapPieceDts(pos, to, to_pc, dts);
        } else if (pc == to_pc) {
            movePieceDts(pos, from, to, dts);
        } else {
            removePieceDts(pos, from, dts);
            putPieceDts(pos, to_pc, to, dts);
        }
    }

    if ((pc & 7) == pawn_pt) {
        if ((@as(i32, to) ^ @as(i32, from)) == 16) {
            const ep_sq: u8 = @intCast(@as(i16, to) - pawnPush(us));
            const their_pawns = pos.by_color_bb[them] & pos.by_type_bb[pawn_pt];
            const pawns = pawnAttacks(us, ep_sq) & their_pawns;
            if (pawns != 0) {
                const ksq = kingSquare(pos, them);
                const not_blockers = ~pos.st.previous.?.blockers_for_king[them];
                const no_discovery = (sqBb(from) & not_blockers) != 0 or fileOf(from) == fileOf(ksq);
                if (no_discovery and (pawns & (not_blockers | bitboard.line(ep_sq, ksq))) != 0) {
                    pos.st.ep_square = ep_sq;
                    k ^= enpassant[fileOf(ep_sq)];
                }
            }
        } else if (mt == mt_promotion) {
            const pt = movePromotionType(m);
            const promotion = (us << 3) | pt;
            dp.add_pc = promotion;
            dp.add_sq = to;
            dp.to = sq_none_u8;
            k ^= psq[psqIdx(promotion, to)];
            const prom_slot: u8 = @intCast(8 + pos.piece_count[promotion] - 1);
            const pawn_slot: u8 = @intCast(8 + pos.piece_count[pc]);
            pos.st.material_key ^= psq[psqIdx(promotion, prom_slot)] ^ psq[psqIdx(pc, pawn_slot)];
            pos.st.non_pawn_key[us] ^= psq[psqIdx(promotion, to)];
            if (pt <= bishop_pt) pos.st.minor_piece_key ^= psq[psqIdx(promotion, to)];
            pos.st.non_pawn_material[us] += piece_value_by_type[pt];
        }
        pos.st.pawn_key ^= psq[psqIdx(pc, from)] ^ psq[psqIdx(pc, to)];
        pos.st.rule50 = 0;
    } else {
        pos.st.non_pawn_key[us] ^= psq[psqIdx(pc, from)] ^ psq[psqIdx(pc, to)];
        if ((pc & 7) <= bishop_pt) pos.st.minor_piece_key ^= psq[psqIdx(pc, from)] ^ psq[psqIdx(pc, to)];
    }

    pos.st.key = k;
    pos.st.captured_piece = captured;
    pos.st.checkers_bb = if (gives_check != 0)
        attackersTo(pos_ptr, kingSquare(pos, them), pos.by_type_bb[0]) & pos.by_color_bb[us]
    else
        0;
    pos.side_to_move ^= 1;
    setCheckInfo(pos_ptr);

    pos.st.repetition = 0;
    const end = @min(pos.st.rule50, pos.st.plies_from_null);
    if (end >= 4) {
        var stp = pos.st.previous.?.previous.?;
        var i: i32 = 4;
        while (i <= end) : (i += 2) {
            stp = stp.previous.?.previous.?;
            if (stp.key == pos.st.key) {
                pos.st.repetition = if (stp.repetition != 0) -i else i;
                break;
            }
        }
    }

    dts.ksq = kingSquare(pos, us);
}

pub fn undoMove(pos_ptr: *Position, m: u16) void {
    const pos = pos_ptr;
    pos.side_to_move ^= 1;
    const us = pos.side_to_move;
    const from = moveFrom(m);
    const to = moveTo(m);
    const mt = moveTypeOf(m);

    if (mt == mt_promotion) {
        swapPiece(pos, to, (us << 3) | pawn_pt);
    }

    if (mt == mt_castling) {
        const king_side = to > from;
        const rfrom = to; // encoded as king-captures-rook
        const rto = relativeSquare(us, if (king_side) 5 else 3); // SQ_F1 : SQ_D1
        const king_dest = relativeSquare(us, if (king_side) 6 else 2); // SQ_G1 : SQ_C1
        removePiece(pos, king_dest);
        removePiece(pos, rto);
        putPiece(pos, (us << 3) | king_pt, from);
        putPiece(pos, (us << 3) | rook_pt, rfrom);
    } else {
        movePieceQuiet(pos, to, from);
        if (pos.st.captured_piece != 0) {
            var capsq = to;
            if (mt == mt_en_passant) capsq = @intCast(@as(i16, to) - pawnPush(us));
            putPiece(pos, pos.st.captured_piece, capsq);
        }
    }

    pos.st = pos.st.previous.?;
    pos.game_ply -= 1;
}

pub fn putPiece(pos: *Position, pc: u8, s: u8) void {
    const bb = sqBb(s);
    pos.board[s] = pc;
    pos.by_type_bb[pc & 7] |= bb;
    pos.by_type_bb[0] |= pos.by_type_bb[pc & 7];
    pos.by_color_bb[pc >> 3] |= bb;
    pos.piece_count[pc] += 1;
    pos.piece_count[(pc >> 3) << 3] += 1; // make_piece(color, ALL_PIECES)
}

test {
    @import("std").testing.refAllDecls(@This());
}
