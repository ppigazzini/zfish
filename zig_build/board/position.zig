const std = @import("std");
const bitboard = @import("bitboard");
const movegen = @import("movegen");

const pawn_pt: u8 = 1;
const knight_pt: u8 = 2;
const bishop_pt: u8 = 3;
const rook_pt: u8 = 4;
const queen_pt: u8 = 5;
const king_pt: u8 = 6;
const color_white: u8 = 0;
const color_black: u8 = 1;

const file_a_bb: u64 = 0x0101010101010101;
const file_h_bb: u64 = 0x8080808080808080;

// MoveType (top 2 bits of the 16-bit move).
const mt_normal: u16 = 0;
const mt_promotion: u16 = 1 << 14;
const mt_en_passant: u16 = 2 << 14;
const mt_castling: u16 = 3 << 14;

inline fn sqBb(s: u8) u64 {
    return @as(u64, 1) << @intCast(s);
}
inline fn moveFrom(m: u16) u8 {
    return @intCast((m >> 6) & 0x3F);
}
inline fn moveTo(m: u16) u8 {
    return @intCast(m & 0x3F);
}
inline fn moveTypeOf(m: u16) u16 {
    return m & (3 << 14);
}
inline fn movePromotionType(m: u16) u8 {
    return @intCast(((m >> 12) & 3) + 2); // + KNIGHT
}
inline fn relativeSquare(c: u8, s: u8) u8 {
    return s ^ (c * 56);
}
inline fn makeSquare(f: u8, r: u8) u8 {
    return (r << 3) + f;
}
inline fn pieceTypeOn(pos: *const Position, s: u8) u8 {
    return pos.board[s] & 7;
}
inline fn colorOfPiece(pc: u8) u8 {
    return pc >> 3;
}
inline fn isEmpty(pos: *const Position, s: u8) bool {
    return pos.board[s] == 0;
}

const rank1_bb: u64 = 0xFF;
const rank8_bb: u64 = 0xFF << 56;

// attacks_bb<PAWN>(s, c): squares a color-c pawn on `s` attacks.
fn pawnAttacks(color: u8, sq: u8) u64 {
    const b: u64 = @as(u64, 1) << @intCast(sq);
    if (color == color_white) {
        return ((b & ~file_h_bb) << 9) | ((b & ~file_a_bb) << 7);
    }
    return ((b & ~file_h_bb) >> 7) | ((b & ~file_a_bb) >> 9);
}

const white_oo: u8 = 1;
const white_ooo: u8 = 2;
const black_oo: u8 = 4;
const black_ooo: u8 = 8;
const black: u8 = 1;
const sq_none: u8 = 64;

const piece_to_char = " PNBRQK  pnbrqk";

extern fn zfish_position_material_zobrist(piece: u8, count_index: usize) u64;

// Memory mirror of upstream Stockfish StateInfo (src/position.h). Field order,
// types, and C-ABI alignment match the C++ struct exactly so Zig can read the
// live state stack that the C++ Position owns. Only used via pointer (never
// allocated here), so it must stay byte-compatible with the C++ layout.
pub const StateInfo = extern struct {
    material_key: u64,
    pawn_key: u64,
    minor_piece_key: u64,
    non_pawn_key: [2]u64,
    non_pawn_material: [2]c_int,
    castling_rights: c_int,
    rule50: c_int,
    plies_from_null: c_int,
    ep_square: u8,
    key: u64,
    checkers_bb: u64,
    previous: ?*StateInfo,
    blockers_for_king: [2]u64,
    pinners: [2]u64,
    check_squares: [8]u64,
    captured_piece: u8,
    repetition: c_int,
};

// Memory mirror of the leading data members of upstream Position (src/position.h),
// up to `chess960`. The trailing NNUE scratch members (DirtyPiece/DirtyThreats)
// are intentionally omitted: this struct is only ever used through a pointer to
// the live C++ object, so leading-field offsets are all that must match.
pub const Position = extern struct {
    board: [64]u8,
    by_type_bb: [8]u64,
    by_color_bb: [2]u64,
    piece_count: [16]c_int,
    castling_rights_mask: [64]c_int,
    castling_rook_square: [16]u8,
    castling_path: [16]u64,
    st: *StateInfo,
    game_ply: c_int,
    side_to_move: u8,
    chess960: bool,
};

