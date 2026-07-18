// Drive iterative deepening. Drive the main search (search_main.searchImpl)
// across depths + aspiration windows, handle skill/MultiPV/time, and emit UCI
// info. Call searchImpl but nothing in the worker-start glue, so form a
// one-way leaf that search_driver drives.

const std = @import("std");
const worker_layout = @import("worker_layout");
const tt = @import("tt");
const search = @import("search");
const worker_histories = @import("worker_histories");
const position_types = @import("position_types");
const search_types = @import("search_types");
const search_ctx = @import("search_ctx");
const search_id = @import("search_id");
const search_setup = @import("search_setup");
const position_query = @import("position_query");
const history_mod = @import("history");
pub const setContHist = history_mod.setContHist;
pub const ageMainHistory = history_mod.ageMainHistory;
pub const fillLowPlyHistory = history_mod.fillLowPlyHistory;
const Position = position_types.Position;
const StateInfo = position_types.StateInfo;
const SearchStack = search_types.SearchStack;
const WorkerHistories = worker_histories.WorkerHistories;
const sideToMove = position_query.sideToMove;
comptime {
    // Assert the opaque byte regions worker_layout.WorkerLayout uses for these
    // position-module sub-blocks match the real struct sizes so worker_off stays correct.
    std.debug.assert(worker_layout.worker_histories_bytes == @sizeOf(WorkerHistories));
    std.debug.assert(worker_layout.position_size == @sizeOf(Position));
    std.debug.assert(worker_layout.state_info_size == @sizeOf(StateInfo));
}
const sv = @import("search_values.zig");
const q_value_none = sv.value_none;
const q_value_inf = sv.value_inf;
const q_value_mate = sv.value_mate;
const q_max_ply = sv.max_ply;
pub const PVMoves = search_types.PVMoves;
const search_emit = @import("search_emit");
const searchIdPv = search_emit.searchIdPv;
const searchIdCollectBmc = search_id.searchIdCollectBmc;
const searchCbTtContext = search_ctx.searchCbTtContext;
const searchIdState = search_id.searchIdState;
const ZfishIdState = search_ctx.ZfishIdState;
const buildCtx = search_setup.buildCtx;
const id_nodes_limit_output = search_id.id_nodes_limit_output;
const idIsLoss = search_id.idIsLoss;
const idIsMate = search_id.idIsMate;
const idIsMated = search_id.idIsMated;
const rootLess = search_id.rootLess;
const stableSortRoot = search_id.stableSortRoot;
const moveToFront = search_id.moveToFront;
const idElapsed = search_id.idElapsed;
const fclamp = search_id.fclamp;
const skillTimeToPick = search_id.skillTimeToPick;
const skillPickBest = search_id.skillPickBest;
const skillSwapBest = search_id.skillSwapBest;
const search_main = @import("search_main.zig");
const searchImpl = search_main.searchImpl;

