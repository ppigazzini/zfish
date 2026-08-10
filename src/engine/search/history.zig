// Update the history tables.
//
// Gather the functions that WRITE the per-Worker + shared history tables after a search
// node: the quiet/continuation/capture main-history updates (updateAllStats), the
// correction-history nudges (updateCorrectionHistory), the continuation-history
// pointer setup (setContHist), and the per-iteration/per-search decays + clears.
// Draw the storage layer from shared_history, the shared low-level helpers from
// search_common, and the tuning scales from the search module.

const search = @import("search");
const worker_layout = @import("worker_layout");
const search_common = @import("search_common");
const shared_history = @import("shared_history");
const worker_histories = @import("worker_histories");
const search_types = @import("search_types");
const position_types = @import("position_types");
const board_core = @import("board_core");

const WorkerHistories = worker_histories.WorkerHistories;
const WorkerLayout = worker_layout.WorkerLayout;
const Position = position_types.Position;
const SearchStack = search_types.SearchStack;
const hist_uint16 = worker_histories.hist_uint16;
const hist_square_nb = worker_histories.hist_square_nb;
const hist_pieceto = worker_histories.hist_pieceto;
const workerHistories = search_common.workerHistories;
const statsUpdate = search_common.statsUpdate;
const main_history_limit = search_common.main_history_limit;
const low_ply_history_limit = search_common.low_ply_history_limit;
const pawn_history_limit = search_common.pawn_history_limit;
const capture_history_limit = search_common.capture_history_limit;
const continuation_history_limit = search_common.continuation_history_limit;
const captureStage = search_common.captureStage;
const moveIsOk = search_common.moveIsOk;
const sharedOf = shared_history.sharedOf;
const fillI16Slice = shared_history.fillI16Slice;

// Lane count for the main-history decay: 32 i16 in, two 512-bit i32 halves through the scale
// and divide. Tuned for the tier it was measured on -- re-measure before changing it.
const age_lanes = 32;
const pawnEntryRow = shared_history.pawnEntryRow;
const pawnCorrEntry = shared_history.pawnCorrEntry;
const minorCorrEntry = shared_history.minorCorrEntry;
const whiteNonPawnCorrEntry = shared_history.whiteNonPawnCorrEntry;
const blackNonPawnCorrEntry = shared_history.blackNonPawnCorrEntry;
const moveFrom = board_core.moveFrom;
const moveTo = board_core.moveTo;
const pieceTypeOn = board_core.pieceTypeOn;

const sq_none = board_core.sq_none;

// Upstream's NO_PIECE and SQ_A1, the two the base continuation plane is addressed by.
const no_piece: u8 = 0;
const sq_a1: u8 = 0;

pub fn updateQuietHistoriesWorker(
    worker_ptr: *WorkerLayout,
    pos_ptr: *const Position,
    ss_ptr: *const SearchStack,
    move: u16,
    bonus: i32,
) void {
    const w: *WorkerHistories = workerHistories(worker_ptr);
    const pos = pos_ptr;
    const ss = ss_ptr;
    const raw: usize = move;
    const main_entry = &w.main_history[@as(usize, pos.side_to_move) * hist_uint16 + raw];
    var lowply_entry: ?*i16 = null;
    if (ss.ply < 5) // LOW_PLY_HISTORY_SIZE
        lowply_entry = &w.low_ply_history[@as(usize, @intCast(ss.ply)) * hist_uint16 + raw];
    const pc = pos.board[moveFrom(move)];
    const to = moveTo(move);
    const pawn_entry = &pawnEntryRow(sharedOf(w), pos)[@as(usize, pc) * hist_square_nb + to];
    updateQuietHistories(main_entry, lowply_entry, pawn_entry, ss_ptr, pc, to, bonus);
}

/// Name the two plane selectors, so they cannot be handed over in the other order.
///
/// They were adjacent `u8`s, and a swap does not fault: it selects a DIFFERENT PLANE of the
/// continuation table -- a valid entry of the wrong thing. Nothing downstream can notice,
/// because every plane holds the same shape of counter; only the bench signature moves, and
/// it says that something changed, never what. These are the arguments, not the result: the
/// page the function stores was already a distinct pointer type and that stopped nothing here.
///
/// Backed by `u8` and used only to index, so `@intFromEnum` is the value that was already
/// being passed -- this is the accessor-typing case, not the "type a quantity that is computed
/// with" case the cost rule refutes (see docs/09-type-design.md).
/// Construct through `of`, never through a bare `.yes` / `.no`. An enum LITERAL infers its
/// type from the parameter it lands in, so two `if (c) .yes else .no` arguments still compile
/// after a transposition -- the literal simply adapts. Checked, not assumed: that swap built
/// clean. Naming the type at the call site is what makes the swap a compile error.
pub const InCheck = enum(u8) {
    no = 0,
    yes = 1,
    pub fn of(v: bool) InCheck {
        return if (v) .yes else .no;
    }
};
pub const WasCapture = enum(u8) {
    no = 0,
    yes = 1,
    pub fn of(v: bool) WasCapture {
        return if (v) .yes else .no;
    }
};

