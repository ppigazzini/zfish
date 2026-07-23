// COMPONENT: treat search_back.zig + search_main.zig as ONE component, deliberately.
// Form the other half of the file graph's only import cycle -- the alpha-beta recursion
// itself (runBack <-> searchImpl), not a layering defect. See search_main.zig's
// header for the full rationale; `zig build arch-report` lists this SCC as KNOWN so a
// NEW one cannot hide behind it. Do not break this cycle.
//
// Run the move loop + node finalization (Steps 13-21) of searchImpl. Take the
// pre-loop node state as an anytype `nd` struct (Steps 1-12 invariants); the
// loop's mutable running state + scratch are local here. Recurse into
// search_main.searchImpl for child nodes.

const std = @import("std");
const worker_layout = @import("worker_layout");
const tt = @import("tt");
const movepick = @import("movepick");
const search = @import("search");
const worker_histories = @import("worker_histories");
const position_types = @import("position_types");
const search_types = @import("search_types");
const search_acc = @import("search_acc");
const board_core = @import("board_core");
const legality = @import("legality");
const shared_history = @import("shared_history");
const search_common = @import("search_common");
const captureStage = search_common.captureStage;
const statsUpdate = search_common.statsUpdate;
const captVal = search_common.captVal;
const captEntry = search_common.captEntry;
const history_mod = @import("history");
pub const updateContinuationHistories = history_mod.updateContinuationHistories;
pub const updateAllStats = history_mod.updateAllStats;
pub const updateCorrectionHistory = history_mod.updateCorrectionHistory;
const Position = position_types.Position;
const StateInfo = position_types.StateInfo;
const WorkerHistories = worker_histories.WorkerHistories;
const pawn_pt = board_core.pawn_pt;
const mt_promotion = board_core.mt_promotion;
const moveFrom = board_core.moveFrom;
const moveTo = board_core.moveTo;
const moveTypeOf = board_core.moveTypeOf;
const hist_uint16 = worker_histories.hist_uint16;
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
const q_max_ply = sv.max_ply;
const q_depth_none = sv.depth_none;
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
pub const PVMoves = search_types.PVMoves;
const search_emit = @import("search_emit");
const searchCbRootOnIter = search_emit.searchCbRootOnIter;
const reductionAcc = search_acc.reductionAcc;
const doMoveAcc = search_acc.doMoveAcc;
const undoMoveAcc = search_acc.undoMoveAcc;
const search_control = @import("search_control.zig");
const rootUpdate = search_control.rootUpdate;
const rootInList = search_control.rootInList;
const searchStopped = search_control.searchStopped;
const lmr_divisor = [16]i32{ 3637, 2787, 2761, 2939, 3171, 3347, 3147, 2762, 2772, 3106, 3107, 3060, 3112, 2991, 3090, 3542 };
const search_qsearch = @import("search_qsearch.zig");
pub const isShuffling = search_qsearch.isShuffling;
const pvClear = search_qsearch.pvClear;
const pvUpdate = search_qsearch.pvUpdate;
const posCapture = search_qsearch.posCapture;
const ssAdd = search_qsearch.ssAdd;
const ssSub = search_qsearch.ssSub;
const ttMoveHistoryUpdate = search_qsearch.ttMoveHistoryUpdate;
const contVal = search_qsearch.contVal;

const searchImpl = @import("search_main.zig").searchImpl;

