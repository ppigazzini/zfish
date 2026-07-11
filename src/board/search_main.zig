// The main alpha-beta search, split out of search_driver.zig. searchImpl
// recurses on itself and dives into qsearchImpl (search_qsearch) at depth 0;
// it never calls the iterative-deepening driver or the worker-start glue, so
// it is a one-way leaf. iterativeDeepening (search_id_loop) imports it.

const std = @import("std");
const graph_layout = @import("graph_layout");
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
const move_do = @import("move_do");
const shared_history = @import("shared_history");
const search_common = @import("search_common");
const workerHistories = search_common.workerHistories;
const captureStage = search_common.captureStage;
const moveIsOk = search_common.moveIsOk;
const statsUpdate = search_common.statsUpdate;
const captVal = search_common.captVal;
const captEntry = search_common.captEntry;
const history_mod = @import("history");
pub const updateQuietHistoriesWorker = history_mod.updateQuietHistoriesWorker;
pub const setContHist = history_mod.setContHist;
pub const updateContinuationHistories = history_mod.updateContinuationHistories;
pub const updateAllStats = history_mod.updateAllStats;
pub const updateCorrectionHistory = history_mod.updateCorrectionHistory;
const Position = position_types.Position;
const StateInfo = position_types.StateInfo;
const SearchStack = search_types.SearchStack;
const WorkerHistories = worker_histories.WorkerHistories;
const pawn_pt = board_core.pawn_pt;
const mt_promotion = board_core.mt_promotion;
const moveFrom = board_core.moveFrom;
const moveTo = board_core.moveTo;
const moveTypeOf = board_core.moveTypeOf;
const hist_uint16 = worker_histories.hist_uint16;
const doNullMove = move_do.doNullMove;
const undoNullMove = move_do.undoNullMove;
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
const pawnEntryRow = shared_history.pawnEntryRow;
const sv = @import("search_values.zig");
const q_value_draw = sv.value_draw;
const q_value_none = sv.value_none;
const q_value_inf = sv.value_inf;
const q_max_ply = sv.max_ply;
const q_depth_unsearched = sv.depth_unsearched;
const q_depth_none = sv.depth_none;
const q_bound_none = sv.bound_none;
const q_bound_upper = sv.bound_upper;
const q_bound_lower = sv.bound_lower;
const q_bound_exact = sv.bound_exact;
const q_mt_promotion = sv.mt_promotion;
const q_piece_value = sv.piece_value;
const qIsValid = sv.isValid;
const qIsWin = sv.isWin;
const qIsLoss = sv.isLoss;
const qIsDecisive = sv.isDecisive;
const qMatedIn = sv.matedIn;
const qMateIn = sv.mateIn;
pub const PVMoves = search_types.PVMoves;
const search_emit = @import("search_emit");
const searchCbRootOnIter = search_emit.searchCbRootOnIter;
const QCtx = search_ctx.QCtx;
const updateSelDepth = search_acc.updateSelDepth;
const reductionAcc = search_acc.reductionAcc;
const evaluateAcc = search_acc.evaluateAcc;
const doMoveAcc = search_acc.doMoveAcc;
const undoMoveAcc = search_acc.undoMoveAcc;
const verifyDoMove = search_acc.verifyDoMove;
const verifyUndoMove = search_acc.verifyUndoMove;
const search_control = @import("search_control.zig");
const checkTime = search_control.checkTime;
const rootUpdate = search_control.rootUpdate;
const rootTtMove = search_control.rootTtMove;
const rootInList = search_control.rootInList;
const searchStopped = search_control.searchStopped;
const inLastIterPv = search_control.inLastIterPv;
const lmr_divisor = [16]c_int{ 3307, 2930, 2874, 2818, 3215, 3225, 3224, 2782, 2858, 2919, 3088, 3275, 3180, 2868, 3006, 3599 };
const search_qsearch = @import("search_qsearch.zig");
pub const isShuffling = search_qsearch.isShuffling;
const pvClear = search_qsearch.pvClear;
const pvUpdate = search_qsearch.pvUpdate;
const qCorrectionValue = search_qsearch.qCorrectionValue;
const adjustKey50 = search_qsearch.adjustKey50;
const qsearchImpl = search_qsearch.qsearchImpl;
const posCapture = search_qsearch.posCapture;
const ssAdd = search_qsearch.ssAdd;
const ssSub = search_qsearch.ssSub;
const ttMoveHistoryUpdate = search_qsearch.ttMoveHistoryUpdate;
const contVal = search_qsearch.contVal;

