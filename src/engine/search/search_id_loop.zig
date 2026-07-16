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
        id.iter_value[0] = fv;
        id.iter_value[1] = fv;
        id.iter_value[2] = fv;
        id.iter_value[3] = fv;
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

        // Save last iteration scores.
        var ri: usize = 0;
        while (ri < id.root_moves_count) : (ri += 1)
            id.root_moves[ri].previous_score = id.root_moves[ri].score;

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
                    if (main_thread) id.stop_on_ponderhit.* = 0;
                } else if (best_value >= beta) {
                    alpha = @max(beta - delta, alpha);
                    beta = @min(best_value + delta, q_value_inf);
                    failed_high_cnt += 1;
                } else break;

                delta = search.aspirationDeltaGrow(delta);
            }

            // Protect aborted later PV lines from mated-in/TB-loss (MultiPV).
            if (@atomicLoad(u8, id.stop, .monotonic) != 0 and id.pv_idx.* != 0 and
                idIsLoss(id.root_moves[id.pv_idx.* - 1].score) and
                rootLess(&id.root_moves[id.pv_idx.*], &id.root_moves[id.pv_idx.* - 1]))
            {
                const prev = id.root_moves[id.pv_idx.* - 1].score;
                const cur_prev = id.root_moves[id.pv_idx.*].previous_score;
                id.root_moves[id.pv_idx.*].score = if (cur_prev != -q_value_inf and cur_prev < prev) cur_prev else prev;
                id.root_moves[id.pv_idx.*].uci_score = id.root_moves[id.pv_idx.*].score;
                id.root_moves[id.pv_idx.*].previous_score = -q_value_inf;
                id.root_moves[id.pv_idx.*].score_lowerbound = false;
                id.root_moves[id.pv_idx.*].score_upperbound = false;
                id.root_moves[id.pv_idx.*].pv.length = 1;
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

        if (@atomicLoad(u8, id.stop, .monotonic) == 0) {
            if (id.last_iter_pv.length == 0 or id.root_moves[0].pv.moves[0] != id.last_iter_pv.moves[0])
                last_best_move_depth = id.root_depth.*;
            id.last_iter_pv.* = id.root_moves[0].pv;
        } else if (id.pv_idx.* == 0 and id.root_moves[0].score != -q_value_inf and
            idIsLoss(id.root_moves[0].score) and
            !(id.root_moves[0].score_lowerbound or id.root_moves[0].score_upperbound))
        {
            if (id.last_iter_pv.length != 0) {
                moveToFront(id.root_moves, id.root_moves_count, id.last_iter_pv.moves[0]);
                id.root_moves[0].pv = id.last_iter_pv.*;
                id.root_moves[0].score = id.root_moves[0].previous_score;
                id.root_moves[0].uci_score = id.root_moves[0].previous_score;
                if (main_thread) uci_pv_sent = false;
            } else id.root_moves[0].score_lowerbound = true;
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
        if (id.use_time_management != 0 and @atomicLoad(u8, id.stop, .monotonic) == 0 and id.stop_on_ponderhit.* == 0) {
            const nodes_effort: u64 = @divTrunc(id.root_moves[0].effort * 100000, @max(@as(u64, 1), id.nodes.*));

            var falling_eval = (11.87 + 2.21 * @as(f64, @floatFromInt(id.best_previous_average_score - best_value)) +
                1.0 * @as(f64, @floatFromInt(id.iter_value[iter_idx] - best_value))) / 100.0;
            falling_eval = fclamp(falling_eval, 0.572, 1.708);

            const tr_x = @as(f64, @floatFromInt(id.root_depth.* - last_best_move_depth));
            time_reduction = fclamp(0.65 + (1.55 - 0.65) * (tr_x - 5.0) / (18.0 - 5.0), 0.65, 1.55);

            const reduction = (1.48 + id.previous_time_reduction.*) / (2.157 * time_reduction);
            const best_move_instability = 1.096 + 2.29 * tot_best_move_changes / @as(f64, @floatFromInt(id.threads_size));

            const hbme_x = @as(f64, @floatFromInt(@as(i64, @intCast(nodes_effort))));
            const high_best_move_effort = fclamp(0.924 + (0.71 - 0.924) * (hbme_x - 79219.0) / (101822.0 - 79219.0), 0.71, 0.924);

            var total_time = @as(f64, @floatFromInt(id.tm_optimum)) * falling_eval * reduction * best_move_instability * high_best_move_effort;
            if (id.root_moves_count == 1) total_time = @min(561.7, total_time);

            const elapsed_time = @as(f64, @floatFromInt(idElapsed(&id)));
            if (elapsed_time > @min(total_time, @as(f64, @floatFromInt(id.tm_maximum)))) {
                if (@atomicLoad(u8, id.ponder, .monotonic) != 0) id.stop_on_ponderhit.* = 1 else @atomicStore(u8, id.stop, 1, .monotonic);
            } else {
                const inc: u8 = if (@atomicLoad(u8, id.ponder, .monotonic) != 0 or elapsed_time <= total_time * 0.50) 1 else 0;
                @atomicStore(u8, id.increase_depth, inc, .monotonic);
            }
        }

        id.iter_value[iter_idx] = best_value;
        iter_idx = (iter_idx + 1) & 3;
    }

    if (!main_thread) return 0;

    id.previous_time_reduction.* = time_reduction;
    // Swap the best PV line with the sub-optimal one if the skill level is enabled.
    if (id.skill_enabled != 0) {
        const sel = if (skill_best != 0) skill_best else skillPickBest(&id, multi_pv);
        skillSwapBest(&id, sel);
    }
    return if (uci_pv_sent) 1 else 0;
}
