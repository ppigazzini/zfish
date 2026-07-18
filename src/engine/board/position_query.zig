// Provide the read-only Position accessors and snapshot builders.
//
// Gather the small "read a fact off the live Position" queries lifted out of
// position.zig: the scalar accessors (side/chess960/ply/checkers/material), and
// the snapshot fills that copy the Position into the NNUE/board views the eval
// and movegen consume. All are read-only over a *const Position, so this is a
// leaf over board_core + position_types -- no import of position, no cycle.
// position.zig re-exports them so its callers and the fill_snapshot hook resolve
// through the position surface unchanged.

const std = @import("std");
const board_core = @import("board_core");
const position_types = @import("position_types");
const position_snapshot = @import("position_snapshot");

const Position = position_types.Position;
const king_pt = board_core.king_pt;

pub fn sideToMove(pos: *const Position) u8 {
    return pos.side_to_move;
}

pub fn isChess960(pos: *const Position) bool {
    return pos.chess960;
}

pub fn gamePly(pos: *const Position) i32 {
    return pos.game_ply;
}

pub fn hasCheckers(pos: *const Position) bool {
    return pos.st.checkers_bb != 0;
}

// Count the WDL-model material (src/uci.cpp): pawns + 3*(knights+bishops) +
// 5*rooks + 9*queens, both colours. piece_count is indexed by piece
// (white type at 1..5, black type at 9..13).
pub fn wdlMaterial(pos: *const Position) i32 {
    const pc = pos.piece_count;
    return (pc[1] + pc[9]) + 3 * (pc[2] + pc[10]) + 3 * (pc[3] + pc[11]) +
        5 * (pc[4] + pc[12]) + 9 * (pc[5] + pc[13]);
}

// Alias position_snapshot.PositionSnapshot -- the snapshot the fill hook writes.
const FillSnapshot = position_snapshot.PositionSnapshot;

// Derive the NNUE/board snapshot from the live Position (fillSnapshot).
// Read the Position fields directly.
pub fn fillSnapshot(pos: *const Position, out: *FillSnapshot) void {
    const st = pos.st;

    out.side_to_move = pos.side_to_move;
    out.pieces_all = pos.by_type_bb[0];
    out.pieces_by_color[0] = pos.by_color_bb[0];
    out.pieces_by_color[1] = pos.by_color_bb[1];
    @memcpy(out.pieces_by_type[0..8], pos.by_type_bb[0..8]);
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

    // Copy the two bulk fields -- the whole cost of this function -- with @memcpy: a
    // byte-at-a-time board copy is 64 scalar moves per node; @memcpy lowers to vector loads/stores.
    @memcpy(out.board[0..64], pos.board[0..64]);
}

// Copy the 64-square piece board only, for NNUE piece-count/accumulator callers that
// need just the board (not the full snapshot).
pub fn accumulatorSnapshot(pos: *const Position, pieces_out: [*]u8) void {
    var s: usize = 0;
    while (s < 64) : (s += 1) pieces_out[s] = pos.board[s];
}

test {
    @import("std").testing.refAllDecls(@This());
}