pub fn searchImpl(ctx: *const QCtx, pos_ptr: *Position, ss_ptr: *SearchStack, alpha_in: c_int, beta_in: c_int, depth_in: c_int, cut_node: bool, pv_node: bool, root_node: bool) c_int {
    const all_node = !(pv_node or cut_node);

    // Dive into qsearch at depth 0.
    if (depth_in <= 0) return qsearchImpl(ctx, pos_ptr, ss_ptr, alpha_in, beta_in, pv_node);

    const w: *WorkerHistories = workerHistories(ctx.worker);
    const pos = pos_ptr;
    const ss = ss_ptr;
    const ss1 = ssSub(ss, 1);
    const ss2 = ssSub(ss, 2);

    var alpha = alpha_in;
    var beta = beta_in;
    var depth = @min(depth_in, q_max_ply - 1);

    // Upcoming-repetition draw (non-root).
    if (!root_node and alpha < q_value_draw and upcomingRepetition(pos_ptr, ss.ply)) {
        alpha = search.valueDraw(ctx.nodes.*);
        if (alpha >= beta) return alpha;
    }

    var pv: PVMoves = undefined;
    var st: StateInfo = undefined;

    // Step 1. Initialize node.
    ss.in_check = pos.st.checkers_bb != 0;
    const prior_capture = pos.st.captured_piece != 0;
    const us = pos.side_to_move;
    ss.move_count = 0;
    var best_value: c_int = -q_value_inf;
    const max_value: c_int = q_value_inf;

    ss.follow_pv = root_node or (ss1.follow_pv and inLastIterPv(ctx, ss.ply - 1, ss1.current_move));

    checkTime(ctx);

    if (pv_node) updateSelDepth(ctx, ss.ply);

    if (!root_node) {
        // Step 2. Aborted search / immediate draw / max ply.
        if (searchStopped(ctx) or isDraw(pos_ptr, ss.ply) or ss.ply >= q_max_ply) {
            if (ss.ply >= q_max_ply and !ss.in_check) return evaluateAcc(ctx, pos_ptr);
            return search.valueDraw(ctx.nodes.*);
        }

        // Step 3. Mate distance pruning.
        alpha = @max(qMatedIn(ss.ply), alpha);
        beta = @min(qMateIn(ss.ply + 1), beta);
        if (alpha >= beta) return alpha;
    }

    const prev_sq: c_int = if (moveIsOk(ss1.current_move)) @intCast(moveTo(ss1.current_move)) else @as(c_int, sq_none);
    var best_move: u16 = 0;
    const prior_reduction = ss1.reduction;
    ss1.reduction = 0;
    ss.stat_score = 0;
    ssAdd(ss, 2).cutoff_cnt = 0;

    // Step 4. Transposition-table lookup.
    const excluded_move = ss.excluded_move;
    const pos_key = adjustKey50(pos);
    const probe = tt.probeTable(ctx.table, ctx.cluster_count, pos_key, ctx.generation, q_depth_none);
    const tt_hit = probe.found != 0;
    ss.tt_hit = tt_hit;
    const tt_move: u16 = if (root_node) rootTtMove(ctx) else if (tt_hit) probe.data.move16 else 0;
    const tt_value: c_int = if (tt_hit) search.valueFromTt(probe.data.value16, ss.ply, pos.st.rule50) else q_value_none;
    const tt_depth: c_int = probe.data.depth;
    const tt_bound: u8 = probe.data.bound;
    const tt_eval: c_int = probe.data.eval16;
    const tt_is_pv = tt_hit and probe.data.is_pv != 0;
    ss.tt_pv = if (excluded_move != 0) ss.tt_pv else (pv_node or tt_is_pv);
    const tt_capture = tt_move != 0 and captureStage(pos, tt_move);
    const writer = probe.writer_ptr.?;

    // Step 5. Static evaluation.
    var unadjusted_static_eval: c_int = q_value_none;
    const correction_value = qCorrectionValue(w, pos, ss);
    var eval: c_int = undefined;
    if (ss.in_check) {
        ss.static_eval = ss2.static_eval;
        eval = ss2.static_eval;
    } else if (excluded_move != 0) {
        unadjusted_static_eval = ss.static_eval;
        eval = ss.static_eval;
    } else if (ss.tt_hit) {
        unadjusted_static_eval = tt_eval;
        if (!qIsValid(unadjusted_static_eval)) unadjusted_static_eval = evaluateAcc(ctx, pos_ptr);
        ss.static_eval = search.toCorrectedStaticEval(unadjusted_static_eval, correction_value);
        eval = ss.static_eval;
        if (qIsValid(tt_value) and (tt_bound & (if (tt_value > eval) q_bound_lower else q_bound_upper)) != 0)
            eval = tt_value;
    } else {
        unadjusted_static_eval = evaluateAcc(ctx, pos_ptr);
        ss.static_eval = search.toCorrectedStaticEval(unadjusted_static_eval, correction_value);
        eval = ss.static_eval;
        tt.entrySave(writer, pos_key, q_value_none, @intFromBool(ss.tt_pv), q_bound_none, q_depth_unsearched, q_depth_none, 0, unadjusted_static_eval, ctx.generation);
    }

    var improving = ss.static_eval > ss2.static_eval;
    const opponent_worsening = ss.static_eval > -ss1.static_eval;

    // Hindsight reduction adjustments.
    if (prior_reduction >= 3 and !opponent_worsening) depth += 1;
    if (prior_reduction >= 2 and depth >= 2 and ss.static_eval + ss1.static_eval > 173) depth -= 1;

    // Early TT cutoff (non-PV).
    if (!pv_node and excluded_move == 0 and tt_depth > depth - @as(c_int, @intFromBool(tt_value <= beta)) and
        qIsValid(tt_value) and (tt_bound & (if (tt_value >= beta) q_bound_lower else q_bound_upper)) != 0 and
        (cut_node == (tt_value >= beta) or depth > 4))
    {
        if (tt_move != 0 and tt_value >= beta) {
            if (!tt_capture)
                updateQuietHistoriesWorker(ctx.worker, pos_ptr, ss_ptr, tt_move, @min(114 * depth, 724)); // upstream 73826352d
            if (prev_sq != @as(c_int, sq_none) and ss1.move_count < 4 and !prior_capture)
                updateContinuationHistories(ss1, pos.board[@intCast(prev_sq)], @intCast(prev_sq), -2187);
        }
        if (pos.st.rule50 < 96) {
            if (depth >= 7 and tt_move != 0 and pseudoLegal(pos_ptr, tt_move) and legal(pos_ptr, tt_move) and !qIsDecisive(tt_value)) {
                verifyDoMove(pos_ptr, tt_move, &st);
                const next_key = adjustKey50(pos);
                const probe_next = tt.probeTable(ctx.table, ctx.cluster_count, next_key, ctx.generation, q_depth_none);
                verifyUndoMove(pos_ptr, tt_move);
                const next_value: c_int = probe_next.data.value16;
                if (!qIsValid(next_value)) return tt_value;
                if ((tt_value >= beta) == (-next_value >= beta)) return tt_value;
            } else return tt_value;
        }
    }
    // upstream 319d61eff: no cutoff, but if a window-bound mismatch is the only reason, penalize the
    // now-useless tte (decrement its stored depth).
    else if (!pv_node and excluded_move == 0 and
        tt_depth > depth - @as(c_int, @intFromBool(tt_value <= beta)) and
        qIsValid(tt_value) and tt_bound != (q_bound_lower | q_bound_upper) and
        (tt_bound & (if (tt_value >= beta) q_bound_upper else q_bound_lower)) != 0 and depth > 5)
    {
        tt.entryPenalize(writer, 1);
    }

    // Step 6. Tablebases: cardinality is 0 in this build; skipped.

    if (!ss.in_check) {
        // Static-eval-difference quiet ordering.
        if (moveIsOk(ss1.current_move) and !ss1.in_check and !prior_capture) {
            const eval_diff = search.evalDiff(ss1.static_eval, ss.static_eval);
            statsUpdate(&w.main_history[@as(usize, us ^ 1) * hist_uint16 + ss1.current_move], eval_diff * 10, 7183);
            if (!tt_hit and (pos.board[@intCast(prev_sq)] & 7) != pawn_pt and moveTypeOf(ss1.current_move) != q_mt_promotion) {
                const psq: u8 = @intCast(prev_sq);
                const row = pawnEntryRow(sharedOf(w), pos);
                statsUpdate(&row[@as(usize, pos.board[psq]) * 64 + psq], eval_diff * 13, 8192);
            }
        }

        // Step 7. Razoring.
        if (!pv_node and eval < alpha - search.razorMargin(depth))
            return qsearchImpl(ctx, pos_ptr, ss_ptr, alpha, beta, false);

        // Step 8. Futility pruning.
        if (!ss.tt_pv and depth < 17 and eval >= beta and (tt_move == 0 or tt_capture) and !qIsLoss(beta) and !qIsWin(eval)) {
            const fm = search.futilityMargin(depth, ss.tt_hit, improving, opponent_worsening, correction_value);
            if (eval - fm >= beta) return search.futilityReturn(beta, eval);
        }

        // Step 9. Null-move search.
        if (cut_node and ss.static_eval >= search.nullMoveThreshold(beta, depth, improving) and
            excluded_move == 0 and pos.st.non_pawn_material[us] != 0 and ss.ply >= ctx.nmp_min_ply.* and !qIsLoss(beta))
        {
            const r = search.nullMoveReduction(depth);
            // Worker::do_null_move, inlined: null moves touch no accumulator, so
            // call the Zig-owned pos.do_null_move, mark the stack move as null
            // (Move::null() == 65), and set the all-NO_PIECE continuation-history
            // pointer -- the work the removed cb_do_null_move callback did.
            doNullMove(pos_ptr, &st);
            ss.current_move = 65;
            setContHist(ctx.worker, ss_ptr, 0, 0, 0, 0);
            const null_value = -searchImpl(ctx, pos_ptr, ssAdd(ss, 1), -beta, -beta + 1, depth - r, false, false, false);
            undoNullMove(pos_ptr);
            if (null_value >= beta and !qIsWin(null_value)) {
                if (ctx.nmp_min_ply.* != 0 or depth < 16) return null_value;
                ctx.nmp_min_ply.* = search.nmpMinPly(ss.ply, depth, r);
                const v = searchImpl(ctx, pos_ptr, ss_ptr, beta - 1, beta, depth - r, false, false, false);
                ctx.nmp_min_ply.* = 0;
                if (v >= beta) return null_value;
            }
        }

        if (ss.static_eval >= beta) improving = true;

        // Step 10. Internal iterative reductions.
        if (!ss.follow_pv and !all_node and depth >= 6 and tt_move == 0) depth -= 1; // upstream b1053e60b: drop priorReduction<=3

        // Step 11. ProbCut.
        const probcut_beta = search.probCutBeta(beta, improving);
        if (depth >= 3 and !qIsDecisive(beta) and !(qIsValid(tt_value) and tt_value < probcut_beta)) {
            var mp_moves2: [256]movepick.SortEntry = undefined;
            var pc_state = movepick.MovePickerState{
                .tt_move_raw = tt_move,
                .stage = movepick.initProbcutStage(tt_move != 0 and captureStage(pos, tt_move) and pseudoLegal(pos_ptr, tt_move)),
                .threshold = probcut_beta - ss.static_eval,
                .depth = 0,
                .skip_quiets = 0,
                .cur = 0,
                .end_cur = 0,
                .end_bad_captures = 0,
                .end_captures = 0,
                .end_generated = 0,
                .moves = &mp_moves2,
            };
            const pc_ctx = movepick.MovePickerContext{
                .pos = pos_ptr,
                .main_history = null,
                .low_ply_history = null,
                .capture_history = @ptrCast(&w.capture_history),
                .continuation_history = null,
                .shared_history = null,
                .ply = 0,
            };
            const probcut_depth = depth - 4 - @as(c_int, @intFromBool(improving)); // upstream d64835051
            while (true) {
                const move = movepick.nextMove(&pc_state, &pc_ctx);
                if (move == 0) break;
                if (move == excluded_move or !legal(pos_ptr, move)) continue;
                doMoveAcc(ctx, pos_ptr, move, &st, @intFromBool(givesCheck(pos_ptr, move)), ss_ptr);
                var value = -qsearchImpl(ctx, pos_ptr, ssAdd(ss, 1), -probcut_beta, -probcut_beta + 1, false);
                if (value >= probcut_beta and probcut_depth > 0)
                    value = -searchImpl(ctx, pos_ptr, ssAdd(ss, 1), -probcut_beta, -probcut_beta + 1, probcut_depth, !cut_node, false, false);
                undoMoveAcc(ctx, pos_ptr, move);
                if (value >= probcut_beta) {
                    tt.entrySave(writer, pos_key, search.valueToTt(value, ss.ply), @intFromBool(ss.tt_pv), q_bound_lower, probcut_depth + 1, q_depth_none, move, unadjusted_static_eval, ctx.generation);
                    if (!qIsDecisive(value)) return value - (probcut_beta - beta);
                }
            }
        }
    }

    // moves_loop:
    // Step 12. Deep-probcut TT idea.
    const probcut_beta2 = search.probCutBetaDeep(beta);
    if ((tt_bound & q_bound_lower) != 0 and tt_depth >= depth - 4 and tt_value >= probcut_beta2 and
        !qIsDecisive(beta) and qIsValid(tt_value) and !qIsDecisive(tt_value)) return probcut_beta2;

    // contHist[6] = {(ss-1)..(ss-6)}.continuation_history.
    var cont_hist = [6]?*const worker_histories.PieceToHistory{
        ss1.continuation_history,          ssSub(ss, 2).continuation_history,
        ssSub(ss, 3).continuation_history, ssSub(ss, 4).continuation_history,
        ssSub(ss, 5).continuation_history, ssSub(ss, 6).continuation_history,
    };

    var mp_moves: [256]movepick.SortEntry = undefined;
    var mp_state = movepick.MovePickerState{
        .tt_move_raw = tt_move,
        .stage = movepick.initMainStage(pos.st.checkers_bb != 0, tt_move != 0 and pseudoLegal(pos_ptr, tt_move), depth),
        .threshold = 0,
        .depth = depth,
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

    var value: c_int = best_value;
    var move_count: c_int = 0;
    var quiets_searched: [32]u16 = undefined;
    var n_quiets: usize = 0;
    var captures_searched: [32]u16 = undefined;
    var n_captures: usize = 0;

    // Step 13. Move loop.
    while (true) {
        const move = movepick.nextMove(&mp_state, &mp_ctx);
        if (move == 0) break;
        if (move == excluded_move) continue;
        if (!legal(pos_ptr, move)) continue;
        if (root_node and !rootInList(ctx, move)) continue;

        move_count += 1;
        ss.move_count = move_count;

        if (root_node and ctx.nodes.* > 10_000_000)
            searchCbRootOnIter(ctx.worker, depth, move, move_count);

        if (pv_node) ssAdd(ss, 1).pv = null;

        var extension: c_int = 0;
        const capture = captureStage(pos, move);
        const moved_piece = pos.board[moveFrom(move)];
        const to = moveTo(move);
        const gc = givesCheck(pos_ptr, move);

        var new_depth = depth - 1;
        const delta = beta - alpha;
        var r = reductionAcc(ctx, improving, depth, move_count, delta);
        if (ss.tt_pv) r += 1006;

        // Step 14. Shallow-depth pruning.
        if (!root_node and pos.st.non_pawn_material[us] != 0 and !qIsLoss(best_value)) {
            if (move_count >= search.moveCountLimit(depth, improving)) mp_state.skip_quiets = 1;
            var lmr_depth = new_depth - @divTrunc(r, 1024);
            if (capture or gc) {
                const captured = pos.board[to];
                const capt_hist = captVal(w, moved_piece, to, captured & 7);
                if (!gc and lmr_depth < 7) {
                    const fv = search.captureFutilityValue(ss.static_eval, lmr_depth, q_piece_value[captured], capt_hist);
                    if (fv <= alpha) continue;
                }
                const margin = search.captureSeeMargin(depth, capt_hist);
                if ((alpha >= q_value_draw or pos.st.non_pawn_material[us] != q_piece_value[moved_piece]) and !seeGe(pos_ptr, move, -margin)) continue;
            } else if (!ss.follow_pv or !pv_node) {
                const d_index: usize = @intCast(@min(depth, @as(c_int, lmr_divisor.len)) - 1);
                var history = contVal(cont_hist[0], moved_piece, to) + contVal(cont_hist[1], moved_piece, to) +
                    pawnEntryRow(sharedOf(w), pos)[@as(usize, moved_piece) * 64 + to];
                if (history < search.historyPruneThreshold(depth)) continue;
                history += @divTrunc(64 * @as(c_int, w.main_history[@as(usize, us) * hist_uint16 + move]), 32);
                lmr_depth += @divTrunc(history, lmr_divisor[d_index]);
                const fv = search.quietFutilityValue(ss.static_eval, best_move == 0, lmr_depth, ss.static_eval > alpha);
                if (!ss.in_check and lmr_depth < 12 and fv <= alpha) {
                    if (best_value <= fv and !qIsDecisive(best_value) and !qIsWin(fv)) best_value = fv;
                    continue;
                }
                if (lmr_depth < 0) lmr_depth = 0;
                if (!seeGe(pos_ptr, move, -search.quietSeeMargin(lmr_depth))) continue;
            }
        }

        // Step 15. Extensions (singular).
        if (!root_node and move == tt_move and excluded_move == 0 and depth >= 6 + @as(c_int, @intFromBool(ss.tt_pv)) and
            qIsValid(tt_value) and !qIsDecisive(tt_value) and (tt_bound & q_bound_lower) != 0 and
            tt_depth >= depth - 3 and !isShuffling(pos_ptr, ss_ptr, move))
        {
            const singular_beta = search.singularBeta(tt_value, ss.tt_pv and !pv_node, depth);
            const singular_depth = @divTrunc(new_depth, 2);
            ss.excluded_move = move;
            value = searchImpl(ctx, pos_ptr, ss_ptr, singular_beta - 1, singular_beta, singular_depth, cut_node, false, false);
            ss.excluded_move = 0;
            if (value < singular_beta) {
                const ply_gt_root = ss.ply > ctx.root_depth.*;
                const double_margin = search.singularDoubleMargin(pv_node, !tt_capture, correction_value, w.tt_move_history, ply_gt_root);
                const triple_margin = search.singularTripleMargin(pv_node, !tt_capture, ss.tt_pv, correction_value, ply_gt_root);
                extension = 1 + @as(c_int, @intFromBool(value < singular_beta - double_margin)) + @as(c_int, @intFromBool(value < singular_beta - triple_margin));
                depth += 1;
            } else if (value >= beta and !qIsDecisive(value)) {
                ttMoveHistoryUpdate(w, search.ttMoveHistoryDepthBonus(depth));
                return value;
            } else if (tt_value >= beta) {
                extension = -3;
            } else if (cut_node) {
                extension = -2;
            }
        }

        const node_count: u64 = if (root_node) ctx.nodes.* else 0;

        // Step 16. Make the move.
        doMoveAcc(ctx, pos_ptr, move, &st, @intFromBool(gc), ss_ptr);
        new_depth += extension;

        if (ss.tt_pv)
            r -= search.lmrTtpvReduction(pv_node, tt_value > alpha, tt_depth >= depth, cut_node);
        r += 714;
        r -= move_count * 62;
        r -= search.lmrCorrReduction(correction_value);
        if (cut_node) r += 3995 + 1059 * @as(c_int, @intFromBool(tt_move == 0));
        if (ssAdd(ss, 1).cutoff_cnt > 1) {
            r += 236 + 1079 * @as(c_int, @intFromBool(ssAdd(ss, 1).cutoff_cnt > 2)) + 1143 * @as(c_int, @intFromBool(all_node));
        } else if (move == tt_move) {
            r = @max(@as(c_int, 0), r - 2016); // upstream 3c858c19e: simplify ttMove reduction
        }
        if (tt_capture) r += 1039;

        if (capture)
            ss.stat_score = search.captureStatScore(q_piece_value[pos.st.captured_piece], captVal(w, moved_piece, to, pos.st.captured_piece & 7))
        else
            ss.stat_score = search.quietStatScore(w.main_history[@as(usize, us) * hist_uint16 + move], contVal(cont_hist[0], moved_piece, to), contVal(cont_hist[1], moved_piece, to));

        r -= search.lmrStatScoreReduction(ss.stat_score);
        if (all_node) r += search.lmrAllNodeScale(r, depth);

        // Step 17/18. LMR + full-depth search.
        if (depth >= 2 and move_count > 1) {
            const d = @max(@as(c_int, 1), @min(new_depth - @divTrunc(r, 1024), new_depth + 2)) + @as(c_int, @intFromBool(pv_node));
            ss.reduction = new_depth - d;
            value = -searchImpl(ctx, pos_ptr, ssAdd(ss, 1), -(alpha + 1), -alpha, d, true, false, false);
            ss.reduction = 0;
            if (value > alpha) {
                const do_deeper = d < new_depth and value > best_value + 52;
                const do_shallower = value < best_value + 9;
                new_depth += @as(c_int, @intFromBool(do_deeper)) - @as(c_int, @intFromBool(do_shallower));
                if (new_depth > d)
                    value = -searchImpl(ctx, pos_ptr, ssAdd(ss, 1), -(alpha + 1), -alpha, new_depth, !cut_node, false, false);
                updateContinuationHistories(ss, moved_piece, to, 1415);
            }
        } else if (!pv_node or move_count > 1) {
            if (tt_move == 0) r += 1085;
            value = -searchImpl(ctx, pos_ptr, ssAdd(ss, 1), -(alpha + 1), -alpha, new_depth - @as(c_int, @intFromBool(r > 5039)) - @as(c_int, @intFromBool(r > 5223 and new_depth > 2)), !cut_node, false, false);
        }

        if (pv_node and (move_count == 1 or value > alpha)) {
            ssAdd(ss, 1).pv = &pv;
            pvClear(&pv);
            if (move == tt_move and ((qIsValid(tt_value) and qIsDecisive(tt_value) and tt_depth > 0) or tt_depth > 1))
                new_depth = @max(new_depth, 1);
            value = -searchImpl(ctx, pos_ptr, ssAdd(ss, 1), -beta, -alpha, new_depth, false, true, false);
        }

        // Step 19. Undo move.
        undoMoveAcc(ctx, pos_ptr, move);

        // Step 20. Check for a new best move.
        if (searchStopped(ctx)) return q_value_draw;

        if (root_node) {
            // (ss+1)->pv is only valid (non-null) when this move ran a PV search,
            // i.e. move_count == 1 or value > alpha; otherwise it is ignored.
            const cpv: ?*const PVMoves = if (move_count == 1 or value > alpha) ssAdd(ss, 1).pv.? else null;
            rootUpdate(ctx, move, value, ctx.nodes.* - node_count, move_count, alpha, beta, cpv);
        }

        const av = if (value < 0) -value else value;
        const inc: c_int = @intFromBool(value == best_value and ss.ply + 2 >= ctx.root_depth.* and (@as(c_int, @intCast(ctx.nodes.* & 14)) == 0) and !qIsWin(av + 1));
        if (value + inc > best_value) {
            best_value = value;
            if (value + inc > alpha) {
                best_move = move;
                // (ss+1)->pv is only set (1913) when this move ran a PV re-search;
                // if a rare best-move update fires without one it stays null, and
                // pvUpdate takes the child PV as optional (null -> PV is just the
                // move). Force-unwrapping it here was a latent null-deref (silent
                // under ReleaseFast, panics under ReleaseSafe/Debug).
                if (pv_node and !root_node) {
                    const child_pv = ssAdd(ss, 1).pv;
                    pvUpdate(ss.pv.?, move, child_pv);
                }
                if (value >= beta) {
                    ss.cutoff_cnt += @intFromBool(extension < 2 or pv_node);
                    break;
                }
                if (depth > 2 and depth < 13 and !qIsDecisive(value)) depth -= 2;
                alpha = value;
            }
        }

        if (move != best_move and move_count <= 32) {
            if (capture) {
                captures_searched[n_captures] = move;
                n_captures += 1;
            } else {
                quiets_searched[n_quiets] = move;
                n_quiets += 1;
            }
        }
    }

    // Step 21. Mate / stalemate / fail-high adjust.
    if (best_value >= beta and !qIsDecisive(best_value) and !qIsDecisive(alpha))
        best_value = @divTrunc(best_value * depth + beta, depth + 1);

    if (move_count == 0) {
        best_value = if (excluded_move != 0) alpha else if (ss.in_check) qMatedIn(ss.ply) else q_value_draw;
    } else if (best_move != 0) {
        updateAllStats(ctx.worker, pos_ptr, ss_ptr, best_move, prev_sq, &quiets_searched, n_quiets, &captures_searched, n_captures, depth, tt_move, @intFromBool(pv_node));
        if (!pv_node) ttMoveHistoryUpdate(w, search.ttMoveHistoryMatchBonus(best_move == tt_move));
    } else if (!prior_capture and prev_sq != @as(c_int, sq_none)) {
        const psq: u8 = @intCast(prev_sq);
        const bonus_scale = search.priorBonusScale(ss1.stat_score, depth, ss1.move_count > 8, !ss.in_check and best_value <= ss.static_eval - 103, !ss1.in_check and best_value <= -ss1.static_eval - 78);
        const scaled_bonus = search.priorScaledBonusBase(depth) * bonus_scale;
        updateContinuationHistories(ss1, pos.board[psq], psq, search.priorConthistScale(scaled_bonus));
        statsUpdate(&w.main_history[@as(usize, us ^ 1) * hist_uint16 + ss1.current_move], search.priorMainhistScale(scaled_bonus), 7183);
        if ((pos.board[psq] & 7) != pawn_pt and moveTypeOf(ss1.current_move) != q_mt_promotion) {
            const row = pawnEntryRow(sharedOf(w), pos);
            statsUpdate(&row[@as(usize, pos.board[psq]) * 64 + psq], search.priorPawnhistScale(scaled_bonus), 8192);
        }
    } else if (prior_capture and prev_sq != @as(c_int, sq_none)) {
        const psq: u8 = @intCast(prev_sq);
        statsUpdate(captEntry(w, pos.board[psq], psq, pos.st.captured_piece & 7), 901, 10692);
    }

    if (pv_node) best_value = @min(best_value, max_value);

    if (best_value <= alpha) ss.tt_pv = ss.tt_pv or ss1.tt_pv;

    if (excluded_move == 0 and !(root_node and ctx.pv_idx.* != 0)) {
        const bound: u8 = if (best_value >= beta) q_bound_lower else if (pv_node and best_move != 0) q_bound_exact else q_bound_upper;
        const wdepth: c_int = if (move_count != 0) depth else @min(q_max_ply - 1, depth + 6);
        tt.entrySave(writer, pos_key, search.valueToTt(best_value, ss.ply), @intFromBool(ss.tt_pv), bound, wdepth, q_depth_none, best_move, unadjusted_static_eval, ctx.generation);
    }

    // Adjust correction history.
    if (!ss.in_check and !(best_move != 0 and posCapture(pos, best_move)) and (best_value > ss.static_eval) == (best_move != 0)) {
        updateCorrectionHistory(ctx.worker, pos_ptr, ss_ptr, search.correctionHistoryBonus(best_value - ss.static_eval, depth, best_move != 0));
    }

    return best_value;
}