// Inline into searchImpl, restoring upstream's single search<NodeType> function at
// codegen: as a real call, every `nd.*` read in the move loop is a memory load LLVM
// must conservatively repeat (no TBAA), and the ~27-field node-state struct is
// rebuilt per node. Semantic inlining, not speed-by-annotation -- measured
// instructions 0.990 / cycles 0.966 (perf_counters 8-round paired, avx512icl).
pub inline fn runBack(nd: anytype) i32 {
    var alpha = nd.alpha;
    var depth = nd.depth;
    var best_value = nd.best_value;
    var best_move: u16 = 0;
    // Reuse searchImpl's StateInfo and move-sort buffer (nd.st_ptr / nd.mp_moves):
    // their pre-loop uses are complete, and a second live copy of each doubled the
    // per-node frame.
    const st = nd.st_ptr;
    var pv: PVMoves = undefined;

    // Build contHist[6] = {(nd.ss-1)..(nd.ss-6)}.continuation_history.
    var cont_hist = [6]?*const worker_histories.PieceToHistory{
        nd.ss1.continuation_history,          ssSub(nd.ss, 2).continuation_history,
        ssSub(nd.ss, 3).continuation_history, ssSub(nd.ss, 4).continuation_history,
        ssSub(nd.ss, 5).continuation_history, ssSub(nd.ss, 6).continuation_history,
    };

    var mp_state = movepick.MovePickerState{
        .tt_move_raw = nd.tt_move,
        .stage = movepick.initMainStage(nd.pos.st.checkers_bb != 0, nd.tt_move != 0 and pseudoLegal(nd.pos_ptr, nd.tt_move), depth),
        .threshold = 0,
        .depth = depth,
        .skip_quiets = 0,
        .cur = 0,
        .end_cur = 0,
        .end_bad_captures = 0,
        .end_captures = 0,
        .end_generated = 0,
        .moves = nd.mp_moves,
    };
    const mp_ctx = movepick.MovePickerContext{
        .pos = nd.pos_ptr,
        .main_history = @ptrCast(&nd.w.main_history),
        .low_ply_history = @ptrCast(&nd.w.low_ply_history),
        .capture_history = @ptrCast(&nd.w.capture_history),
        .continuation_history = movepick.contHistSlice(&cont_hist),
        .shared_history = nd.w.shared_history,
        .ply = nd.ss.ply,
    };

    var value: i32 = best_value;
    var move_count: i32 = 0;
    var quiets_searched: [32]u16 = undefined;
    var n_quiets: usize = 0;
    var captures_searched: [32]u16 = undefined;
    var n_captures: usize = 0;

    // Step 13. Loop over moves.
    while (true) {
        const move = movepick.nextMove(&mp_state, &mp_ctx);
        if (move == 0) break;
        if (move == nd.excluded_move) continue;
        if (!legal(nd.pos_ptr, move)) continue;
        if (nd.root_node and !rootInList(nd.ctx, move)) continue;

        move_count += 1;
        nd.ss.move_count = move_count;

        if (nd.root_node and nd.ctx.nodes.* > 10_000_000)
            searchCbRootOnIter(nd.ctx.worker, depth, move, move_count);

        if (nd.pv_node) ssAdd(nd.ss, 1).pv = null;

        var extension: i32 = 0;
        const capture = captureStage(nd.pos, move);
        const moved_piece = nd.pos.board[moveFrom(move)];
        const to = moveTo(move);
        const gc = givesCheck(nd.pos_ptr, move);

        var new_depth = depth - 1;
        const delta = nd.beta - alpha;
        var r = reductionAcc(nd.ctx, nd.improving, depth, move_count, delta);
        if (nd.ss.tt_pv) r += 929;

        // Step 14. Prune at shallow depth.
        if (!nd.root_node and nd.pos.st.non_pawn_material[nd.us] != 0 and !qIsLoss(best_value)) {
            if (move_count >= search.moveCountLimit(depth, nd.improving)) mp_state.skip_quiets = 1;
            var lmr_depth = new_depth - @divTrunc(r, 1024);
            if (capture or gc) {
                const captured = nd.pos.board[to];
                const capt_hist = captVal(nd.w, moved_piece, to, captured & 7);
                if (!gc and lmr_depth < 8) {
                    const fv = search.captureFutilityValue(nd.ss.static_eval, lmr_depth, q_piece_value[captured], capt_hist);
                    if (fv <= alpha) continue;
                }
                const margin = search.captureSeeMargin(depth, capt_hist);
                if ((alpha >= q_value_draw or nd.pos.st.non_pawn_material[nd.us] != q_piece_value[moved_piece]) and !seeGe(nd.pos_ptr, move, -margin)) continue;
            } else if (!nd.ss.follow_pv or !nd.pv_node) {
                const d_index: usize = @intCast(@min(depth, @as(i32, lmr_divisor.len)) - 1);
                // Relaxed on the pawn-table read: the row is shared across workers and written
                // concurrently by statsUpdate.
                var history = contVal(cont_hist[0], moved_piece, to) + contVal(cont_hist[1], moved_piece, to) +
                    @atomicLoad(i16, &pawnEntryRow(sharedOf(nd.w), nd.pos)[@as(usize, moved_piece) * 64 + to], .monotonic);
                if (history < search.historyPruneThreshold(depth)) continue;
                history += @divTrunc(69 * @as(i32, nd.w.main_history[@as(usize, nd.us) * hist_uint16 + move]), 32);
                lmr_depth += @divTrunc(history, lmr_divisor[d_index]);
                const fv = search.quietFutilityValue(nd.ss.static_eval, best_move == 0, lmr_depth, nd.ss.static_eval > alpha);
                if (!nd.ss.in_check and lmr_depth < 12 and fv <= alpha) {
                    if (best_value <= fv and !qIsDecisive(best_value) and !qIsWin(fv)) best_value = fv;
                    continue;
                }
                if (lmr_depth < 0) lmr_depth = 0;
                if (!seeGe(nd.pos_ptr, move, -search.quietSeeMargin(lmr_depth))) continue;
            }
        }

        // Step 15. Extend (singular).
        if (!nd.root_node and move == nd.tt_move and nd.excluded_move == 0 and depth >= 6 + @as(i32, @intFromBool(nd.ss.tt_pv)) and
            qIsValid(nd.tt_value) and !qIsDecisive(nd.tt_value) and (nd.tt_bound & q_bound_lower) != 0 and
            nd.tt_depth >= depth - 3 and !isShuffling(nd.pos_ptr, nd.ss_ptr, move))
        {
            const singular_beta = search.singularBeta(nd.tt_value, nd.ss.tt_pv and !nd.pv_node, depth);
            const singular_depth = @divTrunc(new_depth, 2);
            nd.ss.excluded_move = move;
            value = searchImpl(nd.ctx, nd.pos_ptr, nd.ss_ptr, singular_beta - 1, singular_beta, singular_depth, nd.cut_node, false, false);
            nd.ss.excluded_move = 0;
            if (value < singular_beta) {
                const ply_gt_root = nd.ss.ply > nd.ctx.root_depth.*;
                const double_margin = search.singularDoubleMargin(nd.pv_node, !nd.tt_capture, nd.correction_value, nd.w.tt_move_history, ply_gt_root);
                const triple_margin = search.singularTripleMargin(nd.pv_node, !nd.tt_capture, nd.ss.tt_pv, nd.correction_value, ply_gt_root);
                extension = 1 + @as(i32, @intFromBool(value < singular_beta - double_margin)) + @as(i32, @intFromBool(value < singular_beta - triple_margin));
                depth += 1;
            } else if (value >= nd.beta and !qIsDecisive(value)) {
                ttMoveHistoryUpdate(nd.w, search.ttMoveHistoryDepthBonus(depth));
                return value;
            } else if (nd.tt_value >= nd.beta) {
                extension = -3;
            } else if (nd.cut_node) {
                extension = -2;
            }
        }

        const node_count: u64 = if (nd.root_node) nd.ctx.nodes.* else 0;

        // Step 16. Make the move.
        doMoveAcc(nd.ctx, nd.pos_ptr, move, st, @intFromBool(gc), nd.ss_ptr);
        new_depth += extension;

        if (nd.ss.tt_pv)
            r -= search.lmrTtpvReduction(nd.pv_node, nd.tt_value > alpha, nd.tt_depth >= depth, nd.cut_node);
        r += 697;
        r -= move_count * 65;
        r -= search.lmrCorrReduction(nd.correction_value);
        if (nd.cut_node) r += 4026 + 933 * @as(i32, @intFromBool(nd.tt_move == 0));
        if (ssAdd(nd.ss, 1).cutoff_cnt > 1) {
            r += 264 + 1095 * @as(i32, @intFromBool(ssAdd(nd.ss, 1).cutoff_cnt > 2)) + 1138 * @as(i32, @intFromBool(nd.all_node));
        } else if (move == nd.tt_move) {
            r -= 2179; // upstream 924d29d3c: simplify the first-picked-move (ttMove) reduction
        }
        if (nd.tt_capture) r += 1079;

        if (capture)
            nd.ss.stat_score = search.captureStatScore(q_piece_value[nd.pos.st.captured_piece], captVal(nd.w, moved_piece, to, nd.pos.st.captured_piece & 7))
        else
            nd.ss.stat_score = search.quietStatScore(nd.w.main_history[@as(usize, nd.us) * hist_uint16 + move], contVal(cont_hist[0], moved_piece, to), contVal(cont_hist[1], moved_piece, to));

        r -= search.lmrStatScoreReduction(nd.ss.stat_score);
        if (nd.all_node) r += search.lmrAllNodeScale(r, depth);

        // Step 17/18. Run the LMR + full-depth search.
        if (depth >= 2 and move_count > 1) {
            const d = @max(@as(i32, 1), @min(new_depth - @divTrunc(r, 1024), new_depth + 2)) + @as(i32, @intFromBool(nd.pv_node));
            nd.ss.reduction = new_depth - d;
            value = -searchImpl(nd.ctx, nd.pos_ptr, ssAdd(nd.ss, 1), -(alpha + 1), -alpha, d, true, false, false);
            nd.ss.reduction = 0;
            if (value > alpha) {
                const do_deeper = d < new_depth and value > best_value + 53;
                const do_shallower = value < best_value + 8;
                new_depth += @as(i32, @intFromBool(do_deeper)) - @as(i32, @intFromBool(do_shallower));
                if (new_depth > d)
                    value = -searchImpl(nd.ctx, nd.pos_ptr, ssAdd(nd.ss, 1), -(alpha + 1), -alpha, new_depth, !nd.cut_node, false, false);
                updateContinuationHistories(nd.ss, moved_piece, to, 1334);
            }
        } else if (!nd.pv_node or move_count > 1) {
            if (nd.tt_move == 0) r += 1127;
            value = -searchImpl(nd.ctx, nd.pos_ptr, ssAdd(nd.ss, 1), -(alpha + 1), -alpha, new_depth - @as(i32, @intFromBool(r > 5234)) - @as(i32, @intFromBool(r > 5487 and new_depth > 2)), !nd.cut_node, false, false);
        }

        if (nd.pv_node and (move_count == 1 or value > alpha)) {
            ssAdd(nd.ss, 1).pv = &pv;
            pvClear(&pv);
            if (move == nd.tt_move and ((qIsValid(nd.tt_value) and qIsDecisive(nd.tt_value) and nd.tt_depth > 0) or nd.tt_depth > 1))
                new_depth = @max(new_depth, 1);
            value = -searchImpl(nd.ctx, nd.pos_ptr, ssAdd(nd.ss, 1), -nd.beta, -alpha, new_depth, false, true, false);
        }

        // Step 19. Undo move.
        undoMoveAcc(nd.ctx, nd.pos_ptr, move);

        // Step 20. Check for a new best move.
        if (searchStopped(nd.ctx)) return q_value_draw;

        if (nd.root_node) {
            // Hold that (nd.ss+1)->pv is only valid (non-null) when this move ran a PV search,
            // i.e. move_count == 1 or value > alpha; otherwise it is ignored.
            const cpv: ?*const PVMoves = if (move_count == 1 or value > alpha) ssAdd(nd.ss, 1).pv.? else null;
            rootUpdate(nd.ctx, move, value, nd.ctx.nodes.* - node_count, move_count, alpha, nd.beta, cpv);
        }

        const av = if (value < 0) -value else value;
        const inc: i32 = @intFromBool(value == best_value and nd.ss.ply + 2 >= nd.ctx.root_depth.* and (@as(i32, @intCast(nd.ctx.nodes.* & 14)) == 0) and !qIsWin(av + 1));
        if (value + inc > best_value) {
            best_value = value;
            if (value + inc > alpha) {
                best_move = move;
                // Hold that (nd.ss+1)->pv is only set (1913) when this move ran a PV re-search;
                // if a rare best-move update fires without one it stays null, and
                // pvUpdate takes the child PV as optional (null -> PV is just the
                // move). Force-unwrapping it here was a latent null-deref (silent
                // under ReleaseFast, panics under ReleaseSafe/Debug).
                if (nd.pv_node and !nd.root_node) {
                    const child_pv = ssAdd(nd.ss, 1).pv;
                    pvUpdate(nd.ss.pv.?, move, child_pv);
                }
                if (value >= nd.beta) {
                    nd.ss.cutoff_cnt += @intFromBool(extension < 2 or nd.pv_node);
                    break;
                }
                if (depth > 3 and depth < 12 and !qIsDecisive(value)) depth -= 3;
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

    // Step 21. Adjust for mate / stalemate / fail-high.
    if (best_value >= nd.beta and !qIsDecisive(best_value) and !qIsDecisive(alpha))
        best_value = @divTrunc(best_value * depth + nd.beta, depth + 1);

    if (move_count == 0) {
        best_value = if (nd.excluded_move != 0) alpha else if (nd.ss.in_check) qMatedIn(nd.ss.ply) else q_value_draw;
    } else if (best_move != 0) {
        updateAllStats(nd.ctx.worker, nd.pos_ptr, nd.ss_ptr, best_move, nd.prev_sq, &quiets_searched, n_quiets, &captures_searched, n_captures, depth, nd.tt_move, @intFromBool(nd.pv_node));
        if (!nd.pv_node) ttMoveHistoryUpdate(nd.w, search.ttMoveHistoryMatchBonus(best_move == nd.tt_move));
    } else if (!nd.prior_capture and nd.prev_sq != @as(i32, sq_none)) {
        const psq: u8 = @intCast(nd.prev_sq);
        const bonus_scale = search.priorBonusScale(nd.ss1.stat_score, depth, nd.ss1.move_count > 9, !nd.ss.in_check and best_value <= nd.ss.static_eval - 106, !nd.ss1.in_check and best_value <= -nd.ss1.static_eval - 68);
        const scaled_bonus = search.priorScaledBonusBase(depth) * bonus_scale;
        updateContinuationHistories(nd.ss1, nd.pos.board[psq], psq, search.priorConthistScale(scaled_bonus));
        statsUpdate(&nd.w.main_history[@as(usize, nd.us ^ 1) * hist_uint16 + nd.ss1.current_move], search.priorMainhistScale(scaled_bonus), 7183);
        if ((nd.pos.board[psq] & 7) != pawn_pt and moveTypeOf(nd.ss1.current_move) != q_mt_promotion) {
            const row = pawnEntryRow(sharedOf(nd.w), nd.pos);
            statsUpdate(&row[@as(usize, nd.pos.board[psq]) * 64 + psq], search.priorPawnhistScale(scaled_bonus), 8192);
        }
    } else if (nd.prior_capture and nd.prev_sq != @as(i32, sq_none)) {
        const psq: u8 = @intCast(nd.prev_sq);
        statsUpdate(captEntry(nd.w, nd.pos.board[psq], psq, nd.pos.st.captured_piece & 7), 892, 10692);
    }

    if (nd.pv_node) best_value = @min(best_value, nd.max_value);

    if (best_value <= alpha) nd.ss.tt_pv = nd.ss.tt_pv or nd.ss1.tt_pv;

    if (nd.excluded_move == 0 and !(nd.root_node and nd.ctx.pv_idx.* != 0)) {
        const bound: u8 = if (best_value >= nd.beta) q_bound_lower else if (nd.pv_node and best_move != 0) q_bound_exact else q_bound_upper;
        const wdepth: i32 = if (move_count != 0) depth else @min(q_max_ply - 1, depth + 6);
        tt.entrySave(nd.writer, nd.pos_key, search.valueToTt(best_value, nd.ss.ply), @intFromBool(nd.ss.tt_pv), bound, wdepth, q_depth_none, best_move, nd.unadjusted_static_eval, nd.ctx.generation);
    }

    // Adjust correction history.
    if (!nd.ss.in_check and !(best_move != 0 and posCapture(nd.pos, best_move)) and (best_value > nd.ss.static_eval) == (best_move != 0)) {
        updateCorrectionHistory(nd.ctx.worker, nd.pos_ptr, nd.ss_ptr, search.correctionHistoryBonus(best_value - nd.ss.static_eval, depth, best_move != 0));
    }

    return best_value;
}
