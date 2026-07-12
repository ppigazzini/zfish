// Root-search bookkeeping and time/stop control.
// These operate purely on the QCtx (built by search_setup) plus the clock and
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

    const elapsed: i64 = if (ts.tm_use_nodes_time != 0)
        @intCast(ctx.nodes.*)
    else
        time_source.now() - ts.tm_start_time;

    if (ts.ponder.?.* != 0) return;

    const ns: u64 = ctx.nodes.*;
    if ((ts.use_time_management != 0 and (elapsed > ts.tm_maximum_time or ts.stop_on_ponderhit.?.* != 0)) or
        (ts.lim_movetime != 0 and elapsed >= ts.lim_movetime) or
        (ts.lim_nodes != 0 and ns >= ts.lim_nodes))
    {
        @atomicStore(u8, ts.stop_write.?, 1, .monotonic);
    }
}

// Per-move root bookkeeping. Finds the
// RootMove for `move` in [pvIdx, pvLast) (unique, guaranteed present by the
// rootInList filter), updates its effort / averageScore / meanSquaredScore, and
// on a PV move stores the score/bound flags/PV. Uses C truncating division
// (@divTrunc) and i32 arithmetic (no overflow: both squared terms are
// < VALUE_INFINITE^2, sum < INT_MAX).
const root_mean_sq_sentinel: c_int = -(q_value_inf * q_value_inf);
pub fn rootUpdate(ctx: *const QCtx, move: u16, value: c_int, nodes_delta: u64, move_count: c_int, alpha: c_int, beta: c_int, child_pv: ?*const PVMoves) void {
    var idx: usize = ctx.pv_idx.*;
    const last = ctx.pv_last.*;
    while (idx < last and ctx.root_moves[idx].pv.moves[0] != move) : (idx += 1) {}
    const rm = &ctx.root_moves[idx];

    rm.effort += nodes_delta;
    rm.average_score = if (rm.average_score != -q_value_inf) @divTrunc(value + rm.average_score, 2) else value;
    const av = if (value < 0) -value else value;
    const v_sq = value * av;
    rm.mean_squared_score = if (rm.mean_squared_score != root_mean_sq_sentinel) @divTrunc(v_sq + rm.mean_squared_score, 2) else v_sq;

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
        // pv.resize(1) keeps pv[0] (== move), then append the child PV.
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

// Reads the root TT move from the rootMoves array (a contiguous RootMove array)
// handed over by worker_state.
pub inline fn rootTtMove(ctx: *const QCtx) u16 {
    return ctx.root_moves[ctx.pv_idx.*].pv.moves[0];
}

// Compares pv[0] against move over [pvIdx, pvLast).
pub inline fn rootInList(ctx: *const QCtx, move: u16) bool {
    var i: usize = ctx.pv_idx.*;
    const last = ctx.pv_last.*;
    while (i < last) : (i += 1) {
        if (ctx.root_moves[i].pv.moves[0] == move) return true;
    }
    return false;
}

// The search aborts when the shared stop flag is set: a monotonic atomic byte
// load (relaxed ordering).
pub inline fn searchStopped(ctx: *const QCtx) bool {
    return @atomicLoad(u8, ctx.stop, .monotonic) != 0;
}

// lastIterationPV is an inline PVMoves member (fixed Move array + length); the
// follow-pv test compares the move directly against it.
pub inline fn inLastIterPv(ctx: *const QCtx, ply_minus_1: c_int, move: u16) bool {
    const pv = ctx.last_iter_pv;
    const idx: usize = @intCast(ply_minus_1);
    return idx < pv.length and pv.moves[idx] == move;
}

test {
    @import("std").testing.refAllDecls(@This());
}
