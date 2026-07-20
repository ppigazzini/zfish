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
const captureStage = search_common.captureStage;
const moveIsOk = search_common.moveIsOk;
const sharedOf = shared_history.sharedOf;
const pawnEntryRow = shared_history.pawnEntryRow;
const corrBundle = shared_history.corrBundle;
const moveFrom = board_core.moveFrom;
const moveTo = board_core.moveTo;
const pieceTypeOn = board_core.pieceTypeOn;

const sq_none = board_core.sq_none;

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

// Set up the do_move / do_null_move continuation-history pointer. Set the Stack's
// continuation_history to &continuationHistory[in_check][capture][pc][to] (a
// PieceToHistory page) and continuation_correction_history to
// &continuationCorrectionHistory[pc][to]. The null move and the
// iterative_deepening sentinels pass all-zero indices (NO_PIECE), which resolve
// to the table bases.
pub fn setContHist(worker_ptr: *WorkerLayout, ss_ptr: *SearchStack, in_check: u8, capture: u8, pc: u8, to: u8) void {
    const w: *WorkerHistories = workerHistories(worker_ptr);
    const ss = ss_ptr;
    const ch_block = (@as(usize, in_check) * 2 + capture) * hist_pieceto +
        @as(usize, pc) * hist_square_nb + to;
    ss.continuation_history = @ptrCast(&sharedOf(w).cont_data[ch_block * hist_pieceto]);
    const cc_block = @as(usize, pc) * hist_square_nb + to;
    ss.continuation_correction_history =
        @ptrCast(&w.continuation_correction_history[cc_block * hist_pieceto]);
}

// Decay the main history per iterative_deepening() iteration: v * 729 / 1024
// toward zero over the whole table.
pub fn ageMainHistory(worker_ptr: *WorkerLayout) void {
    const w: *WorkerHistories = workerHistories(worker_ptr);
    for (&w.main_history) |*e| {
        const v: i32 = e.*;
        e.* = @intCast(@divTrunc(v * 729, 1024)); // upstream 3c858c19e: drop the +5
    }
}

// Reset lowPlyHistory per iterative_deepening() search: lowPlyHistory.fill(102)
// over the whole [5][65536] table.
pub fn fillLowPlyHistory(worker_ptr: *WorkerLayout) void {
    const w: *WorkerHistories = workerHistories(worker_ptr);
    for (&w.low_ply_history) |*e| e.* = 102;
}

// Clear the Worker: reset the per-Worker histories (the shared correction/pawn/continuation
// clear_range is handled separately by clearSharedHistory for its numa partitioning, and the
// NNUE refreshTable is untouched). mainHistory=-5, captureHistory=-742, ttMoveHistory=0,
// continuationCorrectionHistory=5. continuationHistory (=-586) is shared, cleared there.
pub fn clearWorkerHistories(wl: *WorkerLayout) void {
    const w: *WorkerHistories = workerHistories(wl);
    for (&w.main_history) |*e| e.* = -5;
    for (&w.capture_history) |*e| e.* = -742;
    w.tt_move_history = 0;
    for (&w.continuation_correction_history) |*e| e.* = 5;
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
    statsUpdate(main_entry, bonus, 7183);
    if (lowply_entry) |e| statsUpdate(e, search.quietLowPlyScale(bonus), 7183);
    updateContinuationHistories(ss_ptr, pc, to, search.quietContScale(bonus));
    statsUpdate(pawn_entry, search.quietPawnScale(bonus), 8192);
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
            statsUpdate(entry, delta, 30000);
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
        statsUpdate(ce, @divTrunc(bonus * 1427, 1024), 10692);
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
        statsUpdate(ce, @divTrunc(-malus * 1489, 1024), 10692);
    }
}

const correction_history_limit: i32 = 1024;

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

    const pawn_entry = &corrBundle(shared, pos.st.pawn_key)[us].pawn;
    const minor_entry = &corrBundle(shared, pos.st.minor_piece_key)[us].minor;
    const npw_entry = &corrBundle(shared, pos.st.non_pawn_key[0])[us].nonpawn_white;
    const npb_entry = &corrBundle(shared, pos.st.non_pawn_key[1])[us].nonpawn_black;

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
