// Provide the shared search/history helpers.
//
// Gather the small accessors and stat primitives used by BOTH the history-update code
// and the search itself: the Worker->histories accessor, the capture-history
// lookups, the StatsEntry gravity update, the capture-stage predicate, and the
// move-validity check.

const worker_layout = @import("worker_layout");
const worker_histories = @import("worker_histories");
const position_types = @import("position_types");
const board_core = @import("board_core");

const WorkerHistories = worker_histories.WorkerHistories;
const Position = position_types.Position;
const moveTo = board_core.moveTo;
const moveTypeOf = board_core.moveTypeOf;
const movePromotionType = board_core.movePromotionType;
const mt_castling = board_core.mt_castling;
const mt_en_passant = board_core.mt_en_passant;
const queen_pt = board_core.queen_pt;

pub inline fn workerHistories(wl: *worker_layout.WorkerLayout) *WorkerHistories {
    return &wl.histories;
}

pub fn captureStage(pos: *const Position, m: u16) bool {
    const cap = (pos.board[moveTo(m)] != 0 and moveTypeOf(m) != mt_castling) or
        moveTypeOf(m) == mt_en_passant;
    return cap or movePromotionType(m) == queen_pt;
}

pub inline fn moveIsOk(m: u16) bool {
    return m != 0 and m != 65; // != none() and != null()
}

// Update by gravity toward [-D, D].
//
// Load and store RELAXED. The pawn and correction tables are shared by every worker, and upstream
// types their slots `RelaxedAtomic<i16>` (history.h:63 via `std::conditional_t<Shared, ...>`) so
// this read-modify-write is a defined relaxed load followed by a relaxed store. A plain access is
// a data race: `val` is read once but used twice, and if the compiler rematerialises the second
// use after a sibling thread's store, the result can leave [-D, D] and trap the @intCast in
// ReleaseSafe -- which is what CI builds.
/// Type the gravity clamp so it cannot be swapped with the bonus beside it.
///
/// The two used to be adjacent `i32`s across every call site, with the clamp a bare
/// literal and five distinct values in use. A transposition does not fail: it clamps by
/// one and divides by the other, so the gravity curve is a different shape and the move
/// ordering changes. Only the bench signature notices, and it says that something moved,
/// never where.
///
/// A one-field struct is what makes the swap unspellable in BOTH directions -- a bare
/// `i32` parameter name would stop nothing, and an enum cannot hold the two pairs of
/// tables whose tunables coincide today. It costs nothing: the parameter is `comptime`,
/// so it occupies no register and the wrapper scalarises completely.
pub const HistLimit = struct { v: i32 };

// One constant per table, mirroring upstream's per-instantiation `Stats<i16, D, ...>`
// (history.h). The two pairs that share a value keep separate names deliberately: they
// are separate upstream tunables that coincide today, and one shared name would make a
// sync moving either one move both.
pub const main_history_limit: HistLimit = .{ .v = 7183 }; // ButterflyHistory
pub const low_ply_history_limit: HistLimit = .{ .v = 7183 }; // LowPlyHistory
pub const pawn_history_limit: HistLimit = .{ .v = 8192 }; // PawnHistory
pub const tt_move_history_limit: HistLimit = .{ .v = 8192 }; // TTMoveHistory
pub const capture_history_limit: HistLimit = .{ .v = 10692 }; // CapturePieceToHistory
pub const continuation_history_limit: HistLimit = .{ .v = 30000 }; // PieceToHistory

pub inline fn statsUpdate(entry: *i16, bonus: i32, comptime limit: HistLimit) void {
    const d = limit.v;
    const clamped = @max(-d, @min(d, bonus));
    const val: i32 = @atomicLoad(i16, entry, .monotonic);
    const abs_clamped = if (clamped < 0) -clamped else clamped;
    @atomicStore(i16, entry, @intCast(val + clamped - @divTrunc(val * abs_clamped, d)), .monotonic);
}

pub inline fn captVal(w: *WorkerHistories, pc: u8, to: u8, captured_type: u8) i32 {
    return w.capture_history[@as(usize, pc) * 512 + @as(usize, to) * 8 + captured_type];
}
pub inline fn captEntry(w: *WorkerHistories, pc: u8, to: u8, captured_type: u8) *i16 {
    return &w.capture_history[@as(usize, pc) * 512 + @as(usize, to) * 8 + captured_type];
}

test {
    @import("std").testing.refAllDecls(@This());
}
