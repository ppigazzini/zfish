// Position lifecycle / port surface (M17.3y).
//
// The allocate/free/setup/do-move entry points the engine and thread drivers call
// through the position facade -- position operations that had accreted in
// search_driver.zig only because that file was carved out of position.zig. They
// touch no search state (no QCtx / SearchStack / worker graph), so they live here
// as a leaf: the facade re-exports them, engine/thread resolve here. Thin wrappers
// over the move_do / fen_parse / legality leaves with the graph sizes filled in.

const std = @import("std");
const graph_layout = @import("graph_layout");
const move_do = @import("move_do");
const legality = @import("legality");
const fen_parse = @import("fen_parse");
const position_types = @import("position_types");

const Position = position_types.Position;
const DirtyPiece = position_types.DirtyPiece;
const DirtyThreats = position_types.DirtyThreats;
const doMove = move_do.doMove;
const givesCheck = legality.givesCheck;
const setPosition = fen_parse.setPosition;

// do a move with fresh dirty-piece/threats scratch (the perft/setup path, which
// does not thread an accumulator delta through).
pub fn doMoveState(pos_ptr: *Position, move: u16, st_ptr: *anyopaque) void {
    var dp: DirtyPiece = undefined;
    var dts: DirtyThreats = undefined;
    dts.list_size = 0;
    doMove(pos_ptr, move, st_ptr, @intFromBool(givesCheck(pos_ptr, move)), &dp, &dts);
}

/// Allocate a zeroed Position block.
pub fn create() ?*Position {
    const buf = std.c.malloc(graph_layout.position_size) orelse return null;
    @memset(@as([*]u8, @ptrCast(buf))[0..graph_layout.position_size], 0);
    return @ptrCast(@alignCast(buf));
}
pub fn destroy(pos: ?*Position) void {
    if (pos) |p| std.c.free(p);
}

/// setPosition with the engine-graph Position/StateInfo sizes filled in (lets callers keep
/// the 5-arg shape without threading graph sizes through).
pub fn setPositionState(pos_ptr: *Position, fen_ptr: [*]const u8, fen_len: usize, chess960_enabled: u8, state_ptr: *anyopaque) ?[*:0]u8 {
    return setPosition(pos_ptr, fen_ptr, fen_len, chess960_enabled, state_ptr, graph_layout.position_size, graph_layout.state_info_size);
}
