// FEN parsing: build a Position from a FEN string (M17.3o).
//
// The FEN *decode* side of the board, split out of position.zig. Unlike fen.zig
// (pure string encoding), parsing writes a live Position -- it places pieces,
// derives castling rights, and rebuilds the cached state -- so it depends on the
// move/state leaves (move_do.putPiece, state_setup.setState/setCastlingRight,
// legality.attackersTo(Exist)) plus board_core primitives. All of those are
// leaves, so fen_parse imports no position.zig -- no cycle. position.zig
// re-exports setPosition so setPositionState and the engine/thread callers keep
// resolving through the position surface.

const std = @import("std");
const board_core = @import("board_core");
const move_do = @import("move_do");
const state_setup = @import("state_setup");
const legality = @import("legality");
const position_types = @import("position_types");

const Position = position_types.Position;
const StateInfo = position_types.StateInfo;

const sq_none_u8: u8 = 64;
const piece_to_char = " PNBRQK  pnbrqk";

const pawn_pt = board_core.pawn_pt;
const rook_pt = board_core.rook_pt;
const king_pt = board_core.king_pt;
const color_white = board_core.color_white;
const color_black = board_core.color_black;
const rank1_bb = board_core.rank1_bb;
const rank8_bb = board_core.rank8_bb;
const sqBb = board_core.sqBb;
const makeSquare = board_core.makeSquare;
const relativeSquare = board_core.relativeSquare;
const pawnAttacks = board_core.pawnAttacks;
const kingSquare = board_core.kingSquare;
const putPiece = move_do.putPiece;
const setState = state_setup.setState;
const setCastlingRight = state_setup.setCastlingRight;
const attackersTo = legality.attackersTo;
const attackersToExist = legality.attackersToExist;

inline fn countPt(pos: *const Position, c: u8, pt: u8) c_int {
    return pos.piece_count[(c << 3) | pt];
}
inline fn pawnPush(c: u8) i16 {
    return if (c == color_white) 8 else -8;
}
fn pieceCharIndex(token: u8) ?u8 {
    for (piece_to_char, 0..) |ch, idx| {
        if (ch == token and ch != ' ') return @intCast(idx);
    }
    return null;
}
fn setErr(comptime msg: []const u8) ?[*:0]u8 {
    return allocCString(msg) catch null;
}

const FenCursor = struct {
    fen: []const u8,
    i: usize = 0,
    fn next(self: *FenCursor) ?u8 {
        if (self.i >= self.fen.len) return null;
        const ch = self.fen[self.i];
        self.i += 1;
        return ch;
    }
    fn skipWs(self: *FenCursor) void {
        while (self.i < self.fen.len and std.ascii.isWhitespace(self.fen[self.i])) self.i += 1;
    }
};

