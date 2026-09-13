// Probe the tablebases at an interior node -- upstream search.cpp Step 7.
//
// Own the WDL probe the node recursion makes before the move loop: the gate on the worker's
// Tablebases::Config, the VALUE_TB-range score, the TT store on a cutoff, and the PV-node
// alpha/max_value adjustment. A default build has cardinality 0, so bench never enters here;
// that is also why it lives beside searchImpl rather than inside it -- the node body is the
// hottest function in the engine and this block is cold.
//
// Path-imported by search_main.zig, so `@import("tt")` and friends resolve through the
// search_main module's import table.

const tt = @import("tt");
const tb_source = @import("tb_source");
const search = @import("search");
const position_types = @import("position_types");
const search_types = @import("search_types");
const search_ctx = @import("search_ctx");
const sv = @import("search_values.zig");

const Position = position_types.Position;
const SearchStack = search_types.SearchStack;
const QCtx = search_ctx.QCtx;

// Force a check of time on the next occasion after a TB probe (search.cpp:917);
// calls_cnt is null off the main thread, mirroring upstream's is_mainthread()
// guard. Keep the store out of line: the TB block never runs on a default build
// (cardinality == 0), and an inline write to the counter perturbs the node
// body's register allocation.
noinline fn tbForceTimeCheck(ctx: *const QCtx) void {
    if (ctx.time_state.calls_cnt) |cc| cc.* = 0;
}

/// Name what the probe leaves for the caller. `none` is every path that did not probe or
/// found nothing to say; `cutoff` returns the value from the node; `raise_alpha` and
/// `cap_max` are the two PV-node adjustments upstream makes before falling through to the
/// move loop.
pub const Outcome = union(enum) {
    none,
    cutoff: i32,
    raise_alpha: i32,
    cap_max: i32,
};

/// Probe the WDL of the current (non-root, non-excluded) position when it is small enough,
/// has a zeroed rule50 counter and no castling rights; on success score it in the
/// VALUE_TB..VALUE_TB_WIN range and cut or adjust. Gate on the worker's tb_config.cardinality,
/// which is 0 without a SyzygyPath, so a default build (and bench) never enters here and the
/// node count is unchanged.
pub fn probeAtNode(
    ctx: *const QCtx,
    pos_ptr: *Position,
    ss: *const SearchStack,
    comptime pv_node: bool,
    depth: i32,
    alpha: i32,
    beta: i32,
    pos_key: u64,
    writer: anytype,
) Outcome {
    const pos = pos_ptr;
    const tb_cfg = &ctx.worker.tb_config;
    const cardinality = tb_cfg.cardinality;
    if (cardinality == 0) return .none;

    const pieces_count: i32 = @popCount(pos.by_type_bb[0]);
    const probe_depth = tb_cfg.probe_depth;
    if (pieces_count > cardinality or
        (pieces_count == cardinality and depth < probe_depth) or
        pos.st.rule50 != 0 or pos.st.castling_rights != 0) return .none;

    const res = tb_source.probeWdlPos(pos_ptr);
    tbForceTimeCheck(ctx);
    if (res.available == 0) return .none;

    @atomicStore(u64, &ctx.worker.tb_hits, @atomicLoad(u64, &ctx.worker.tb_hits, .monotonic) + 1, .monotonic);
    const draw_score: i32 = if (tb_cfg.use_rule50) 1 else 0;
    const tb_value: i32 = sv.value_tb - ss.ply;
    const wdl = res.wdl;
    const value: i32 = if (wdl < -draw_score)
        -tb_value
    else if (wdl > draw_score)
        tb_value
    else
        sv.value_draw + 2 * wdl * draw_score;
    const b: u8 = if (wdl < -draw_score)
        sv.bound_upper
    else if (wdl > draw_score)
        sv.bound_lower
    else
        sv.bound_exact;
    if (b == sv.bound_exact or (if (b == sv.bound_lower) value >= beta else value <= alpha)) {
        tt.entrySave(writer, pos_key, search.valueToTt(value, ss.ply), @intFromBool(ss.tt_pv), b, @min(sv.max_ply - 1, depth + 6), sv.depth_none, 0, sv.value_none, ctx.generation);
        return .{ .cutoff = value };
    }
    if (pv_node) {
        if (b == sv.bound_lower) return .{ .raise_alpha = value };
        return .{ .cap_max = value };
    }
    return .none;
}