pub fn isDraw(pos_ptr: *const anyopaque, ply: c_int) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    if (pos.st.rule50 > 99) {
        if (pos.st.checkers_bb == 0) return true;
        var buf: [256]u16 = undefined;
        if (movegen.generateLegal(pos_ptr, &buf) != 0) return true;
    }
    return isRepetition(pos_ptr, ply);
}

pub fn isRepetition(pos_ptr: *const anyopaque, ply: c_int) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const rep = pos.st.repetition;
    return rep != 0 and rep < ply;
}

pub fn hasRepeated(pos_ptr: *const anyopaque) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    var stc: *const StateInfo = pos.st;
    var end = @min(pos.st.rule50, pos.st.plies_from_null);
    while (end >= 4) : (end -= 1) {
        if (stc.repetition != 0) return true;
        stc = stc.previous.?;
    }
    return false;
}

pub fn attackersTo(pos_ptr: *const anyopaque, s: u8, occupied: u64) u64 {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
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

fn kingSquare(pos: *const Position, c: u8) u8 {
    return @intCast(@ctz(pos.by_color_bb[c] & pos.by_type_bb[king_pt]));
}

pub fn updateSliderBlockers(pos_ptr: *const anyopaque, c: u8) void {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
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

pub fn setCheckInfo(pos_ptr: *const anyopaque) void {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
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

pub fn legal(pos_ptr: *const anyopaque, m: u16) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const us = pos.side_to_move;
    const them = us ^ 1;
    const from = moveFrom(m);
    const orig_to = moveTo(m);
    const all = pos.by_type_bb[0];

    if (moveTypeOf(m) == mt_castling) {
        const king_dest_rel: u8 = if (orig_to > from) 6 else 2; // SQ_G1 : SQ_C1
        const to = relativeSquare(us, king_dest_rel);
        const step: i8 = if (to > from) -1 else 1; // WEST : EAST
        var s: u8 = to;
        while (s != from) : (s = @intCast(@as(i16, s) + step)) {
            if (attackersToExist(pos_ptr, s, all, them)) return false;
        }
        if (!pos.chess960) return true;
        return (pos.st.blockers_for_king[us] & sqBb(orig_to)) == 0;
    }

    if (pieceTypeOn(pos, from) == king_pt) {
        return !attackersToExist(pos_ptr, orig_to, all ^ sqBb(from), them);
    }

    return (pos.st.blockers_for_king[us] & sqBb(from)) == 0 or
        (bitboard.line(from, orig_to) & (pos.by_color_bb[us] & pos.by_type_bb[king_pt])) != 0;
}

const piece_value_by_type = [8]c_int{ 0, 208, 781, 825, 1276, 2538, 0, 0 };

inline fn lsbBb(bb: u64) u64 {
    return bb & (~bb +% 1);
}

pub fn seeGe(pos_ptr: *const anyopaque, m: u16, threshold: c_int) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    if (moveTypeOf(m) != mt_normal) return 0 >= threshold;

    const from = moveFrom(m);
    const to = moveTo(m);

    var swap: c_int = piece_value_by_type[pos.board[to] & 7] - threshold;
    if (swap < 0) return false;
    swap = piece_value_by_type[pos.board[from] & 7] - swap;
    if (swap <= 0) return true;

    var occupied = pos.by_type_bb[0] ^ sqBb(from) ^ sqBb(to);
    var stm = pos.side_to_move;
    var attackers = attackersTo(pos_ptr, to, occupied);
    var res: c_int = 1;

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
            // King capture: if the opponent still has attackers, reverse the result.
            return if ((attackers & ~pos.by_color_bb[stm]) != 0) (res ^ 1) != 0 else res != 0;
        }
    }

    return res != 0;
}

