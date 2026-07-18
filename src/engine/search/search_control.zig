// Track root-search bookkeeping and time/stop control.
// Operate purely on the QCtx (built by search_setup) plus the clock and
// the shared stop/ponder flags worker_state hands over; none of them touch the
// search recursion itself, so they form a clean, self-contained cluster:
//   * checkTime     -- decrement the calls counter and raise the stop flag
//   * rootUpdate    -- search<Root> per-move RootMove bookkeeping
//   * rootTtMove    -- the root TT move (rootMoves[pvIdx].pv[0])
//   * rootInList    -- RootMove::operator== over [pvIdx, pvLast)
//   * searchStopped -- monotonic load of the shared stop flag
//   * inLastIterPv  -- follow-PV test against lastIterationPV
// Pure aside from the atomics and the injected clock.

const std = @import("std");
const time_source = @import("time_source");
const search_ctx = @import("search_ctx");
const search_types = @import("search_types");
const sv = @import("search_values.zig");

const QCtx = search_ctx.QCtx;
const PVMoves = search_types.PVMoves;
const q_value_inf = sv.value_inf;

pub fn checkTime(ctx: *const QCtx) void {
    const ts = &ctx.time_state;
    const cc = ts.calls_cnt orelse return; // not the main thread => no-op
    cc.* -= 1;
    if (cc.* > 0) return;
    cc.* = if (ts.lim_nodes != 0) @intCast(@min(@as(u64, 512), ts.lim_nodes / 1024)) else 512;

    // Read the POOL's node count, not this worker's: upstream gates both `nodestime`
    // elapsed and the node limit on `worker.threads.nodes_searched()` (search.cpp:2073,
    // 2088). Sampled once per checkTime call (every <=512 nodes), so the sum over the
    // pool is amortised, as it is upstream.
    const pool_nodes: u64 = search_ctx.timeStatePoolNodes(ts, ctx.nodes.*);

    const elapsed: i64 = if (ts.tm_use_nodes_time != 0)
        @intCast(pool_nodes)
    else
        time_source.now() - ts.tm_start_time;

    // Load atomically: the UCI thread clears this on ponderhit, and missing that store leaves
    // checkTime permanently early-returning, so no time limit is ever enforced.
    if (@atomicLoad(u8, ts.ponder.?, .monotonic) != 0) return;

    const ns: u64 = pool_nodes;
    if ((ts.use_time_management != 0 and (elapsed > ts.tm_maximum_time or ts.stop_on_ponderhit.?.* != 0)) or
        (ts.lim_movetime != 0 and elapsed >= ts.lim_movetime) or
        (ts.lim_nodes != 0 and ns >= ts.lim_nodes))
    {
        @atomicStore(u8, ts.stop_write.?, 1, .monotonic);
    }
}