pub fn setPosition(
    pos_ptr: *Position,
    fen_ptr: [*]const u8,
    fen_len: usize,
    is_chess960: u8,
    st_ptr: *StateInfo,
    pos_size: usize,
    st_size: usize,
) ?[*:0]u8 {
    const pos = pos_ptr;
    @memset(@as([*]u8, @ptrCast(pos))[0..pos_size], 0);
    @memset(@as([*]u8, @ptrCast(st_ptr))[0..st_size], 0);
    pos.st = st_ptr;

    var cur = FenCursor{ .fen = fen_ptr[0..fen_len] };

    // 1. Piece placement
    var num_pieces: c_int = 0;
    var file: i32 = 0;
    var rank: i32 = 7;
    while (cur.next()) |token| {
        if (std.ascii.isWhitespace(token)) break;
        if (token >= '0' and token <= '9') {
            const diff: i32 = token - '0';
            if (diff < 1 or diff > 8) return setErr("Invalid FEN. Invalid number of squares to skip.");
            file += diff;
            if (file > 8) return setErr("Invalid FEN. Invalid file reached.");
        } else if (token == '/') {
            if (file != 8) return setErr("Invalid FEN. Trying to end rank when not at the end of it.");
            rank -= 1;
            file = 0;
            if (rank < 0) return setErr("Invalid FEN. Invalid rank reached.");
        } else {
            if (file >= 8) return setErr("Invalid FEN. Invalid file reached.");
            const idx = pieceCharIndex(token) orelse return setErr("Invalid FEN. Invalid piece.");
            num_pieces += 1;
            if (num_pieces > 32) return setErr("Invalid FEN. More than 32 pieces on the board.");
            putPiece(pos, idx, makeSquare(@intCast(file), @intCast(rank)));
            file += 1;
        }
    }
    if (rank != 0 or file != 8)
        return setErr("Invalid FEN. Board state encoding ended but cursor not at end.");
    if ((pos.by_type_bb[pawn_pt] & (rank1_bb | rank8_bb)) != 0)
        return setErr("Unsupported position. Pawns on the first or eighth rank.");
    if (countPt(pos, color_white, king_pt) != 1 or countPt(pos, color_black, king_pt) != 1)
        return setErr("Unsupported position. Incorrect number of kings.");

    // 2. Active color
    const active = cur.next() orelse return setErr("Invalid FEN. Unexpected end of stream.");
    if (active != 'w' and active != 'b') return setErr("Invalid FEN. Invalid side to move.");
    pos.side_to_move = if (active == 'w') color_white else color_black;
    const stm = pos.side_to_move;
    const them = stm ^ 1;
    const ws = cur.next();
    if (ws == null or !std.ascii.isWhitespace(ws.?) or cur.i >= cur.fen.len)
        return setErr("Invalid FEN. Expected whitespace after side to move.");

    // 3. Castling availability
    var num_castling: c_int = 0;
    while (cur.next()) |tok0| {
        var token = tok0;
        if (std.ascii.isWhitespace(token)) break;
        if (num_castling == 0 and token == '-') {
            cur.skipWs();
            break;
        }
        num_castling += 1;
        if (num_castling > 4) return setErr("Invalid FEN. Maximum of 4 castling rights can be specified.");

        const c: u8 = if (std.ascii.isLower(token)) color_black else color_white;
        const rook = (c << 3) | rook_pt;
        const king = (c << 3) | king_pt;
        token = std.ascii.toUpper(token);

        var rsq: i32 = -1;
        var ksq: i32 = -1;
        if (token == 'K' or token == 'Q') {
            const dir: i32 = if (token == 'K') -1 else 1;
            var sq: i32 = relativeSquare(c, if (token == 'K') 7 else 0); // SQ_H1 : SQ_A1
            var n: usize = 0;
            while (n < 7) : (n += 1) {
                const pc = pos.board[@intCast(sq)];
                if (pc == king) {
                    ksq = sq;
                    break;
                } else if (pc == rook and rsq == -1) {
                    rsq = sq;
                }
                sq += dir;
            }
        } else if (token >= 'A' and token <= 'H') {
            const rel_rank1 = relativeSquare(c, 0) >> 3; // rank of relative SQ_A1
            const rsq_cand = makeSquare(token - 'A', rel_rank1);
            if (pos.board[rsq_cand] == rook) rsq = rsq_cand;
            var sq: i32 = relativeSquare(c, 1); // SQ_B1
            var n: usize = 0;
            while (n < 6) : (n += 1) {
                if (pos.board[@intCast(sq)] == king) ksq = sq;
                sq += 1;
            }
        } else return setErr("Invalid FEN. Expected castling rights.");

        if (ksq != -1 and rsq != -1) setCastlingRight(pos_ptr, c, @intCast(rsq));
    }

    // 4. En passant square
    var enpassant_ok = false;
    var legal_ep = false;
    const col = cur.next() orelse '-';
    if (col != '-') {
        const row = cur.next() orelse return setErr("Invalid FEN. Unexpected end of stream.");
        if ((col >= 'a' and col <= 'h') and (row == (if (stm == color_white) @as(u8, '6') else '3'))) {
            const ep = makeSquare(col - 'a', row - '1');
            pos.st.ep_square = ep;
            const all = pos.by_type_bb[0];
            const our_pawns = pos.by_color_bb[stm] & pos.by_type_bb[pawn_pt];
            const their_pawns = pos.by_color_bb[them] & pos.by_type_bb[pawn_pt];
            var pawns = pawnAttacks(them, ep) & our_pawns;
            const target_sq: u8 = @intCast(@as(i16, ep) + pawnPush(them));
            const target = their_pawns & sqBb(target_sq);
            const behind_sq: u8 = @intCast(@as(i16, ep) + pawnPush(stm));
            enpassant_ok = pawns != 0 and target != 0 and (all & (sqBb(ep) | sqBb(behind_sq))) == 0;
            const occ = all ^ target ^ sqBb(ep);
            const ksq = kingSquare(pos, stm);
            while (pawns != 0) {
                const pawn_sq: u8 = @intCast(@ctz(pawns));
                pawns &= pawns - 1;
                if ((attackersTo(pos_ptr, ksq, occ ^ sqBb(pawn_sq)) & pos.by_color_bb[them] & ~target) == 0)
                    legal_ep = true;
            }
        } else return setErr("Invalid FEN. Invalid en-passant square.");
    }
    if (!enpassant_ok or !legal_ep) pos.st.ep_square = sq_none_u8;

    // 5-6. Halfmove clock and fullmove number
    cur.skipWs();
    const rule50 = parseInt(&cur) orelse 0;
    cur.skipWs();
    var game_ply = parseInt(&cur) orelse 0;
    if (rule50 < 0 or rule50 > 32767) return setErr("Unsupported position. Rule50 counter out of range.");
    if (game_ply < 0 or game_ply > 100000) return setErr("Unsupported position. Game ply out of range.");
    pos.st.rule50 = rule50;
    game_ply = @max(2 * (game_ply - 1), 0) + @as(c_int, if (stm == color_black) 1 else 0);
    pos.game_ply = game_ply;

    pos.chess960 = is_chess960 != 0;
    setState(pos_ptr);

    if (attackersToExist(pos_ptr, kingSquare(pos, them), pos.by_type_bb[0], stm))
        return setErr("Unsupported position. King can be captured.");

    return null;
}

fn parseInt(cur: *FenCursor) ?c_int {
    var val: c_int = 0;
    var any = false;
    var neg = false;
    if (cur.i < cur.fen.len and (cur.fen[cur.i] == '-' or cur.fen[cur.i] == '+')) {
        neg = cur.fen[cur.i] == '-';
        cur.i += 1;
    }
    while (cur.i < cur.fen.len and cur.fen[cur.i] >= '0' and cur.fen[cur.i] <= '9') {
        val = val * 10 + @as(c_int, cur.fen[cur.i] - '0');
        cur.i += 1;
        any = true;
    }
    if (!any) return null;
    return if (neg) -val else val;
}

fn allocCString(value: []const u8) ![*:0]u8 {
    const result = try std.heap.c_allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result[0..value.len], value);
    return result.ptr;
}
