// Quiescence search + the PV/low-level primitives shared with the main search.
// qsearchImpl is a call-graph leaf (only self-recurses, never calls
// searchImpl); the shared primitives (isShuffling/pvClear/pvUpdate/
// qCorrectionValue/adjustKey50/ssAdd/ssSub/posCapture/ttMoveHistoryUpdate/
// contVal) live here.

const std = @import("std");
const graph_layout = @import("graph_layout");
const movegen = @import("movegen");
const tt = @import("tt");
const movepick = @import("movepick");
const search = @import("search");
const worker_histories = @import("worker_histories");
const position_types = @import("position_types");
const search_types = @import("search_types");
const search_ctx = @import("search_ctx");
const search_acc = @import("search_acc");
const board_core = @import("board_core");
const legality = @import("legality");
const repetition = @import("repetition");
const shared_history = @import("shared_history");
const search_common = @import("search_common");
const workerHistories = search_common.workerHistories;
const captureStage = search_common.captureStage;
const moveIsOk = search_common.moveIsOk;
const statsUpdate = search_common.statsUpdate;
const Position = position_types.Position;
const StateInfo = position_types.StateInfo;
const SearchStack = search_types.SearchStack;
const WorkerHistories = worker_histories.WorkerHistories;
const pawn_pt = board_core.pawn_pt;
const knight_pt = board_core.knight_pt;
const color_white = board_core.color_white;
const mt_promotion = board_core.mt_promotion;
const mt_en_passant = board_core.mt_en_passant;
const mt_castling = board_core.mt_castling;
const moveFrom = board_core.moveFrom;
const moveTo = board_core.moveTo;
const moveTypeOf = board_core.moveTypeOf;
const upcomingRepetition = repetition.upcomingRepetition;
const isDraw = repetition.isDraw;
const legal = legality.legal;
const seeGe = legality.seeGe;
const pseudoLegal = legality.pseudoLegal;
const givesCheck = legality.givesCheck;
const sq_none: u8 = 64;
comptime {
    // graph_layout.WorkerLayout uses opaque byte regions for these position-module
    // sub-blocks; assert its sizes match the real structs so worker_off stays correct.
    std.debug.assert(graph_layout.worker_histories_bytes == @sizeOf(WorkerHistories));
    std.debug.assert(graph_layout.position_size == @sizeOf(Position));
    std.debug.assert(graph_layout.state_info_size == @sizeOf(StateInfo));
}
const sharedOf = shared_history.sharedOf;
const corrBundle = shared_history.corrBundle;
const sv = @import("search_values.zig");
const q_value_draw = sv.value_draw;
const q_value_none = sv.value_none;
const q_value_inf = sv.value_inf;
const q_max_ply = sv.max_ply;
const q_depth_qs = sv.depth_qs;
const q_depth_unsearched = sv.depth_unsearched;
const q_depth_none = sv.depth_none;
const q_bound_upper = sv.bound_upper;
const q_bound_lower = sv.bound_lower;
const q_mt_promotion = sv.mt_promotion;
const q_piece_value = sv.piece_value;
const qIsValid = sv.isValid;
const qIsLoss = sv.isLoss;
const qIsDecisive = sv.isDecisive;
const qMatedIn = sv.matedIn;
pub const PVMoves = search_types.PVMoves;
const QCtx = search_ctx.QCtx;
const updateSelDepth = search_acc.updateSelDepth;
const evaluateAcc = search_acc.evaluateAcc;
const doMoveAcc = search_acc.doMoveAcc;
const undoMoveAcc = search_acc.undoMoveAcc;

pub fn isShuffling(pos: *const Position, ss: *const SearchStack, move: u16) bool {
    if (captureStage(pos, move) or pos.st.rule50 < 10) return false;
    if (pos.st.plies_from_null < 6 or ss.ply < 20) return false;
    const ss2: *const SearchStack = @ptrFromInt(@intFromPtr(ss) - 2 * @sizeOf(SearchStack));
    const ss4: *const SearchStack = @ptrFromInt(@intFromPtr(ss) - 4 * @sizeOf(SearchStack));
    return moveFrom(move) == moveTo(ss2.current_move) and
        moveFrom(ss2.current_move) == moveTo(ss4.current_move);
}