pub fn pseudoLegal(pos_ptr: *const anyopaque, m: u16) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const us = pos.side_to_move;
    const them = us ^ 1;
    const from = moveFrom(m);
    const to = moveTo(m);
    const pc = pos.board[from];
    const all = pos.by_type_bb[0];

    // Slower but simpler path for non-NORMAL moves: membership in the generator.
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

    const checkers = pos.st.checkers_bb;
    if (checkers != 0) {
        if ((pc & 7) != king_pt) {
            if ((checkers & (checkers -% 1)) != 0) return false; // double check
            const ksq = kingSquare(pos, us);
            const checker_sq: u8 = @intCast(@ctz(checkers));
            if ((bitboard.between(ksq, checker_sq) & sqBb(to)) == 0) return false;
        } else if (attackersToExist(pos_ptr, to, all ^ sqBb(from), them)) {
            return false;
        }
    }

    return true;
}

pub fn givesCheck(pos_ptr: *const anyopaque, m: u16) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const stm = pos.side_to_move;
    const them = stm ^ 1;
    const from = moveFrom(m);
    const to = moveTo(m);
    const mt = moveTypeOf(m);
    const all = pos.by_type_bb[0];
    const their_king_bb = pos.by_color_bb[them] & pos.by_type_bb[king_pt];

    // Direct check.
    if ((pos.st.check_squares[pieceTypeOn(pos, from)] & sqBb(to)) != 0) return true;

    // Discovered check.
    if ((pos.st.blockers_for_king[them] & sqBb(from)) != 0) {
        return (bitboard.line(from, to) & their_king_bb) == 0 or mt == mt_castling;
    }

    switch (mt) {
        mt_normal => return false,
        mt_promotion => return (bitboard.attacks(movePromotionType(m), to, all ^ sqBb(from)) &
            their_king_bb) != 0,
        mt_en_passant => {
            const capsq = makeSquare(fileOf(to), rankOf(from));
            const b = (all ^ sqBb(from) ^ sqBb(capsq)) | sqBb(to);
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

pub fn attackersToExist(pos_ptr: *const anyopaque, s: u8, occupied: u64, c: u8) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
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

pub fn buildEndgameFen(code_ptr: [*]const u8, code_len: usize, color: u8) ?[*:0]u8 {
    return buildEndgameFenAlloc(code_ptr[0..code_len], color) catch null;
}

pub fn formatFen(
    board_ptr: [*]const u8,
    side_to_move: u8,
    chess960: u8,
    castling_rights: u8,
    white_oo_rook_square: u8,
    white_ooo_rook_square: u8,
    black_oo_rook_square: u8,
    black_ooo_rook_square: u8,
    ep_square: u8,
    rule50: c_int,
    game_ply: c_int,
) ?[*:0]u8 {
    return formatFenAlloc(
        board_ptr[0..64],
        side_to_move,
        chess960 != 0,
        castling_rights,
        white_oo_rook_square,
        white_ooo_rook_square,
        black_oo_rook_square,
        black_ooo_rook_square,
        ep_square,
        rule50,
        game_ply,
    ) catch null;
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
            key ^= zfish_position_material_zobrist(@intCast(piece_index), slot);
        }
    }

    return key;
}

fn buildEndgameFenAlloc(code: []const u8, color: u8) ![*:0]u8 {
    std.debug.assert(code.len > 0 and code[0] == 'K');

    const second_king = std.mem.indexOfScalarPos(u8, code, 1, 'K') orelse unreachable;
    const versus = std.mem.indexOfScalar(u8, code, 'v') orelse unreachable;
    const strong_end = @min(second_king, versus);

    const weak_side = code[second_king..];
    const strong_side = code[0..strong_end];

    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(std.heap.c_allocator);

    try builder.appendSlice(std.heap.c_allocator, "8/");
    try appendSide(&builder, weak_side, color == 0);
    try builder.append(std.heap.c_allocator, digitChar(@as(u8, @intCast(8 - weak_side.len))));
    try builder.appendSlice(std.heap.c_allocator, "/8/8/8/8/");
    try appendSide(&builder, strong_side, color == 1);
    try builder.append(std.heap.c_allocator, digitChar(@as(u8, @intCast(8 - strong_side.len))));
    try builder.appendSlice(std.heap.c_allocator, "/8 w - - 0 10");

    return try allocCString(builder.items);
}

