// Define the position POD data types.
//
// Hold the plain-data core of the board representation, pulled out of the 4257-line
// position.zig god-file into a std-only leaf module so it can be imported from
// BOTH position.zig and worker_layout.zig without a module cycle (position imports
// worker_layout, so worker_layout cannot import position). Reuse the same
// cycle-break pattern proven for WorkerHistories: once these types live
// in a leaf, worker_layout can embed a *typed* Position/StateInfo in the Worker
// block instead of an opaque [N]u8 region.
//
// StateInfo lets Zig own the field order (plain struct); Position is extern, pinning
// `board` to offset 0 (see the comment on Position below). The only external layout
// contracts are the fixed struct sizes (asserted below) that the Worker block reserves
// a slot for -- the network reads board/side_to_move through a typed *const Position,
// not a raw offset, so no other pin is needed.

const std = @import("std");

// Hold the per-move dirty state the NNUE incremental update consumes (Position.scratch_dp).
// extern so it stays legal as a Position field once Position itself is extern (below).
pub const DirtyPiece = extern struct {
    pc: u8,
    from: u8,
    to: u8,
    remove_sq: u8,
    add_sq: u8,
    remove_pc: u8,
    add_pc: u8,
};

// Hold the per-move threat deltas the NNUE update consumes (Position.scratch_dts):
// a bounded 96-slot DirtyThreat list plus the from/to king-square bookkeeping, plus the
// pawn-pair diff (before/after pawn bitboards per color) the PP_3Wide feature set consumes.
// Byte-layout-identical to nnue_acc_layout.ThreatDiffView -- do_move writes through this
// alias of the accumulator slot's diff bytes; keep the field order in sync with it.
// extern (C declaration-order layout) so this stays byte-identical to
// nnue_acc_layout.ThreatDiffView regardless of Zig's field-reordering heuristics -- the two
// alias the same accumulator-slot bytes (do_move writes here, applyCombined reads there). A
// plain struct reorders the align-4 list_values differently from ThreatDiffView's nested
// align-8 list once the align-8 pp fields are present, silently corrupting the incremental
// path; extern pins both to declaration order. A cross-struct comptime assert re-checks it.
pub const DirtyThreats = extern struct {
    list_values: [96]u32, // the DirtyThreat values (bounded 96)
    list_size: usize, // the DirtyThreat list length
    pp_before: [2]u64, // pawn bitboards [WHITE, BLACK] before the move
    pp_after: [2]u64, // pawn bitboards [WHITE, BLACK] after the move
    us: u8,
    prev_ksq: u8,
    ksq: u8,
};

// Hold the per-ply position state do_move pushes and undo_move pops. The leading block
// is copied on each move; the trailing block is recomputed, not copied.
pub const StateInfo = struct {
    material_key: u64,
    pawn_key: u64,
    minor_piece_key: u64,
    non_pawn_key: [2]u64,
    non_pawn_material: [2]i32,
    castling_rights: i32,
    rule50: i32,
    plies_from_null: i32,
    ep_square: u8,
    key: u64,
    checkers_bb: u64,
    previous: ?*StateInfo,
    blockers_for_king: [2]u64,
    pinners: [2]u64,
    check_squares: [8]u64,
    captured_piece: u8,
    repetition: i32,
};

// Define the full Position object: the leading data members plus the trailing NNUE
// scratch (scratch_dp/scratch_dts) that completes the object. With the scratch
// members the struct is the whole 1064-byte object, so the graph owns and
// allocates a Position outright.
//
// extern (declaration-order layout): `board` is Piece[64], exactly one cache line, and
// upstream declares it first so piece_on() -- read by movepick scoring, SEE, gives_check,
// legality and every make/unmake -- touches a single line. A plain struct lets Zig sort
// fields by descending alignment instead, which pushed board to offset 972, straddling
// two lines. Declaration order already sums to the contractual 1064 bytes with board
// first (verified by the size assert below), so pinning it costs nothing.
pub const Position = extern struct {
    board: [64]u8,
    by_type_bb: [8]u64,
    by_color_bb: [2]u64,
    piece_count: [16]i32,
    castling_rights_mask: [64]i32,
    castling_rook_square: [16]u8,
    castling_path: [16]u64,
    st: *StateInfo,
    game_ply: i32,
    side_to_move: u8,
    chess960: bool,
    scratch_dp: DirtyPiece,
    scratch_dts: DirtyThreats,
};

/// Mix the rule50 counter into a raw Zobrist key, as upstream's
/// `Position::adjust_key50<AfterMove>` does (position.h:322). Take the counter as a
/// parameter rather than reading `pos.st`: the two instantiations differ only in whether
/// the counter has already been incremented, so a caller holding a post-move key and a
/// pre-move counter passes `rule50 + 1` instead of needing a second copy of the formula.
///
/// Live here, on the type that owns rule50, because upstream keeps it on Position itself
/// and because BOTH zones need it: move_do computes the TT probe key, and position_query
/// answers `d`'s Key line. A second copy is how those two silently drifted before -- the
/// display read the raw key for every position whose counter had reached 14.
pub inline fn adjustKey50(key: u64, rule50: i32) u64 {
    if (rule50 < 14) return key;
    const seed: u64 = @intCast(@divTrunc(rule50 - 14, 8));
    return key ^ (seed *% 6364136223846793005 +% 1442695040888963407);
}

comptime {
    // Assert the fixed-width slot the Worker block reserves for each of these (worker_layout's
    // position_size / state_info_size). These self-contained size asserts keep the
    // slot contract local to the type definition (worker_layout re-asserts the tie to
    // its constants). Field order is Zig's to choose; only the sizes are contractual.
    std.debug.assert(@sizeOf(Position) == 1064);
    std.debug.assert(@alignOf(Position) == 8);
    std.debug.assert(@sizeOf(StateInfo) == 192);
    std.debug.assert(@alignOf(StateInfo) == 8);
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "Position/StateInfo hold their contractual Worker-block slot widths" {
    try testing.expectEqual(@as(usize, 1064), @sizeOf(Position));
    try testing.expectEqual(@as(usize, 192), @sizeOf(StateInfo));
}

test "adjustKey50 is identity below 14 and mixes in steps of 8 above it" {
    const key: u64 = 0x8F8F01D4562F59FB;
    // Below the threshold the key is returned untouched, which is why every golden and
    // every bench position agreed while the `d` display was reading the raw key.
    try testing.expectEqual(key, adjustKey50(key, 0));
    try testing.expectEqual(key, adjustKey50(key, 13));
    // At and above it the mix is keyed by (rule50 - 14) / 8, so 14..21 share one seed.
    try testing.expect(adjustKey50(key, 14) != key);
    try testing.expectEqual(adjustKey50(key, 14), adjustKey50(key, 21));
    try testing.expect(adjustKey50(key, 14) != adjustKey50(key, 22));
    // The exact value upstream prints for the rule50=999 position this was found on.
    try testing.expectEqual(@as(u64, 0x0CEACC969514C215), adjustKey50(key, 999));
}

test "StateInfo chains through previous" {
    var root = std.mem.zeroes(StateInfo);
    var child = std.mem.zeroes(StateInfo);
    child.previous = &root;
    root.key = 0xABCD;
    try testing.expectEqual(@as(u64, 0xABCD), child.previous.?.key);
    try testing.expectEqual(@as(?*StateInfo, null), root.previous);
}
