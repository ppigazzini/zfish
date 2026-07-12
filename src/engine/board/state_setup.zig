// Position derived-state setup.
//
// The functions that (re)derive a Position's cached StateInfo from its board:
// setState (full key/material/checkers rebuild), setCheckInfo (blockers + check
// squares), updateSliderBlockers, setCastlingRight, and the material-key helper.
// They mutate the StateInfo the position points at but only *read* the board, and
// every symbol they need now lives in a leaf (board_core primitives, the zobrist
// tables, legality.attackersTo), so this is itself a leaf over board_core +
// bitboard + zobrist + legality + position_types -- no import of position, no
// cycle. position.zig re-exports the four public entry points so make/unmake, FEN
// setup, and null-move keep resolving through the position surface.

const std = @import("std");
const bitboard = @import("bitboard");
const board_core = @import("board_core");
const zobrist = @import("zobrist");
const legality = @import("legality");
const position_types = @import("position_types");

const Position = position_types.Position;
const StateInfo = position_types.StateInfo;

const sq_none_u8: u8 = 64;

const pawn_pt = board_core.pawn_pt;
const knight_pt = board_core.knight_pt;
const bishop_pt = board_core.bishop_pt;
const rook_pt = board_core.rook_pt;
const queen_pt = board_core.queen_pt;
const king_pt = board_core.king_pt;
const color_white = board_core.color_white;
const color_black = board_core.color_black;
const piece_value_by_type = board_core.piece_value_by_type;
const sqBb = board_core.sqBb;
const relativeSquare = board_core.relativeSquare;
const pawnAttacks = board_core.pawnAttacks;
const kingSquare = board_core.kingSquare;
const fileOf = board_core.fileOf;
const attackersTo = legality.attackersTo;

pub fn setCastlingRight(pos_ptr: *Position, c: u8, rfrom: u8) void {
    const pos = pos_ptr;
    const kfrom = kingSquare(pos, c);
    const side_mask: u8 = if (kfrom < rfrom) 5 else 10; // KING_SIDE : QUEEN_SIDE
    const color_castling: u8 = if (c == color_white) 3 else 12; // WHITE_CASTLING : BLACK_CASTLING
    const cr: u8 = color_castling & side_mask;

    pos.st.castling_rights |= @as(c_int, cr);
    pos.castling_rights_mask[kfrom] |= @as(c_int, cr);
    pos.castling_rights_mask[rfrom] |= @as(c_int, cr);
    pos.castling_rook_square[cr] = rfrom;

    const king_side = (cr & 5) != 0;
    const kto = relativeSquare(c, if (king_side) 6 else 2); // SQ_G1 : SQ_C1
    const rto = relativeSquare(c, if (king_side) 5 else 3); // SQ_F1 : SQ_D1
    pos.castling_path[cr] = (bitboard.between(rfrom, rto) | bitboard.between(kfrom, kto)) &
        ~(sqBb(kfrom) | sqBb(rfrom));
}

pub fn updateSliderBlockers(pos_ptr: *const Position, c: u8) void {
    const pos = pos_ptr;
    const ksq = kingSquare(pos, c);
    const nc = c ^ 1;
    pos.st.blockers_for_king[c] = 0;
    pos.st.pinners[nc] = 0;

    const queen_rook = pos.by_type_bb[queen_pt] | pos.by_type_bb[rook_pt];
    const queen_bishop = pos.by_type_bb[queen_pt] | pos.by_type_bb[bishop_pt];
    var snipers = ((bitboard.attacks(rook_pt, ksq, 0) & queen_rook) |
        (bitboard.attacks(bishop_pt, ksq, 0) & queen_bishop)) & pos.by_color_bb[nc];
    const occupancy = pos.by_type_bb[0] ^ snipers;

    while (snipers != 0) {
        const sniper_sq: u8 = @intCast(@ctz(snipers));
        snipers &= snipers - 1;
        const b = bitboard.between(ksq, sniper_sq) & occupancy;
        if (b != 0 and (b & (b -% 1)) == 0) {
            pos.st.blockers_for_king[c] |= b;
            if ((b & pos.by_color_bb[c]) != 0) {
                pos.st.pinners[nc] |= (@as(u64, 1) << @intCast(sniper_sq));
            }
        }
    }
}