// Do the per-move root bookkeeping. Find the
// RootMove for `move` in [pvIdx, pvLast) (unique, guaranteed present by the
// rootInList filter), update its effort / averageScore / meanSquaredScore, and
// on a PV move store the score/bound flags/PV. Use C truncating division
// (@divTrunc) and i32 arithmetic (no overflow: both squared terms are
// < VALUE_INFINITE^2, sum < INT_MAX).
const root_mean_sq_sentinel: i32 = -(q_value_inf * q_value_inf);
pub fn rootUpdate(ctx: *const QCtx, move: u16, value: i32, nodes_delta: u64, move_count: i32, alpha: i32, beta: i32, child_pv: ?*const PVMoves) void {
    var idx: usize = ctx.pv_idx.*;
    const last = ctx.pv_last.*;
    while (idx < last and ctx.root_moves[idx].pv.moves[0] != move) : (idx += 1) {}
    const rm = &ctx.root_moves[idx];

    rm.effort += nodes_delta;

    // Dynamic EMA (upstream 93ed4b53c): weight this move's node share (N) against its
    // prior effort (E_prev). The averageScore / meanSquaredScore updates run in u64 as
    // upstream -- `value * w` promotes the signed value to u64, so this is UNSIGNED
    // wrapping arithmetic truncated back to i32; bit-exact only when replicated exactly.
    const scale: u64 = 32;
    const n: u64 = nodes_delta;
    const e_prev: u64 = @max(@as(u64, 1), rm.effort - n);
    const w: u64 = @min(@max((scale * n * 2) / (n * 2 + 3 * e_prev), @as(u64, 12)), @as(u64, 24));
    const w_mss: u64 = @min(w, @as(u64, 16));
    const av = if (value < 0) -value else value;
    const v2: i64 = @as(i64, value) * @as(i64, av);

    if (rm.average_score == -q_value_inf) {
        rm.average_score = value;
    } else {
        const value_u: u64 = @bitCast(@as(i64, value));
        const avg_u: u64 = @bitCast(@as(i64, rm.average_score));
        rm.average_score = @bitCast(@as(u32, @truncate((value_u *% w +% avg_u *% (scale - w)) / scale)));
    }

    if (rm.mean_squared_score == root_mean_sq_sentinel) {
        rm.mean_squared_score = value * av;
    } else {
        const v2_u: u64 = @bitCast(v2);
        const mss_u: u64 = @bitCast(@as(i64, rm.mean_squared_score));
        rm.mean_squared_score = @bitCast(@as(u32, @truncate((v2_u *% w_mss +% mss_u *% (scale - w_mss)) / scale)));
    }

    if (move_count == 1 or value > alpha) {
        rm.score = value;
        rm.uci_score = value;
        rm.sel_depth = ctx.sel_depth.*;
        rm.score_lowerbound = false;
        rm.score_upperbound = false;
        if (value >= beta) {
            rm.score_lowerbound = true;
            rm.uci_score = beta;
        } else if (value <= alpha) {
            rm.score_upperbound = true;
            rm.uci_score = alpha;
        }
        // Keep pv[0] (== move) with pv.resize(1), then append the child PV.
        rm.pv.length = 1;
        if (child_pv) |c| {
            var j: usize = 0;
            while (j < c.length) : (j += 1) rm.pv.moves[1 + j] = c.moves[j];
            rm.pv.length = 1 + c.length;
        }
        if (move_count > 1 and ctx.pv_idx.* == 0)
            _ = @atomicRmw(u64, ctx.best_move_changes, .Add, 1, .monotonic);
    } else rm.score = -q_value_inf;
}

// Read the root TT move from the rootMoves array (a contiguous RootMove array)
// handed over by worker_state.
pub inline fn rootTtMove(ctx: *const QCtx) u16 {
    return ctx.root_moves[ctx.pv_idx.*].pv.moves[0];
}

// Compare pv[0] against move over [pvIdx, pvLast).
pub inline fn rootInList(ctx: *const QCtx, move: u16) bool {
    var i: usize = ctx.pv_idx.*;
    const last = ctx.pv_last.*;
    while (i < last) : (i += 1) {
        if (ctx.root_moves[i].pv.moves[0] == move) return true;
    }
    return false;
}

// Load the shared stop flag (monotonic atomic byte, relaxed ordering); the
// search aborts when it is set.
pub inline fn searchStopped(ctx: *const QCtx) bool {
    return @atomicLoad(u8, ctx.stop, .monotonic) != 0;
}

// Compare the move directly against lastIterationPV for the follow-pv test;
// lastIterationPV is an inline PVMoves member (fixed Move array + length).
pub inline fn inLastIterPv(ctx: *const QCtx, ply_minus_1: i32, move: u16) bool {
    const pv = ctx.last_iter_pv;
    const idx: usize = @intCast(ply_minus_1);
    return idx < pv.length and pv.moves[idx] == move;
}

test {
    @import("std").testing.refAllDecls(@This());
}