pub inline fn pvClear(pv: *PVMoves) void {
    pv.length = 0;
}

pub fn pvUpdate(pv: *PVMoves, move: u16, child: ?*PVMoves) void {
    const n: usize = if (child) |c| c.length else 0;
    if (child) |c| {
        var i: usize = 0;
        while (i < n) : (i += 1) pv.moves[i + 1] = c.moves[i];
    }
    pv.moves[0] = move;
    pv.length = n + 1;
}

pub fn qCorrectionValue(w: *WorkerHistories, pos: *const Position, ss: *SearchStack) c_int {
    const shared = sharedOf(w);
    const us = pos.side_to_move;
    const pcv: c_int = corrBundle(shared, pos.st.pawn_key)[us].pawn;
    const micv: c_int = corrBundle(shared, pos.st.minor_piece_key)[us].minor;
    const wnpcv: c_int = corrBundle(shared, pos.st.non_pawn_key[0])[us].nonpawn_white;
    const bnpcv: c_int = corrBundle(shared, pos.st.non_pawn_key[1])[us].nonpawn_black;
    const ss1: *SearchStack = @ptrFromInt(@intFromPtr(ss) - @sizeOf(SearchStack));
    const m = ss1.current_move;
    var cch2: c_int = 0;
    var cch4: c_int = 0;
    const m_ok = moveIsOk(m);
    if (m_ok) {
        const to = moveTo(m);
        const idx = @as(usize, pos.board[to]) * 64 + to;
        const ss2: *SearchStack = @ptrFromInt(@intFromPtr(ss) - 2 * @sizeOf(SearchStack));
        const ss4: *SearchStack = @ptrFromInt(@intFromPtr(ss) - 4 * @sizeOf(SearchStack));
        const cc2 = ss2.continuation_correction_history.?;
        const cc4 = ss4.continuation_correction_history.?;
        cch2 = cc2[idx];
        cch4 = cc4[idx];
    }
    return search.correctionValue(pcv, micv, wnpcv, bnpcv, cch2, cch4, m_ok);
}

pub inline fn adjustKey50(pos: *const Position) u64 {
    const k = pos.st.key;
    if (pos.st.rule50 < 14) return k;
    const seed: u64 = @intCast(@divTrunc(pos.st.rule50 - 14, 8));
    return k ^ (seed *% 6364136223846793005 +% 1442695040888963407);
}

