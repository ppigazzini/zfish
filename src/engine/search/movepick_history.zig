// Provide the move-ordering history heuristics: the HistorySnapshot (typed views
// over the worker's history tables) + the five history-score lookups. Pure reads of
// value snapshots; std only.

const std = @import("std");

const square_nb: usize = 64;
const piece_type_nb: usize = 8;
const piece_nb: usize = 16;

pub const HistorySnapshot = struct {
    main_base: ?[*]const MainHistoryRow,
    low_ply_base: ?[*]const LowPlyHistoryRow,
    capture_base: ?[*]const CaptureHistoryRow,
    continuation_base: [6]ContHistSlot,
    pawn_table: ?[*]const PawnHistoryRow,
    pawn_mask: u64,
};

pub const HistoryEntry = struct {
    value: i16,
};

pub const AtomicHistoryEntry = struct {
    value: i16,
};

pub const MainHistoryRow = [1 << 16]HistoryEntry;
pub const LowPlyHistoryRow = [1 << 16]HistoryEntry;
pub const CaptureHistoryRow = [square_nb][piece_type_nb]HistoryEntry;
pub const PieceToHistoryRow = [square_nb]HistoryEntry;
pub const PawnHistoryRow = [square_nb]AtomicHistoryEntry;

// Hold one continuation-history slot: a PieceToHistory page viewed as [piece][square].
pub const ContHistSlot = ?[*]const PieceToHistoryRow;

// View a caller's contHist array as slots. The source is [1] on the qsearch path and [6] in
// the main search, so keep the length: the snapshot fills only the slots that exist, and a
// bare many-pointer would let qsearch's single slot be read as six.
pub inline fn contHistSlice(arr: anytype) []const ContHistSlot {
    return @as([*]const ContHistSlot, @ptrCast(arr))[0..arr.len];
}

// Pack the history-table base pointers into a HistorySnapshot.
pub fn fillHistorySnapshot(
    main_history: ?[*]const MainHistoryRow,
    low_ply_history: ?[*]const LowPlyHistoryRow,
    capture_history: ?[*]const CaptureHistoryRow,
    continuation_history: ?[]const ContHistSlot,
    shared_history: ?*const anyopaque,
    out: *HistorySnapshot,
) void {
    out.main_base = main_history;
    out.low_ply_base = low_ply_history;
    out.capture_base = capture_history;
    out.continuation_base = .{ null, null, null, null, null, null };
    if (continuation_history) |ch| {
        for (ch, 0..) |page, slot| out.continuation_base[slot] = page;
    }
    if (shared_history) |sh_ptr| {
        const sh: [*]const u8 = @ptrCast(sh_ptr);
        const pawn_size = @as(*const usize, @ptrCast(@alignCast(sh + 16))).*;
        out.pawn_table = if (pawn_size != 0) @as(*const ?[*]const PawnHistoryRow, @ptrCast(@alignCast(sh + 24))).* else null;
        out.pawn_mask = @as(*const u64, @ptrCast(@alignCast(sh + 40))).*;
    } else {
        out.pawn_table = null;
        out.pawn_mask = 0;
    }
}

pub fn mainHistoryScore(history_snapshot: *const HistorySnapshot, side_to_move: u8, raw_move: u16) c_int {
    const history = history_snapshot.main_base orelse unreachable;
    return history[@as(usize, side_to_move)][@as(usize, raw_move)].value;
}

pub fn lowPlyHistoryScore(history_snapshot: *const HistorySnapshot, ply: c_int, raw_move: u16) c_int {
    const history = history_snapshot.low_ply_base orelse unreachable;
    return history[@as(usize, @intCast(ply))][@as(usize, raw_move)].value;
}

pub fn captureHistoryScore(
    history_snapshot: *const HistorySnapshot,
    piece: u8,
    square: u8,
    captured_piece_type: u8,
) c_int {
    const history = history_snapshot.capture_base orelse unreachable;
    return history[@as(usize, piece)][@as(usize, square)][@as(usize, captured_piece_type)].value;
}

pub fn continuationHistoryScore(
    history_snapshot: *const HistorySnapshot,
    slot: usize,
    piece: u8,
    square: u8,
) c_int {
    const history = history_snapshot.continuation_base[slot] orelse unreachable;
    return history[@as(usize, piece)][@as(usize, square)].value;
}

pub fn pawnHistoryScore(
    history_snapshot: *const HistorySnapshot,
    pawn_key: u64,
    piece: u8,
    square: u8,
) c_int {
    const history = history_snapshot.pawn_table orelse return 0;
    // Index pawn history [(pawn_key & mask) * PIECE_NB + piece][square]
    const index: usize = @intCast(pawn_key & history_snapshot.pawn_mask);
    const row_index = index * piece_nb + @as(usize, piece);
    return history[row_index][@as(usize, square)].value;
}

test {
    @import("std").testing.refAllDecls(@This());
}
