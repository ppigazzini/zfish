const position_types = @import("position_types");

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
// shared leaf they all already import — instead of the old C-ABI exports.
// position.initRuntime() installs them before any search runs.
//
// M17.9: NON-OPTIONAL, each defaulting to a named panic stub (matching the
// native_hooks registry idiom), so fill()/moveIsLegal() invoke them directly with no
// `.?` null-unwrap. An unregistered hook fails fast with its own name instead of an
// opaque null-optional panic.
fn hookPanic(comptime name: []const u8) noreturn {
    @panic(name ++ ": position snapshot hook not registered (initRuntime not run?)");
}

pub var fill_fn: *const fn (pos: *const anyopaque, out: *anyopaque) void =
    struct {
        fn stub(_: *const anyopaque, _: *anyopaque) void {
            hookPanic("fill_fn");
        }
    }.stub;
pub var move_is_legal_fn: *const fn (pos: *const position_types.Position, raw_move: u16) bool =
    struct {
        fn stub(_: *const position_types.Position, _: u16) bool {
            hookPanic("move_is_legal_fn");
        }
    }.stub;

pub inline fn fill(pos: *const anyopaque, out: *anyopaque) void {
    fill_fn(pos, out);
}
pub inline fn moveIsLegal(pos: *const position_types.Position, raw_move: u16) bool {
    return move_is_legal_fn(pos, raw_move);
}