pub fn qsearchImpl(ctx: *const QCtx, pos_ptr: *Position, ss_ptr: *SearchStack, alpha_in: c_int, beta: c_int, pv_node: bool) c_int {
    const w: *WorkerHistories = workerHistories(ctx.worker);
    const pos = pos_ptr;
    const ss = ss_ptr;
    const ss1: *SearchStack = @ptrFromInt(@intFromPtr(ss) - @sizeOf(SearchStack));
    const ss_next: *SearchStack = @ptrFromInt(@intFromPtr(ss) + @sizeOf(SearchStack));
    var alpha = alpha_in;

    // Upcoming-repetition draw.
    if (alpha < q_value_draw and upcomingRepetition(pos_ptr, ss.ply)) {
        alpha = search.valueDraw(ctx.nodes.*);
        if (alpha >= beta) return alpha;
    }

    var pv: PVMoves = undefined;
    var st: StateInfo = undefined;

    var best_move: u16 = 0;
    ss.in_check = pos.st.checkers_bb != 0;
    var move_count: c_int = 0;

    // Step 1. Initialize node (PV).
    if (pv_node) {
        ss_next.pv = &pv;
        pvClear(ss.pv.?);
        updateSelDepth(ctx, ss.ply);
    }

    // Step 2. Immediate draw or max ply.
    if (isDraw(pos_ptr, ss.ply) or ss.ply >= q_max_ply) {
        if (ss.ply >= q_max_ply and !ss.in_check) return evaluateAcc(ctx, pos_ptr);
        return q_value_draw;
    }

    // Step 3. Transposition-table lookup.
    const pos_key = adjustKey50(pos);
    const probe = tt.probeTable(ctx.table, ctx.cluster_count, pos_key, ctx.generation, q_depth_none);
    const tt_hit = probe.found != 0;
    ss.tt_hit = tt_hit;
    const tt_move: u16 = if (tt_hit) probe.data.move16 else 0;
    const tt_value: c_int = if (tt_hit) search.valueFromTt(probe.data.value16, ss.ply, pos.st.rule50) else q_value_none;
    const tt_depth: c_int = probe.data.depth;
    const tt_bound: u8 = probe.data.bound;
    const tt_eval: c_int = probe.data.eval16;
    const pv_hit = tt_hit and probe.data.is_pv != 0;
    const writer = probe.writer_ptr.?;

    if (!pv_node and tt_depth >= q_depth_qs and qIsValid(tt_value) and
        (tt_bound & (if (tt_value >= beta) q_bound_lower else q_bound_upper)) != 0)
        return tt_value;

    // Step 4. Static evaluation.
    var unadjusted_static_eval: c_int = q_value_none;
    var best_value: c_int = undefined;
    var futility_base: c_int = -q_value_inf;
    if (ss.in_check) {
        best_value = -q_value_inf;
    } else {
        const correction_value = qCorrectionValue(w, pos, ss);
        if (ss.tt_hit) {
            unadjusted_static_eval = tt_eval;
            if (!qIsValid(unadjusted_static_eval))
                unadjusted_static_eval = evaluateAcc(ctx, pos_ptr);
            ss.static_eval = search.toCorrectedStaticEval(unadjusted_static_eval, correction_value);
            best_value = ss.static_eval;
            if (qIsValid(tt_value) and !qIsDecisive(tt_value) and
                (tt_bound & (if (tt_value > best_value) q_bound_lower else q_bound_upper)) != 0)
                best_value = tt_value;
        } else {
            unadjusted_static_eval = evaluateAcc(ctx, pos_ptr);
            ss.static_eval = search.toCorrectedStaticEval(unadjusted_static_eval, correction_value);
            best_value = ss.static_eval;
        }

        // Stand pat.
        if (best_value >= beta) {
            if (!qIsDecisive(best_value)) best_value = search.qsearchStandPatBlend(best_value, beta);
            if (!ss.tt_hit)
                tt.entrySave(writer, pos_key, q_value_none, 0, q_bound_lower, q_depth_unsearched, q_depth_none, 0, unadjusted_static_eval, ctx.generation);
            return best_value;
        }
        if (best_value > alpha) alpha = best_value;
        futility_base = search.qsearchFutilityBase(ss.static_eval);
    }

    var cont_hist = [1]?*const worker_histories.PieceToHistory{ss1.continuation_history};
    const prev_sq: c_int = if (moveIsOk(ss1.current_move)) @intCast(moveTo(ss1.current_move)) else @as(c_int, sq_none);

    // Step 5. MovePicker (captures, or evasions when in check).
    var mp_moves: [256]movepick.SortEntry = undefined;
    const has_checkers = pos.st.checkers_bb != 0;
    const tt_pseudo = tt_move != 0 and pseudoLegal(pos_ptr, tt_move);
    var mp_state = movepick.MovePickerState{
        .tt_move_raw = tt_move,
        .stage = movepick.initMainStage(has_checkers, tt_pseudo, q_depth_qs),
        .threshold = 0,
        .depth = q_depth_qs,
        .skip_quiets = 0,
        .cur = 0,
        .end_cur = 0,
        .end_bad_captures = 0,
        .end_captures = 0,
        .end_generated = 0,
        .moves = &mp_moves,
    };
    const mp_ctx = movepick.MovePickerContext{
        .pos = pos_ptr,
        .main_history = @ptrCast(&w.main_history),
        .low_ply_history = @ptrCast(&w.low_ply_history),
        .capture_history = @ptrCast(&w.capture_history),
        .continuation_history = @ptrCast(&cont_hist),
        .shared_history = w.shared_history,
        .ply = ss.ply,
    };

    while (true) {
        const move = movepick.nextMove(&mp_state, &mp_ctx);
        if (move == 0) break;

        if (!legal(pos_ptr, move)) continue;

        const gc = givesCheck(pos_ptr, move);
        const capture = captureStage(pos, move);
        move_count += 1;

        // Step 6. Pruning.
        if (!qIsLoss(best_value)) {
            if (!gc and @as(c_int, moveTo(move)) != prev_sq and !qIsLoss(futility_base) and
                moveTypeOf(move) != q_mt_promotion)
            {
                if (move_count > 2) continue;
                const futility_value = futility_base + q_piece_value[pos.board[moveTo(move)]];
                if (futility_value <= alpha) {
                    if (futility_value > best_value) best_value = futility_value;
                    continue;
                }
                if (!seeGe(pos_ptr, move, alpha - futility_base)) {
                    const cap = if (alpha < futility_base) alpha else futility_base;
                    if (cap > best_value) best_value = cap;
                    continue;
                }
            }
            if (!capture) continue;
            if (!seeGe(pos_ptr, move, -74)) continue;
        }

        // Step 7. Make and search the move.
        doMoveAcc(ctx, pos_ptr, move, &st, @intFromBool(gc), ss_ptr);
        const value = -qsearchImpl(ctx, pos_ptr, ss_next, -beta, -alpha, pv_node);
        undoMoveAcc(ctx, pos_ptr, move);

        // Step 8. New best move.
        if (value > best_value) {
            best_value = value;
            if (value > alpha) {
                best_move = move;
                if (pv_node) pvUpdate(ss.pv.?, move, ss_next.pv.?);
                if (value < beta) alpha = value else break;
            }
        }
    }

    // Step 9. Mate / stalemate.
    if (move_count == 0) {
        if (ss.in_check) return qMatedIn(ss.ply);
        const us = pos.side_to_move;
        const pawns = pos.by_color_bb[us] & pos.by_type_bb[pawn_pt];
        const pushed = if (us == color_white) pawns << 8 else pawns >> 8;
        if ((pushed & ~pos.by_type_bb[0]) == 0 and pos.st.non_pawn_material[us] == 0 and
            (pos.st.captured_piece & 7) >= knight_pt)
        {
            var lbuf: [256]u16 = undefined;
            if (movegen.generateLegal(pos_ptr, &lbuf) == 0) best_value = q_value_draw;
        }
    }

    if (!qIsDecisive(best_value) and best_value > beta)
        best_value = search.qsearchFailHighBlend(best_value, beta);

    // Save to the transposition table.
    tt.entrySave(writer, pos_key, search.valueToTt(best_value, ss.ply), @intFromBool(pv_hit), if (best_value >= beta) q_bound_lower else q_bound_upper, q_depth_qs, q_depth_none, best_move, unadjusted_static_eval, ctx.generation);

    return best_value;
}

pub inline fn posCapture(pos: *const Position, m: u16) bool {
    const t = moveTypeOf(m);
    return (pos.board[moveTo(m)] != 0 and t != mt_castling) or t == mt_en_passant;
}

pub inline fn ssAdd(ss: *SearchStack, n: usize) *SearchStack {
    return @ptrFromInt(@intFromPtr(ss) + n * @sizeOf(SearchStack));
}

pub inline fn ssSub(ss: *SearchStack, n: usize) *SearchStack {
    return @ptrFromInt(@intFromPtr(ss) - n * @sizeOf(SearchStack));
}

pub inline fn ttMoveHistoryUpdate(w: *WorkerHistories, bonus: c_int) void {
    statsUpdate(&w.tt_move_history, bonus, 8192);
}

pub inline fn contVal(ss_ch: ?*const worker_histories.PieceToHistory, pc: u8, to: u8) c_int {
    return ss_ch.?[@as(usize, pc) * 64 + to];
}