pub fn iterativeDeepening(wl: *worker_layout.WorkerLayout) u8 {
    // Drive the typed graph directly -- not a hook: only workerStartSearching calls it,
    // and it already holds the typed *WorkerLayout.
    var id: ZfishIdState = undefined;
    searchIdState(wl, &id);
    const main_thread = id.is_main != 0;

    var table: ?[*]tt.TtCluster = null;
    var cc: usize = 0;
    var gen: u8 = 0;
    searchCbTtContext(wl, &table, &cc, &gen);
    const ctx = buildCtx(wl, table, cc, gen);

    var pv: PVMoves = undefined;
    pv.length = 0;

    // Keep the best move's PV in a LOCAL, as upstream does (`PVMoves lastBestMovePV;`,
    // search.cpp:275). It is the abort-rollback memory and is written only when the best
    // move changes -- a different quantity, and a different lifetime, from the per-pvIdx
    // follow-PV memory in the Worker (last_iteration_pv). Sharing one buffer for both
    // conflated them.
    var last_best_move_pv: PVMoves = undefined;
    last_best_move_pv.length = 0;
    // Remember the best score alongside its PV (upstream's `lastBestMoveScore`,
    // search.cpp:277). The rollback restored root_moves[0].previous_score instead, which
    // is this iteration's saved score -- not the score that belongs to last_best_move_pv.
    var last_best_move_score: c_int = -q_value_inf;
    var last_best_move_depth: c_int = 0;
    var best_value: c_int = -q_value_inf;
    const us: usize = @intCast(sideToMove(id.root_pos));
    var time_reduction: f64 = 1;
    var tot_best_move_changes: f64 = 0;
    var iter_idx: usize = 0;

    // Zero Stack[MAX_PLY+10] with (ss-7..ss-1) sentinels and ss[i].ply = i.
    const stack_n: usize = @intCast(q_max_ply + 10);
    var stack: [stack_n]SearchStack = std.mem.zeroes([stack_n]SearchStack);
    {
        var k: usize = 0;
        while (k < 7) : (k += 1) {
            setContHist(wl, &stack[k], 0, 0, 0, 0); // sentinel (NO_PIECE)
            stack[k].static_eval = q_value_none;
        }
        const ply_hi: usize = @intCast(q_max_ply + 2);
        var p: usize = 0;
        while (p <= ply_hi) : (p += 1) stack[7 + p].ply = @intCast(p);
        stack[7].pv = &pv;
    }

    if (main_thread) {
        const fv: c_int = if (id.best_previous_score == q_value_inf) 0 else id.best_previous_score;
        id.iter_value.?.* = @splat(fv);
    }

    var multi_pv: usize = id.multipv_option;
    if (id.skill_enabled != 0 and multi_pv < 4) multi_pv = 4;
    if (multi_pv > id.root_moves_count) multi_pv = id.root_moves_count;
    var skill_best: u16 = 0;

    fillLowPlyHistory(wl);
    ageMainHistory(wl);

    var search_again_counter: c_int = 0;
    var uci_pv_sent = false;

    // Run the iterative deepening loop.
    while (id.root_depth.* + 1 < q_max_ply and @atomicLoad(u8, id.stop, .monotonic) == 0 and
        !(id.limits_depth != 0 and main_thread and id.root_depth.* >= id.limits_depth))
    {
        id.root_depth.* += 1;

        if (main_thread) {
            tot_best_move_changes /= 2;
            uci_pv_sent = false;
        }

        // Save the last iteration's scores before the first PV line is searched and all
        // the move scores except the (new) PV are set to -VALUE_INFINITE. Mirror upstream
        // search.cpp:346-351: the PV and its exactness are saved alongside the score.
        // Only previous_score was saved before, so previousPV did not exist and the
        // follow-PV memory had to borrow rootMoves[0].pv -- see last_iteration_pv below.
        var ri: usize = 0;
        while (ri < id.root_moves_count) : (ri += 1) {
            id.root_moves[ri].previous_score = id.root_moves[ri].score;
            id.root_moves[ri].previous_pv = id.root_moves[ri].pv;
            id.root_moves[ri].previous_score_exact = ri < multi_pv;
        }

        var pv_first: usize = 0;
        id.pv_last.* = 0;

        if (@atomicLoad(u8, id.increase_depth, .monotonic) == 0) search_again_counter += 1;

        // Loop over the MultiPV lines.
        id.pv_idx.* = 0;
        while (id.pv_idx.* < multi_pv) : (id.pv_idx.* += 1) {
            if (id.pv_idx.* == id.pv_last.*) {
                pv_first = id.pv_last.*;
                id.pv_last.* += 1;
                while (id.pv_last.* < id.root_moves_count) : (id.pv_last.* += 1) {
                    if (id.root_moves[id.pv_last.*].tb_rank != id.root_moves[pv_first].tb_rank) break;
                }
            }

            // Point the follow-PV memory at THIS line's PV from the previous iteration
            // (upstream search.cpp:369). This is upstream's `lastIterationIdxPV`, a
            // per-pvIdx value; it is NOT the best move's PV. zfish had one buffer doing
            // both jobs, so every MultiPV line followed rootMoves[0]'s PV and searched a
            // different tree once MultiPV > 1.
            id.last_iter_pv.* = id.root_moves[id.pv_idx.*].previous_pv;

            id.sel_depth.* = 0;

            var delta = search.aspirationInitialDelta(id.thread_idx, id.root_moves[id.pv_idx.*].mean_squared_score);
            const avg = id.root_moves[id.pv_idx.*].average_score;
            var alpha = @max(avg - delta, -q_value_inf);
            var beta = @min(avg + delta, q_value_inf);
            id.optimism[us] = search.optimism(avg);
            id.optimism[us ^ 1] = -id.optimism[us];

            var failed_high_cnt: c_int = 0;
            while (true) {
                const adjusted_depth = @max(@as(c_int, 1), id.root_depth.* - failed_high_cnt - @divTrunc(3 * (search_again_counter + 1), 4));
                id.root_delta.* = beta - alpha;
                best_value = searchImpl(&ctx, id.root_pos, &stack[7], alpha, beta, adjusted_depth, false, true, true);

                stableSortRoot(id.root_moves, id.pv_idx.*, id.pv_last.*);

                if (@atomicLoad(u8, id.stop, .monotonic) != 0) break;

                if (main_thread and multi_pv == 1 and (best_value <= alpha or best_value >= beta) and id.nodes.* > id_nodes_limit_output)
                    searchIdPv(wl, id.root_depth.*);

                if (best_value <= alpha) {
                    beta = alpha;
                    alpha = @max(best_value - delta, -q_value_inf);
                    failed_high_cnt = 0;
                    if (main_thread) id.stop_on_ponderhit.?.* = 0;
                } else if (best_value >= beta) {
                    alpha = @max(beta - delta, alpha);
                    beta = @min(best_value + delta, q_value_inf);
                    failed_high_cnt += 1;
                } else break;

                delta = search.aspirationDeltaGrow(delta);
            }

            // In multiPV analysis we do not let aborted searches spoil mated-in/TB loss
            // scores from a completed search in an earlier PV line. Guard against an
            // aborted pvIdx line overtaking pvIdx - 1 when pvIdx - 1 is a proven loss.
            // Moreover, do not trust an exact loss score from an aborted search.
            // Port upstream search.cpp:443-489 faithfully; the previous code was an older
            // revision that merged both arms into a min(), so it could not restore the
            // previous PV, always cleared both bound flags, and never marked the later
            // lines. It needed previousPV / previousScoreExact, which did not exist.
            if (@atomicLoad(u8, id.stop, .monotonic) != 0 and id.pv_idx.* != 0) {
                const cur = &id.root_moves[id.pv_idx.*];
                const prev_line = &id.root_moves[id.pv_idx.* - 1];
                const prev_is_loss = idIsLoss(prev_line.score);

                if ((prev_is_loss and rootLess(cur, prev_line)) or
                    cur.scoreIsExactLoss(idIsLoss(cur.score)))
                {
                    // If previousScore is exact and worse than pvIdx - 1, we can safely
                    // use it. If it is equal, make sure it cannot overtake pvIdx - 1.
                    if (cur.previous_score != -q_value_inf and cur.previous_score_exact and
                        cur.previous_score <= prev_line.score)
                    {
                        cur.score = cur.previous_score;
                        cur.uci_score = cur.previous_score;
                        cur.previous_score = -q_value_inf;
                        cur.pv = cur.previous_pv;
                        cur.unsetBoundFlags();
                    } else {
                        // Otherwise, if we can, cap the score to the best possible and mark
                        // it as a bound (also a valid excuse for the incomplete PV).
                        if (prev_is_loss) {
                            cur.score = prev_line.score;
                            cur.uci_score = prev_line.score;
                            cur.previous_score = -q_value_inf;
                            cur.pv.length = 1;
                            cur.score_upperbound = true;
                        } else {
                            cur.score_upperbound = false;
                        }
                        cur.score_lowerbound = !cur.score_upperbound;
                    }
                }

                // Finally, mark all loss scores from partially searched moves as a bound.
                var li: usize = id.pv_idx.* + 1;
                while (li < multi_pv) : (li += 1) {
                    const rm = &id.root_moves[li];
                    if (rm.scoreIsExactLoss(idIsLoss(rm.score))) rm.score_lowerbound = true;
                }
            }

            stableSortRoot(id.root_moves, pv_first, id.pv_idx.* + 1);

            if (main_thread and @atomicLoad(u8, id.stop, .monotonic) == 0 and
                (id.pv_idx.* + 1 == multi_pv or id.nodes.* > id_nodes_limit_output))
            {
                searchIdPv(wl, id.root_depth.*);
                uci_pv_sent = (id.pv_idx.* + 1 == multi_pv);
            }

            if (@atomicLoad(u8, id.stop, .monotonic) != 0) break;
        }

        // Detect a mate score found in an earlier iteration that this iteration failed to
        // recover -- upstream's `forgottenMate` (search.cpp:504-507), which was absent.
        // It fires when the remembered best score is a mate/mated and the new score is
        // either shorter-in-absolute-terms or merely a bound. Note it is NOT conditioned
        // on `stop`: a COMPLETED iteration that forgets a mate is rolled back too.
        const stopped = @atomicLoad(u8, id.stop, .monotonic) != 0;
        const forgotten_mate = last_best_move_score != -q_value_inf and
            (idIsMate(last_best_move_score) or idIsMated(last_best_move_score)) and
            (@abs(id.root_moves[0].score) < @abs(last_best_move_score) or
                id.root_moves[0].scoreIsBound());

        if (!stopped) {
            if (last_best_move_pv.length == 0 or id.root_moves[0].pv.moves[0] != last_best_move_pv.moves[0])
                last_best_move_depth = id.root_depth.*;

            // Do not replace (shorter) mate scores from a previous iteration.
            if (!forgotten_mate) {
                last_best_move_pv = id.root_moves[0].pv;
                last_best_move_score = id.root_moves[0].score;
            }
        }

        const aborted_loss_search = stopped and id.pv_idx.* == 0 and
            id.root_moves[0].scoreIsExactLoss(idIsLoss(id.root_moves[0].score));

        // An exact mated-in/TB-loss score from an aborted search cannot be trusted: the
        // loss could be delayed or refuted upon exploring the remaining root-moves. Roll
        // back to the previous iteration's score. Do the same when a search has failed to
        // recover a mate score found in a previous iteration.
        if (aborted_loss_search or (id.root_moves[0].score != -q_value_inf and forgotten_mate)) {
            // Bring the last best move to the front for best thread selection.
            if (last_best_move_pv.length != 0) {
                moveToFront(id.root_moves, id.root_moves_count, last_best_move_pv.moves[0]);
                id.root_moves[0].score = last_best_move_score;
                id.root_moves[0].uci_score = last_best_move_score;
                id.root_moves[0].pv = last_best_move_pv;
                id.root_moves[0].unsetBoundFlags();
                if (main_thread) uci_pv_sent = false;
            } else if (aborted_loss_search) {
                // For an aborted d1 search label the loss score as a lower bound.
                id.root_moves[0].score_lowerbound = true;
            }
        }

        // Check whether mate in x is found.
        if (id.limits_mate != 0 and @atomicLoad(u8, id.stop, .monotonic) == 0 and
            ((idIsMate(id.root_moves[0].score) and q_value_mate - id.root_moves[0].score <= 2 * id.limits_mate) or
                (idIsMated(id.root_moves[0].score) and q_value_mate + id.root_moves[0].score <= 2 * id.limits_mate)))
            @atomicStore(u8, id.stop, 1, .monotonic);

        if (!main_thread) continue;

        // Pick a sub-optimal move if the skill level is enabled and time is up.
        if (id.skill_enabled != 0 and skillTimeToPick(id.skill_level, id.root_depth.*))
            skill_best = skillPickBest(&id, multi_pv);

        tot_best_move_changes += searchIdCollectBmc(wl);

        // Manage time: decide whether we have time for the next iteration or can stop.
        if (id.use_time_management != 0 and @atomicLoad(u8, id.stop, .monotonic) == 0 and id.stop_on_ponderhit.?.* == 0) {
            const nodes_effort: u64 = @divTrunc(id.root_moves[0].effort * 100000, @max(@as(u64, 1), id.nodes.*));

            var falling_eval = (11.87 + 2.21 * @as(f64, @floatFromInt(id.best_previous_average_score - best_value)) +
                1.0 * @as(f64, @floatFromInt(id.iter_value.?[iter_idx] - best_value))) / 100.0;
            falling_eval = fclamp(falling_eval, 0.572, 1.708);

            const tr_x = @as(f64, @floatFromInt(id.root_depth.* - last_best_move_depth));
            time_reduction = fclamp(0.65 + (1.55 - 0.65) * (tr_x - 5.0) / (18.0 - 5.0), 0.65, 1.55);

            const reduction = (1.48 + id.previous_time_reduction.?.*) / (2.157 * time_reduction);
            const best_move_instability = 1.096 + 2.29 * tot_best_move_changes / @as(f64, @floatFromInt(id.threads_size));

            const hbme_x = @as(f64, @floatFromInt(@as(i64, @intCast(nodes_effort))));
            const high_best_move_effort = fclamp(0.924 + (0.71 - 0.924) * (hbme_x - 79219.0) / (101822.0 - 79219.0), 0.71, 0.924);

            var total_time = @as(f64, @floatFromInt(id.tm_optimum)) * falling_eval * reduction * best_move_instability * high_best_move_effort;
            // Cap used time to 0.5s for a better viewer experience (search.cpp:592-594).
            if (id.root_moves_count == 1) total_time = @min(500.0, total_time);

            // Stop once there is nothing better to find: a mate in <=3 for us, or a forced
            // mate against us in 2 (search.cpp:600-601). Both disjuncts were missing, so a
            // found mate did not end the iteration -- the score then stops moving, no time
            // heuristic fires, and the loop grinds to the MAX_PLY ceiling: on a mate-in-1
            // under `go wtime`, upstream stops at depth 1 / 17 nodes while zfish reached
            // depth 245 / 4165. Read the scores after the pv loop has written this
            // iteration's values, matching upstream's placement.
            const mate_in_3: c_int = sv.value_mate - 3;
            const mated_in_2: c_int = -sv.value_mate + 2;
            const found_mate = id.root_moves[multi_pv - 1].score >= mate_in_3 or
                id.root_moves[0].score == mated_in_2;

            const elapsed_time = @as(f64, @floatFromInt(idElapsed(&id)));
            if (elapsed_time > @min(total_time, @as(f64, @floatFromInt(id.tm_maximum))) or found_mate) {
                if (@atomicLoad(u8, id.ponder.?, .monotonic) != 0) id.stop_on_ponderhit.?.* = 1 else @atomicStore(u8, id.stop, 1, .monotonic);
            } else {
                const inc: u8 = if (@atomicLoad(u8, id.ponder.?, .monotonic) != 0 or elapsed_time <= total_time * 0.50) 1 else 0;
                @atomicStore(u8, id.increase_depth, inc, .monotonic);
            }
        }

        id.iter_value.?[iter_idx] = best_value;
        iter_idx = (iter_idx + 1) & 3;
    }

    if (!main_thread) return 0;

    id.previous_time_reduction.?.* = time_reduction;
    // Swap the best PV line with the sub-optimal one if the skill level is enabled.
    if (id.skill_enabled != 0) {
        const sel = if (skill_best != 0) skill_best else skillPickBest(&id, multi_pv);
        skillSwapBest(&id, sel);
    }
    return if (uci_pv_sent) 1 else 0;
}
