// Native Zig StateInfo.
//
// Part of the post-src/ object graph: the per-ply position state that do_move
// pushes and undo_move pops. Laid out byte-for-byte against the C++
// Stockfish::StateInfo (src/position.h) so it interoperates with the ported
// position code during the transition and is the native owner afterwards.

const std = @import("std");

const color_nb = 2;
const piece_type_nb = 8;

pub const Key = u64;
pub const Bitboard = u64;
pub const Value = i32;

pub const StateInfo = extern struct {
    // Copied when making a move.
    material_key: Key,
    pawn_key: Key,
    minor_piece_key: Key,
    non_pawn_key: [color_nb]Key,
    non_pawn_material: [color_nb]Value,
    castling_rights: i32,
    rule50: i32,
    plies_from_null: i32,
    ep_square: i32, // Square

    // Recomputed, not copied.
    key: Key,
    checkers_bb: Bitboard,
    previous: ?*StateInfo,
    blockers_for_king: [color_nb]Bitboard,
    pinners: [color_nb]Bitboard,
    check_squares: [piece_type_nb]Bitboard,
    captured_piece: i32, // Piece
    repetition: i32,
};

comptime {
    // Must reproduce the locked 192-byte C++ StateInfo footprint with the key
    // anchor offsets the ported code relies on.
    std.debug.assert(@sizeOf(StateInfo) == 192);
    std.debug.assert(@offsetOf(StateInfo, "key") == 64);
    std.debug.assert(@offsetOf(StateInfo, "previous") == 80);
    std.debug.assert(@offsetOf(StateInfo, "repetition") == 188);
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "StateInfo reproduces the C++ footprint and anchors" {
    try testing.expectEqual(@as(usize, 192), @sizeOf(StateInfo));
    try testing.expectEqual(@as(usize, 0), @offsetOf(StateInfo, "material_key"));
    try testing.expectEqual(@as(usize, 64), @offsetOf(StateInfo, "key"));
    try testing.expectEqual(@as(usize, 80), @offsetOf(StateInfo, "previous"));
    try testing.expectEqual(@as(usize, 188), @offsetOf(StateInfo, "repetition"));
}

test "StateInfo chains through previous" {
    var root = std.mem.zeroes(StateInfo);
    var child = std.mem.zeroes(StateInfo);
    child.previous = &root;
    root.key = 0xABCD;
    try testing.expectEqual(@as(Key, 0xABCD), child.previous.?.key);
    try testing.expectEqual(@as(?*StateInfo, null), root.previous);
}