pub fn setState(pos_ptr: *const Position) void {
    const psq: [*]const u64 = &zobrist.zob_psq;
    const enpassant: [*]const u64 = &zobrist.zob_enpassant;
    const castling: [*]const u64 = &zobrist.zob_castling;
    const zob_side = zobrist.zob_side_val;
    const no_pawns = zobrist.zob_no_pawns;
    const pos = pos_ptr;
    const st = pos.st;
    st.key = 0;
    st.minor_piece_key = 0;
    st.non_pawn_key[0] = 0;
    st.non_pawn_key[1] = 0;
    st.pawn_key = no_pawns;
    st.non_pawn_material[0] = 0;
    st.non_pawn_material[1] = 0;

    const stm = pos.side_to_move;
    st.checkers_bb = attackersTo(pos_ptr, kingSquare(pos, stm), pos.by_type_bb[0]) &
        pos.by_color_bb[stm ^ 1];
    setCheckInfo(pos_ptr);

    var b = pos.by_type_bb[0];
    while (b != 0) {
        const s: u8 = @intCast(@ctz(b));
        b &= b - 1;
        const pc = pos.board[s];
        const idx = @as(usize, pc) * 64 + s;
        st.key ^= psq[idx];
        const pt = pc & 7;
        if (pt == pawn_pt) {
            st.pawn_key ^= psq[idx];
        } else {
            const col = pc >> 3;
            st.non_pawn_key[col] ^= psq[idx];
            if (pt != king_pt) {
                st.non_pawn_material[col] += piece_value_by_type[pt];
                if (pt <= bishop_pt) st.minor_piece_key ^= psq[idx];
            }
        }
    }

    if (st.ep_square != sq_none_u8) st.key ^= enpassant[fileOf(st.ep_square)];
    if (stm == color_black) st.key ^= zob_side;
    st.key ^= castling[@intCast(st.castling_rights)];
    st.material_key = computeMaterialKey(&pos.piece_count, 16);
}

pub fn setCheckInfo(pos_ptr: *const Position) void {
    const pos = pos_ptr;
    updateSliderBlockers(pos_ptr, color_white);
    updateSliderBlockers(pos_ptr, color_black);

    const them = pos.side_to_move ^ 1;
    const ksq = kingSquare(pos, them);
    const all = pos.by_type_bb[0];
    pos.st.check_squares[pawn_pt] = pawnAttacks(them, ksq);
    pos.st.check_squares[knight_pt] = bitboard.attacks(knight_pt, ksq, 0);
    pos.st.check_squares[bishop_pt] = bitboard.attacks(bishop_pt, ksq, all);
    pos.st.check_squares[rook_pt] = bitboard.attacks(rook_pt, ksq, all);
    pos.st.check_squares[queen_pt] = pos.st.check_squares[bishop_pt] | pos.st.check_squares[rook_pt];
    pos.st.check_squares[king_pt] = 0;
}

pub fn computeMaterialKey(piece_counts_ptr: [*]const c_int, piece_count_len: usize) u64 {
    const piece_counts = piece_counts_ptr[0..piece_count_len];
    var key: u64 = 0;

    for (piece_counts, 0..) |count, piece_index| {
        if (!isMaterialPiece(@intCast(piece_index))) {
            continue;
        }

        var slot: usize = 0;
        while (slot < @as(usize, @intCast(count))) : (slot += 1) {
            key ^= zobrist.zob_psq[@as(usize, @intCast(piece_index)) * 64 + 8 + slot];
        }
    }

    return key;
}

fn isMaterialPiece(piece: u8) bool {
    return switch (piece) {
        1...6, 9...14 => true,
        else => false,
    };
}

comptime {
    // StateInfo is the thing these writers fill; keep the import live so a layout
    // change is seen here too.
    std.debug.assert(@sizeOf(StateInfo) == 192);
}

test {
    @import("std").testing.refAllDecls(@This());
}
