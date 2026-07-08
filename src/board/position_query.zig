// Read-only Position accessors and snapshot builders (M17.3k).
//
// The small "read a fact off the live Position" queries lifted out of
// position.zig: the scalar accessors (side/chess960/ply/checkers/material), and
// the snapshot fills that copy the Position into the NNUE/board views the eval
// and movegen consume. All are read-only over a *const Position, so this is a
// leaf over board_core + position_types -- no import of position, no cycle.
// position.zig re-exports them so its callers and the fill_snapshot hook resolve
// through the position surface unchanged.

const std = @import("std");
const board_core = @import("board_core");
const position_types = @import("position_types");

const Position = position_types.Position;
const king_pt = board_core.king_pt;

pub fn sideToMove(pos: *const Position) u8 {
    return pos.side_to_move;
}

pub fn isChess960(pos: *const Position) bool {
    return pos.chess960;
}

pub fn gamePly(pos: *const Position) c_int {
    return pos.game_ply;
}

pub fn hasCheckers(pos: *const Position) bool {
    return pos.st.checkers_bb != 0;
}

// WDL-model material count (src/uci.cpp): pawns + 3*(knights+bishops) +
// 5*rooks + 9*queens, both colours. piece_count is indexed by piece
// (white type at 1..5, black type at 9..13).
pub fn wdlMaterial(pos: *const Position) c_int {
    const pc = pos.piece_count;
    return (pc[1] + pc[9]) + 3 * (pc[2] + pc[10]) + 3 * (pc[3] + pc[11]) +
        5 * (pc[4] + pc[12]) + 9 * (pc[5] + pc[13]);
}

// Layout matches position_snapshot.PositionSnapshot. Read straight from the
// Position memory mirror.
const FillSnapshot = struct {
    side_to_move: u8,
    pieces_all: u64,
    pieces_by_color: [2]u64,
    pieces_by_type: [8]u64,
    blockers_for_king: [2]u64,
    pinners: [2]u64,
    king_square: [2]u8,
    ep_square: u8,
    castling_rights: u8,
    castling_impeded: [16]u8,
    castling_rook_square: [16]u8,
    checkers: u64,
    board: [64]u8,
    pawn_key: u64,
    key: u64,
    material_value: c_int,
    rule50_count: c_int,
    game_ply: c_int,
    is_chess960: u8,
};

// Position::fill_snapshot: derive the NNUE/board snapshot from the live Position.
// Reads the memory mirror directly.
pub fn fillSnapshot(pos_ptr: *const anyopaque, out_ptr: *anyopaque) void {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const st = pos.st;
    const out: *FillSnapshot = @ptrCast(@alignCast(out_ptr));

    out.side_to_move = pos.side_to_move;
    out.pieces_all = pos.by_type_bb[0];
    out.pieces_by_color[0] = pos.by_color_bb[0];
    out.pieces_by_color[1] = pos.by_color_bb[1];
    var t: usize = 0;
    while (t < 8) : (t += 1) out.pieces_by_type[t] = pos.by_type_bb[t];
    out.blockers_for_king = st.blockers_for_king;
    out.pinners = st.pinners;
    out.king_square[0] = @intCast(@ctz(pos.by_color_bb[0] & pos.by_type_bb[king_pt]));
    out.king_square[1] = @intCast(@ctz(pos.by_color_bb[1] & pos.by_type_bb[king_pt]));
    out.ep_square = st.ep_square;
    out.checkers = st.checkers_bb;

    out.castling_rights = @intCast(st.castling_rights);
    for ([_]u8{ 1, 2, 4, 8 }) |cr| {
        out.castling_impeded[cr] = if ((pos.by_type_bb[0] & pos.castling_path[cr]) != 0) 1 else 0;
        out.castling_rook_square[cr] = pos.castling_rook_square[cr];
    }

    out.pawn_key = st.pawn_key;
    out.key = st.key;
    const pawns = pos.piece_count[1] + pos.piece_count[9];
    out.material_value = 534 * pawns + st.non_pawn_material[0] + st.non_pawn_material[1];
    out.rule50_count = st.rule50;
    out.game_ply = pos.game_ply;
    out.is_chess960 = @intFromBool(pos.chess960);

    var s: usize = 0;
    while (s < 64) : (s += 1) out.board[s] = pos.board[s];
}

// The 64-square piece board only, for NNUE piece-count/accumulator callers that
// need just the board (not the full snapshot). Relocated from main.zig (M16.7).
pub fn accumulatorSnapshot(pos_ptr: *const anyopaque, pieces_out: [*]u8) void {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    var s: usize = 0;
    while (s < 64) : (s += 1) pieces_out[s] = pos.board[s];
}
