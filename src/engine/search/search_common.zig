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
pub inline fn statsUpdate(entry: *i16, bonus: i32, comptime d: i32) void {
    const clamped = @max(-d, @min(d, bonus));
    const val: i32 = entry.*;
    const abs_clamped = if (clamped < 0) -clamped else clamped;
    entry.* = @intCast(val + clamped - @divTrunc(val * abs_clamped, d));
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