// Set up the do_move / do_null_move continuation-history pointer. Set the Stack's
// continuation_history to &continuationHistory[in_check][capture][pc][to] (a
// PieceToHistory page) and continuation_correction_history to
// &continuationCorrectionHistory[pc][to].
pub fn setContHist(worker_ptr: *WorkerLayout, ss_ptr: *SearchStack, in_check: InCheck, capture: WasCapture, pc: u8, to: u8) void {
    const w: *WorkerHistories = workerHistories(worker_ptr);
    const ss = ss_ptr;
    const ch_block = (@as(usize, @intFromEnum(in_check)) * 2 + @intFromEnum(capture)) * hist_pieceto +
        @as(usize, pc) * hist_square_nb + to;
    ss.continuation_history = @ptrCast(&sharedOf(w).cont_data[ch_block * hist_pieceto]);
    ss.continuation_correction_history =
        @ptrCast(&w.continuation_correction_history[contCorrIndex(pc, to) * hist_pieceto]);
}

/// Index a continuation-correction plane by (piece, destination) -- both the page
/// setContHist selects and, one level in, the element a child's correction read lands on.
/// doMoveAcc prefetches through this same derivation, so the hint cannot drift from the
/// load it hides.
pub fn contCorrIndex(pc: u8, to: u8) usize {
    return @as(usize, pc) * hist_square_nb + to;
}

/// Select the base plane: the one a NO_PIECE "move" to a1 addresses, out of check and not a
/// capture. That is `(0 * 2 + 0) * hist_pieceto + 0 * 64 + 0` -- zero, the table base.
///
/// The null-move path and the pre-root sentinel walk both spelled those four zeroes out, with a
/// comment each explaining which constant they added up to. A name is what a comment was standing
/// in for, and it is also where a reader could not tell which `0` was `in_check` and which was
/// `capture`.
pub fn setContHistBasePlane(worker_ptr: *WorkerLayout, ss_ptr: *SearchStack) void {
    setContHist(worker_ptr, ss_ptr, .no, .no, no_piece, sq_a1);
}

// Decay the main history per iterative_deepening() iteration: v * 729 / 1024
// toward zero over the whole table.
//
// Widen the decay by hand. This is a per-element integer loop over 131072 entries and the
// toolchain will not auto-vectorize one (L13), so the scalar spelling stays one lane per
// iteration for the life of the process. Sign-extend a block of i16 to i32, scale, and
// truncate-divide in registers; @divTrunc by a power of two is the SAME rounding the scalar
// form had (toward zero, not toward -inf), and LLVM lowers the constant divisor to the
// bias-and-arithmetic-shift sequence rather than a real division. The written values are
// bit-identical, so the bench signature holds.
pub fn ageMainHistory(worker_ptr: *WorkerLayout) void {
    const w: *WorkerHistories = workerHistories(worker_ptr);
    const V = age_lanes;
    const Vi16 = @Vector(V, i16);
    const Vi32 = @Vector(V, i32);
    const mul: Vi32 = @splat(729); // upstream 3c858c19e: drop the +5
    const div: Vi32 = @splat(1024);

    const dst: []i16 = &w.main_history;
    var i: usize = 0;
    while (i + V <= dst.len) : (i += V) {
        const src: Vi16 = dst[i..][0..V].*;
        const scaled: Vi32 = @as(Vi32, src) * mul;
        const decayed: Vi16 = @intCast(@divTrunc(scaled, div));
        dst[i..][0..V].* = decayed;
    }
    while (i < dst.len) : (i += 1) {
        const v: i32 = dst[i];
        dst[i] = @intCast(@divTrunc(v * 729, 1024));
    }
}

// Reset lowPlyHistory per iterative_deepening() search: lowPlyHistory.fill(102)
// over the whole [5][65536] table.
pub fn fillLowPlyHistory(worker_ptr: *WorkerLayout) void {
    const w: *WorkerHistories = workerHistories(worker_ptr);
    fillI16Slice(&w.low_ply_history, 102);
}

