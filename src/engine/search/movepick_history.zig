// Provide the move-ordering history heuristics: the typed row/page views over the
// worker's history tables + the per-table read helpers. Pure reads; std only.

const std = @import("std");
const shared_history_types = @import("shared_history_types");
const SharedHistories = shared_history_types.SharedHistories;

const square_nb: usize = 64;
const piece_type_nb: usize = 8;
const piece_nb: usize = 16;

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
// the main search, so keep the length: scoreList unwraps only the slots its kind reads, and
// a bare many-pointer would let qsearch's single slot be read as six.
pub inline fn contHistSlice(arr: anytype) []const ContHistSlot {
    return @as([*]const ContHistSlot, @ptrCast(arr))[0..arr.len];
}

// Resolve the pawn-history block for one position: the PIECE_NB consecutive rows at
// [(pawn_key & mask) * PIECE_NB]. Resolve it ONCE per move list — the key is fixed for
// the whole list — and index the block per move with pawnHistoryRead.
pub fn pawnHistoryBlock(shared_history: ?*const SharedHistories, pawn_key: u64) ?[*]const PawnHistoryRow {
    const sh = shared_history orelse return null;
    if (sh.pawn_size == 0) return null;
    // View the shared pawn table as rows; the shared side stores it flat.
    const table: [*]const PawnHistoryRow = @ptrCast(sh.pawn_data);
    const index: usize = @intCast(pawn_key & sh.pawn_hist_size_minus1);
    return table + index * piece_nb;
}

pub fn pawnHistoryRead(block: ?[*]const PawnHistoryRow, piece: u8, square: u8) i32 {
    const rows = block orelse return 0;
    // Relaxed: the pawn table is shared by every worker and written concurrently by statsUpdate.
    return @atomicLoad(i16, &rows[@as(usize, piece)][@as(usize, square)].value, .monotonic);
}

pub fn continuationHistoryRead(page: [*]const PieceToHistoryRow, piece: u8, square: u8) i32 {
    // Relaxed-atomic load: continuationHistory is shared across a node's workers (upstream's
    // PieceToHistory is AtomicStats), so this read races the atomic statsUpdate writes.
    return @atomicLoad(i16, &page[@as(usize, piece)][@as(usize, square)].value, .monotonic);
}

test {
    @import("std").testing.refAllDecls(@This());
}
