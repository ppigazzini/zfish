// COMPONENT: treat search_main.zig + search_back.zig as ONE component, deliberately.
//
// Form the file graph's only import cycle (searchImpl <-> runBack), and treat it as
// not a layering defect to be fixed: it IS the alpha-beta recursion. searchImpl runs
// a node's Steps 1-12, hands the node state to search_back's move loop (Steps 13-21),
// and that loop recurses back into searchImpl for each child. Read the cycle as the
// algorithm; splitting the file did not split the recursion. Per Lakos, answer a
// legitimate cycle by NAMING the component, not breaking it -- so do not "fix"
// this by inverting an import or threading a function pointer. That would buy nothing
// and cost an optimizer barrier on the hottest path in the engine.
//
// `zig build arch-report` lists this SCC as KNOWN, deliberately: a NEW file
// cycle shows up as UNDECLARED and fails the gate, instead of hiding behind the one
// everybody has learned to ignore.
//
// Run the main alpha-beta search. searchImpl recurses on itself and dives into
// qsearchImpl (search_qsearch) at depth 0; it never calls the
// iterative-deepening driver or the worker-start glue. iterativeDeepening
// (search_id_loop) imports it.

const std = @import("std");
const worker_layout = @import("worker_layout");
const tt = @import("tt");
const movepick = @import("movepick");
const search = @import("search");
const worker_histories = @import("worker_histories");
const position_types = @import("position_types");
const search_types = @import("search_types");
const search_ctx = @import("search_ctx");
const search_acc = @import("search_acc");
const tb_source = @import("tb_source");
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
const sq_none = board_core.sq_none;
comptime {
    // Assert the opaque byte regions worker_layout.WorkerLayout uses for these
    // position-module sub-blocks match the real struct sizes so worker_off stays correct.
    std.debug.assert(worker_layout.worker_histories_bytes == @sizeOf(WorkerHistories));
    std.debug.assert(worker_layout.position_size == @sizeOf(Position));
    std.debug.assert(worker_layout.state_info_size == @sizeOf(StateInfo));
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

/// Mirror upstream `template<NodeType> search<Root>/<PV>/<NonPV>(..., bool cutNode)`: the node
/// type is comptime, `cut_node` is runtime. Carry the comptime fields into `search_back.runBack`
/// through its `nd: anytype`, specialising it per node type as well.
pub fn searchImpl(ctx: *const QCtx, pos_ptr: *Position, ss_ptr: *SearchStack, alpha_in: c_int, beta_in: c_int, depth_in: c_int, cut_node: bool, comptime pv_node: bool, comptime root_node: bool) c_int {
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

    // Detect the upcoming-repetition draw (non-root).
    if (!root_node and alpha < q_value_draw and upcomingRepetition(pos_ptr, ss.ply)) {
        alpha = search.valueDraw(ctx.nodes.*);
        if (alpha >= beta) return alpha;
    }

    var st: StateInfo = undefined;

    // Step 1. Initialize node.
    ss.in_check = pos.st.checkers_bb != 0;
    const prior_capture = pos.st.captured_piece != 0;
    const us = pos.side_to_move;
    ss.move_count = 0;
    var best_value: c_int = -q_value_inf;
    var max_value: c_int = q_value_inf;

    ss.follow_pv = root_node or (ss1.follow_pv and inLastIterPv(ctx, ss.ply - 1, ss1.current_move));

    checkTime(ctx);

    if (pv_node) updateSelDepth(ctx, ss.ply);

    if (!root_node) {
        // Step 2. Bail on aborted search / immediate draw / max ply.
        if (searchStopped(ctx) or isDraw(pos_ptr, ss.ply) or ss.ply >= q_max_ply) {
            if (ss.ply >= q_max_ply and !ss.in_check) return evaluateAcc(ctx, pos_ptr);
            return search.valueDraw(ctx.nodes.*);
        }

        // Step 3. Prune by mate distance.
        alpha = @max(qMatedIn(ss.ply), alpha);
        beta = @min(qMateIn(ss.ply + 1), beta);
        if (alpha >= beta) return alpha;
    }

    const prev_sq: c_int = if (moveIsOk(ss1.current_move)) @intCast(moveTo(ss1.current_move)) else @as(c_int, sq_none);
    const prior_reduction = ss1.reduction;
    ss1.reduction = 0;
    ss.stat_score = 0;
    ssAdd(ss, 2).cutoff_cnt = 0;

    // Step 4. Look up the transposition table.
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

    // Step 5. Compute the static evaluation.
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

    // Apply the hindsight reduction adjustments.
    if (prior_reduction >= 3 and !opponent_worsening) depth += 1;
    if (prior_reduction >= 2 and depth >= 2 and ss.static_eval + ss1.static_eval > 173) depth -= 1;

    // Cut off early on the TT (non-PV).
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
    // upstream 319d61eff: take no cutoff, but if a window-bound mismatch is the only reason, penalize the
    // now-useless tte (decrement its stored depth).
    else if (!pv_node and excluded_move == 0 and
        tt_depth > depth - @as(c_int, @intFromBool(tt_value <= beta)) and
        qIsValid(tt_value) and tt_bound != (q_bound_lower | q_bound_upper) and
        (tt_bound & (if (tt_value >= beta) q_bound_upper else q_bound_lower)) != 0 and depth > 5)
    {
        tt.entryPenalize(writer, 1);
    }

    // Step 6. Probe the tablebases. Port SF search.cpp faithfully: probe the WDL of the current
    // (non-root, non-excluded) position when it is small enough, has a zeroed rule50 counter, and
    // no castling rights; on success score it in the VALUE_TB..VALUE_TB_WIN range and cut/adjust.
    // Gate on the worker's tb_config.cardinality, which is 0 without a SyzygyPath, so a default
    // build (and bench) never enters here and the node count is unchanged.
    if (!root_node and excluded_move == 0) {
        const tb_cfg = &ctx.worker.tb_config;
        const cardinality: c_int = @as(*const c_int, @ptrCast(@alignCast(&tb_cfg[0]))).*;
        if (cardinality != 0) {
            const pieces_count: c_int = @popCount(pos.by_type_bb[0]);
            const probe_depth: c_int = @as(*const c_int, @ptrCast(@alignCast(&tb_cfg[8]))).*;
            if (pieces_count <= cardinality and
                (pieces_count < cardinality or depth >= probe_depth) and
                pos.st.rule50 == 0 and pos.st.castling_rights == 0)
            {
                const res = tb_source.probeWdlPos(pos_ptr);
                if (res.available != 0) {
                    ctx.worker.tb_hits += 1;
                    const draw_score: c_int = if (tb_cfg[5] != 0) 1 else 0;
                    const tb_value: c_int = sv.value_tb - ss.ply;
                    const wdl = res.wdl;
                    const value: c_int = if (wdl < -draw_score)
                        -tb_value
                    else if (wdl > draw_score)
                        tb_value
                    else
                        q_value_draw + 2 * wdl * draw_score;
                    const b: u8 = if (wdl < -draw_score)
                        q_bound_upper
                    else if (wdl > draw_score)
                        q_bound_lower
                    else
                        q_bound_exact;
                    if (b == q_bound_exact or (if (b == q_bound_lower) value >= beta else value <= alpha)) {
                        tt.entrySave(writer, pos_key, search.valueToTt(value, ss.ply), @intFromBool(ss.tt_pv), b, @min(q_max_ply - 1, depth + 6), q_depth_none, 0, q_value_none, ctx.generation);
                        return value;
                    }
                    if (pv_node) {
                        if (b == q_bound_lower) {
                            best_value = value;
                            alpha = @max(alpha, best_value);
                        } else {
                            max_value = value;
                        }
                    }
                }
            }
        }
    }

    if (!ss.in_check) {
        // Order quiets by static-eval difference.
        if (moveIsOk(ss1.current_move) and !ss1.in_check and !prior_capture) {
            const eval_diff = search.evalDiff(ss1.static_eval, ss.static_eval);
            statsUpdate(&w.main_history[@as(usize, us ^ 1) * hist_uint16 + ss1.current_move], eval_diff * 10, 7183);
            if (!tt_hit and (pos.board[@intCast(prev_sq)] & 7) != pawn_pt and moveTypeOf(ss1.current_move) != q_mt_promotion) {
                const psq: u8 = @intCast(prev_sq);
                const row = pawnEntryRow(sharedOf(w), pos);
                statsUpdate(&row[@as(usize, pos.board[psq]) * 64 + psq], eval_diff * 13, 8192);
            }
        }

        // Step 7. Apply razoring.
        if (!pv_node and eval < alpha - search.razorMargin(depth))
            return qsearchImpl(ctx, pos_ptr, ss_ptr, alpha, beta, false);

        // Step 8. Prune by futility.
        if (!ss.tt_pv and depth < 17 and eval >= beta and (tt_move == 0 or tt_capture) and !qIsLoss(beta) and !qIsWin(eval)) {
            const fm = search.futilityMargin(depth, ss.tt_hit, improving, opponent_worsening, correction_value);
            if (eval - fm >= beta) return search.futilityReturn(beta, eval);
        }

        // Step 9. Search the null move.
        if (cut_node and ss.static_eval >= search.nullMoveThreshold(beta, depth, improving) and
            excluded_move == 0 and pos.st.non_pawn_material[us] != 0 and ss.ply >= ctx.nmp_min_ply.* and !qIsLoss(beta))
        {
            const r = search.nullMoveReduction(depth);
            // Touch no accumulator for null moves: call pos.do_null_move, mark the
            // stack move as null (65), and set the all-NO_PIECE
            // continuation-history pointer.
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

        // Step 10. Apply internal iterative reductions.
        if (!ss.follow_pv and !all_node and depth >= 6 and tt_move == 0) depth -= 1; // upstream b1053e60b: drop priorReduction<=3

        // Step 11. Run ProbCut.
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
    // Step 12. Apply the deep-probcut TT idea.
    const probcut_beta2 = search.probCutBetaDeep(beta);
    if ((tt_bound & q_bound_lower) != 0 and tt_depth >= depth - 4 and tt_value >= probcut_beta2 and
        !qIsDecisive(beta) and qIsValid(tt_value) and !qIsDecisive(tt_value)) return probcut_beta2;

    return @import("search_back.zig").runBack(.{
        .ctx = ctx,
        .pos_ptr = pos_ptr,
        .ss_ptr = ss_ptr,
        .pos = pos,
        .ss = ss,
        .ss1 = ss1,
        .w = w,
        .us = us,
        .alpha = alpha,
        .beta = beta,
        .depth = depth,
        .best_value = best_value,
        .excluded_move = excluded_move,
        .tt_move = tt_move,
        .tt_value = tt_value,
        .tt_depth = tt_depth,
        .tt_bound = tt_bound,
        .tt_capture = tt_capture,
        .correction_value = correction_value,
        .cut_node = cut_node,
        .pv_node = pv_node,
        .root_node = root_node,
        .all_node = all_node,
        .improving = improving,
        .unadjusted_static_eval = unadjusted_static_eval,
        .writer = writer,
        .pos_key = pos_key,
        .max_value = max_value,
        .prev_sq = prev_sq,
        .prior_capture = prior_capture,
    });
}