// Clear the Worker: reset the per-Worker histories (the shared correction/pawn/continuation
// clear_range is handled separately by clearSharedHistory for its numa partitioning, and the
// NNUE refreshTable is untouched). mainHistory=-5, captureHistory=-742, ttMoveHistory=0,
// continuationCorrectionHistory=5. continuationHistory (=-586) is shared, cleared there.
// Each table's default is a non-zero int16, so none of these is a byte-pattern @memset and a
// scalar `e.* = v` loop stays scalar (L13) -- fillI16Slice broadcast-stores them instead. The
// Worker owns these tables outright at clear time, so the stores need no atomics.
pub fn clearWorkerHistories(wl: *WorkerLayout) void {
    const w: *WorkerHistories = workerHistories(wl);
    fillI16Slice(&w.main_history, -5);
    fillI16Slice(&w.capture_history, -742);
    w.tt_move_history = 0;
    fillI16Slice(&w.continuation_correction_history, 5);
}

// Find captureStage / moveIsOk / statsUpdate / captVal / captEntry / workerHistories
// in the search_common leaf, shared with the history-update code.

// Own the bonus scaling + gravity update sequence; the caller resolves the table
// lookups (mainHistory[us][move], lowPlyHistory, sharedHistory.pawn_entry) and hands
// this the int16 entry pointers.
pub fn updateQuietHistories(
    main_entry: *i16,
    lowply_entry: ?*i16,
    pawn_entry: *i16,
    ss_ptr: *const SearchStack,
    pc: u8,
    to: u8,
    bonus: i32,
) void {
    statsUpdate(main_entry, bonus, main_history_limit);
    if (lowply_entry) |e| statsUpdate(e, search.quietLowPlyScale(bonus), low_ply_history_limit);
    updateContinuationHistories(ss_ptr, pc, to, search.quietContScale(bonus));
    statsUpdate(pawn_entry, search.quietPawnScale(bonus), pawn_history_limit);
}

const ConthistBonus = struct { i: u8, w: i32 };
const conthist_bonuses = [6]ConthistBonus{
    .{ .i = 1, .w = 1040 }, .{ .i = 2, .w = 780 }, .{ .i = 3, .w = 290 },
    .{ .i = 4, .w = 502 },  .{ .i = 5, .w = 132 }, .{ .i = 6, .w = 418 },
};

pub fn updateContinuationHistories(ss_ptr: *const SearchStack, pc: u8, to: u8, bonus: i32) void {
    const ss = ss_ptr;
    var positive_count: i32 = 0;
    for (conthist_bonuses) |b| {
        if (ss.in_check and b.i > 2) break;
        const ssi: *SearchStack = @ptrFromInt(@intFromPtr(ss) - @as(usize, b.i) * @sizeOf(SearchStack));
        if (moveIsOk(ssi.current_move)) {
            const cont = ssi.continuation_history.?;
            const entry = &cont[@as(usize, pc) * 64 + to]; // PieceToHistory[pc][to]
            if (@atomicLoad(i16, entry, .monotonic) > 0) positive_count += 1; // shared table: relaxed read
            const delta = search.conthistDelta(bonus, b.w, positive_count, @intCast(b.i));
            statsUpdate(entry, delta, continuation_history_limit);
        }
    }
}

