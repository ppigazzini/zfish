pub const PositionSnapshot = struct {
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

// Cycle-break hooks (M16.9): position.zig can't be imported by movegen/movepick/
// nnue/uci_move (they are imported *by* position), so it registers these here — the
// shared leaf they all already import — instead of the old zfish_position_* C-ABI
// exports. position.initRuntime() installs them before any search runs.
pub var fill_fn: ?*const fn (pos: *const anyopaque, out: *anyopaque) void = null;
pub var move_is_legal_fn: ?*const fn (pos: *const anyopaque, raw_move: u16) bool = null;

pub inline fn fill(pos: *const anyopaque, out: *anyopaque) void {
    fill_fn.?(pos, out);
}
pub inline fn moveIsLegal(pos: *const anyopaque, raw_move: u16) bool {
    return move_is_legal_fn.?(pos, raw_move);
}
