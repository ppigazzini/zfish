// Move make/unmake (M17.3m+).
//
// The mutating side of the board: applying and reverting moves on a live
// Position. This slice seeds the module with the null-move pair; the real
// make/unmake (doMove/undoMove/putPiece + the board mutators) follows. Every
// dependency is a leaf (board_core primitives, the zobrist keys, state_setup's
// setCheckInfo), so move_do imports no position.zig -- no cycle. position.zig
// re-exports the public entry points so the search callers keep resolving.

const std = @import("std");
const board_core = @import("board_core");
const zobrist = @import("zobrist");
const state_setup = @import("state_setup");
const position_types = @import("position_types");

const Position = position_types.Position;
const StateInfo = position_types.StateInfo;

const sq_none_u8: u8 = 64;
const fileOf = board_core.fileOf;
const setCheckInfo = state_setup.setCheckInfo;

pub fn doNullMove(pos_ptr: *anyopaque, new_st_ptr: *anyopaque) void {
    const pos: *Position = @ptrCast(@alignCast(pos_ptr));
    const new_st: *StateInfo = @ptrCast(@alignCast(new_st_ptr));

    new_st.* = pos.st.*; // memcpy(&newSt, st, sizeof(StateInfo))
    new_st.previous = pos.st;
    pos.st = new_st;

    if (pos.st.ep_square != sq_none_u8) {
        pos.st.key ^= zobrist.zob_enpassant[fileOf(pos.st.ep_square)];
        pos.st.ep_square = sq_none_u8;
    }
    pos.st.key ^= zobrist.zob_side_val;
    pos.st.plies_from_null = 0;

    // Upstream 782852b26: the StateInfo was copied from the previous ply (incl. its capturedPiece);
    // a null move captures nothing, so clear it or prior_capture detection reads a stale value.
    pos.st.captured_piece = 0; // NO_PIECE

    pos.side_to_move ^= 1;
    setCheckInfo(pos_ptr);
    pos.st.repetition = 0;
}

pub fn undoNullMove(pos_ptr: *anyopaque) void {
    const pos: *Position = @ptrCast(@alignCast(pos_ptr));
    pos.st = pos.st.previous.?;
    pos.side_to_move ^= 1;
}