pub fn updateAllStats(
    worker_ptr: *WorkerLayout,
    pos_ptr: *const Position,
    ss_ptr: *const SearchStack,
    best_move: u16,
    prev_sq: i32,
    quiets: [*]const u16,
    n_quiets: usize,
    captures: [*]const u16,
    n_captures: usize,
    depth: i32,
    tt_move: u16,
    pv_node: u8,
) void {
    const w: *WorkerHistories = workerHistories(worker_ptr);
    const pos = pos_ptr;
    const ss = ss_ptr;
    const ss_prev: *SearchStack = @ptrFromInt(@intFromPtr(ss) - @sizeOf(SearchStack));
    const capture_base: [*]i16 = &w.capture_history;

    const is_tt: u8 = if (best_move == tt_move) 1 else 0;
    var bonus = search.statBonus(depth, is_tt != 0, ss_prev.stat_score);
    const malus = search.statMalus(depth);

    // upstream 645b636df: at non-PV nodes, scale the best-move bonus by the number of searched moves.
    // Match upstream's `bonus += bonus * uint64_t(N) / 256` EXACTLY: the mul/div are UNSIGNED (int promoted
    // to uint64_t), which differs from signed when bonus < 0; the u64 sum narrows back to i32.
    if (pv_node == 0) {
        const n: u64 = @intCast(n_quiets + n_captures);
        const bu: u64 = @bitCast(@as(i64, bonus));
        bonus = @bitCast(@as(u32, @truncate(bu +% ((bu *% n) / 256))));
    }

    if (!captureStage(pos, best_move)) {
        updateQuietHistoriesWorker(worker_ptr, pos_ptr, ss_ptr, best_move, @divTrunc(bonus * 899, 1024));
        var actual_malus: i32 = @divTrunc(malus * 1159, 1024);
        var i: usize = 0;
        while (i < n_quiets) : (i += 1) {
            actual_malus = @divTrunc(actual_malus * 921, 1024);
            updateQuietHistoriesWorker(worker_ptr, pos_ptr, ss_ptr, quiets[i], -actual_malus);
        }
    } else {
        const moved_pc = pos.board[moveFrom(best_move)];
        const to = moveTo(best_move);
        const captured_pt = pieceTypeOn(pos, to);
        const ce = &capture_base[@as(usize, moved_pc) * 512 + @as(usize, to) * 8 + captured_pt];
        statsUpdate(ce, @divTrunc(bonus * 1427, 1024), capture_history_limit);
    }

    if (prev_sq != @as(i32, sq_none) and
        ss_prev.move_count == 1 + @as(i32, @intFromBool(ss_prev.tt_hit)) and
        pos.st.captured_piece == 0)
    {
        const psq: u8 = @intCast(prev_sq);
        updateContinuationHistories(ss_prev, pos.board[psq], psq, @divTrunc(-malus * 713, 1024));
    }

    var j: usize = 0;
    while (j < n_captures) : (j += 1) {
        const move = captures[j];
        const moved_pc = pos.board[moveFrom(move)];
        const to = moveTo(move);
        const captured_pt = pieceTypeOn(pos, to);
        const ce = &capture_base[@as(usize, moved_pc) * 512 + @as(usize, to) * 8 + captured_pt];
        statsUpdate(ce, @divTrunc(-malus * 1489, 1024), capture_history_limit);
    }
}

// Single-source the entry bound with the bonus clamps that are meant to be a quarter of
// it (search.zig owns both, being the std-only formula leaf this file already imports).
// Keep the correction limit an `i32`: search.zig divides it by four to derive the two
// bonus clamps, and a quantity that is computed with must not be wrapped. Type the
// clamp VIEW of it instead -- which is the parameter statsUpdate can confuse.
const correction_history_limit: search_common.HistLimit = .{ .v = search.correction_history_limit };

// update_correction_history: nudge the four shared correction tables plus the
// (ss-2)/(ss-4) continuation correction entries toward the search/static-eval
// delta. Resolve all four key-masked, color-indexed correction entries from
// SharedHistories (the Worker pointer gives the shared block) and apply the
// bonus weighting, gravity, and the stack-relative continuation correction writes.
pub fn updateCorrectionHistory(
    worker_ptr: *WorkerLayout,
    pos_ptr: *const Position,
    ss_ptr: *const SearchStack,
    bonus: i32,
) void {
    const w: *WorkerHistories = workerHistories(worker_ptr);
    const pos = pos_ptr;
    const shared = sharedOf(w);
    const us = pos.side_to_move;

    const pawn_entry = pawnCorrEntry(shared, pos, us);
    const minor_entry = minorCorrEntry(shared, pos, us);
    const npw_entry = whiteNonPawnCorrEntry(shared, pos, us);
    const npb_entry = blackNonPawnCorrEntry(shared, pos, us);

    statsUpdate(pawn_entry, bonus, correction_history_limit);
    statsUpdate(minor_entry, @divTrunc(bonus * 150, 128), correction_history_limit);
    statsUpdate(npw_entry, @divTrunc(bonus * 186, 128), correction_history_limit);
    statsUpdate(npb_entry, @divTrunc(bonus * 186, 128), correction_history_limit);

    const ss = ss_ptr;
    const ss_prev: *SearchStack = @ptrFromInt(@intFromPtr(ss) - @sizeOf(SearchStack));
    const m = ss_prev.current_move;
    if (moveIsOk(m)) {
        const to = moveTo(m);
        const pc = pos.board[to];
        const idx = @as(usize, pc) * 64 + to;
        const ss2: *SearchStack = @ptrFromInt(@intFromPtr(ss) - 2 * @sizeOf(SearchStack));
        const ss4: *SearchStack = @ptrFromInt(@intFromPtr(ss) - 4 * @sizeOf(SearchStack));
        const cc2 = ss2.continuation_correction_history.?;
        const cc4 = ss4.continuation_correction_history.?;
        statsUpdate(&cc2[idx], @divTrunc(bonus * 130, 128), correction_history_limit);
        statsUpdate(&cc4[idx], @divTrunc(bonus * 70, 128), correction_history_limit);
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
