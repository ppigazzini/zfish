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
    rule50_count: i32,
    game_ply: i32,
    is_chess960: u8,
};

/// hook-class: service — a leaf answering a query it must not import the answer for.
/// Own and self-register this hook in position.zig; every other hook in the tree is
/// registered by the composition root (main.zig).
///
/// Break the import cycle: position.zig can't be imported by the modules that need a
/// snapshot (they are imported *by* position), so it registers the filler here — the
/// shared leaf they all already import — instead of the old C-ABI export.
/// Install it via position.initRuntime() before any search runs.
///
/// Make it NON-OPTIONAL, defaulting to a named panic stub (matching the
/// runtime_hooks registry idiom), so fill() invokes it directly with no `.?`
/// null-unwrap. An unregistered hook fails fast with its own name instead of an
/// opaque null-optional panic.
fn hookPanic(comptime name: []const u8) noreturn {
    @panic(name ++ ": position snapshot hook not registered (initRuntime not run?)");
}

/// failure: loud — hookPanic naming the hook. Install it via position.initRuntime() before any search runs.
pub var fill_fn: *const fn (pos: *const position_types.Position, out: *PositionSnapshot) void =
    struct {
        fn stub(_: *const position_types.Position, _: *PositionSnapshot) void {
            hookPanic("fill_fn");
        }
    }.stub;

pub inline fn fill(pos: *const position_types.Position, out: *PositionSnapshot) void {
    fill_fn(pos, out);
}

test {
    @import("std").testing.refAllDecls(@This());
}