fn formatFenAlloc(
    board: []const u8,
    side_to_move: u8,
    chess960: bool,
    castling_rights: u8,
    white_oo_rook_square: u8,
    white_ooo_rook_square: u8,
    black_oo_rook_square: u8,
    black_ooo_rook_square: u8,
    ep_square: u8,
    rule50: c_int,
    game_ply: c_int,
) ![*:0]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(std.heap.c_allocator);

    var rank: i32 = 7;
    while (rank >= 0) : (rank -= 1) {
        var file: usize = 0;
        var empty_count: u8 = 0;

        while (file < 8) : (file += 1) {
            const rank_index: usize = @intCast(rank);
            const square_index = rank_index * 8 + file;
            const piece = board[square_index];
            if (piece == 0) {
                empty_count += 1;
                continue;
            }

            if (empty_count != 0) {
                try builder.append(std.heap.c_allocator, digitChar(empty_count));
                empty_count = 0;
            }

            try builder.append(std.heap.c_allocator, piece_to_char[@as(usize, piece)]);
        }

        if (empty_count != 0) {
            try builder.append(std.heap.c_allocator, digitChar(empty_count));
        }

        if (rank != 0) {
            try builder.append(std.heap.c_allocator, '/');
        }
    }

    try builder.appendSlice(std.heap.c_allocator, if (side_to_move == 0) " w " else " b ");

    var has_castling = false;
    if ((castling_rights & white_oo) != 0) {
        has_castling = true;
        try builder.append(std.heap.c_allocator, if (chess960) rookFileCharUpper(white_oo_rook_square) else 'K');
    }
    if ((castling_rights & white_ooo) != 0) {
        has_castling = true;
        try builder.append(std.heap.c_allocator, if (chess960) rookFileCharUpper(white_ooo_rook_square) else 'Q');
    }
    if ((castling_rights & black_oo) != 0) {
        has_castling = true;
        try builder.append(std.heap.c_allocator, if (chess960) rookFileCharLower(black_oo_rook_square) else 'k');
    }
    if ((castling_rights & black_ooo) != 0) {
        has_castling = true;
        try builder.append(std.heap.c_allocator, if (chess960) rookFileCharLower(black_ooo_rook_square) else 'q');
    }
    if (!has_castling) {
        try builder.append(std.heap.c_allocator, '-');
    }

    if (ep_square == sq_none) {
        try builder.appendSlice(std.heap.c_allocator, " - ");
    } else {
        try builder.append(std.heap.c_allocator, ' ');
        try appendSquare(&builder, ep_square);
        try builder.append(std.heap.c_allocator, ' ');
    }

    try appendInt(&builder, rule50);
    try builder.append(std.heap.c_allocator, ' ');
    const side_offset: c_int = if (side_to_move == black) 1 else 0;
    const fullmove = 1 + @divTrunc(game_ply - side_offset, 2);
    try appendInt(&builder, fullmove);

    return try allocCString(builder.items);
}

fn appendSide(builder: *std.ArrayList(u8), side: []const u8, lower: bool) !void {
    for (side) |byte| {
        try builder.append(std.heap.c_allocator, if (lower) std.ascii.toLower(byte) else byte);
    }
}

fn appendSquare(builder: *std.ArrayList(u8), square: u8) !void {
    try builder.append(std.heap.c_allocator, 'a' + fileOf(square));
    try builder.append(std.heap.c_allocator, '1' + rankOf(square));
}

fn appendInt(builder: *std.ArrayList(u8), value: c_int) !void {
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    try builder.appendSlice(std.heap.c_allocator, text);
}

fn allocCString(value: []const u8) ![*:0]u8 {
    const result = try std.heap.c_allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result[0..value.len], value);
    return result.ptr;
}

fn digitChar(value: u8) u8 {
    return '0' + value;
}

fn fileOf(square: u8) u8 {
    return square & 7;
}

fn rankOf(square: u8) u8 {
    return square >> 3;
}

fn rookFileCharUpper(square: u8) u8 {
    return 'A' + fileOf(square);
}

fn rookFileCharLower(square: u8) u8 {
    return 'a' + fileOf(square);
}

fn isMaterialPiece(piece: u8) bool {
    return switch (piece) {
        1...6, 9...14 => true,
        else => false,
    };
}
