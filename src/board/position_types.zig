// Position POD data types (M17.3b leaf-extraction).
//
// The plain-data core of the board representation, pulled out of the 4257-line
// position.zig god-file into a std-only leaf module so it can be imported from
// BOTH position.zig and graph_layout.zig without a module cycle (position imports
// graph_layout, so graph_layout cannot import position). This is the same
// cycle-break pattern proven for WorkerHistories (M17.2p): once these types live
// in a leaf, graph_layout can embed a *typed* Position/StateInfo in the Worker
// block instead of an opaque [N]u8 region.
//
// Native structs (M16.8 de-mirror): Zig owns the field order. The only external
// layout contracts are the fixed struct sizes (asserted below) that the Worker
// block reserves a slot for, plus the board/side_to_move offsets the NNUE eval
// reads (asserted against graph_layout in position.zig, which sees both).

const std = @import("std");

// Per-move dirty state the NNUE incremental update consumes (Position.scratch_dp).
pub const DirtyPiece = struct {
    pc: u8,
    from: u8,
    to: u8,
    remove_sq: u8,
    add_sq: u8,
    remove_pc: u8,
    add_pc: u8,
};

// Per-move threat deltas the NNUE update consumes (Position.scratch_dts):
// ValueList<DirtyThreat,96> plus the from/to king-square bookkeeping.
pub const DirtyThreats = struct {
    list_values: [96]u32, // ValueList<DirtyThreat,96>::values_
    list_size: usize, // ValueList<...>::size_
    us: u8,
    prev_ksq: u8,
    ksq: u8,
};

// The per-ply position state do_move pushes and undo_move pops. The leading block
// is copied on each move; the trailing block is recomputed, not copied.
pub const StateInfo = struct {
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

// Full memory image of upstream Position (src/position.h): the leading data
// members the ported code reaches through a pointer, plus the trailing NNUE
// scratch (scratch_dp/scratch_dts) that completes the object. With the scratch
// members the struct is the whole 1032-byte object, so the native graph owns and
// allocates a Position outright.
pub const Position = struct {
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
    scratch_dp: DirtyPiece,
    scratch_dts: DirtyThreats,
};

comptime {
    // The Worker block reserves a fixed-width slot for each of these (graph_layout's
    // position_size / state_info_size). These self-contained size asserts keep the
    // slot contract local to the type definition (graph_layout re-asserts the tie to
    // its constants). Field order is Zig's to choose; only the sizes are contractual.
    std.debug.assert(@sizeOf(Position) == 1032);
    std.debug.assert(@alignOf(Position) == 8);
    std.debug.assert(@sizeOf(StateInfo) == 192);
    std.debug.assert(@alignOf(StateInfo) == 8);
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "Position/StateInfo hold their contractual Worker-block slot widths" {
    try testing.expectEqual(@as(usize, 1032), @sizeOf(Position));
    try testing.expectEqual(@as(usize, 192), @sizeOf(StateInfo));
}

test "StateInfo chains through previous" {
    var root = std.mem.zeroes(StateInfo);
    var child = std.mem.zeroes(StateInfo);
    child.previous = &root;
    root.key = 0xABCD;
    try testing.expectEqual(@as(u64, 0xABCD), child.previous.?.key);
    try testing.expectEqual(@as(?*StateInfo, null), root.previous);
}
