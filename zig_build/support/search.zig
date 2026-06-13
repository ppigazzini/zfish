const std = @import("std");

const value_draw: c_int = 0;
const value_none: c_int = 32002;
const max_ply: c_int = 246;
const value_mate: c_int = 32000;
const value_mate_in_max_ply: c_int = value_mate - max_ply;
const value_mated_in_max_ply: c_int = -value_mate_in_max_ply;
const value_tb: c_int = value_mate_in_max_ply - 1;
const value_tb_win_in_max_ply: c_int = value_tb - max_ply;
const value_tb_loss_in_max_ply: c_int = -value_tb_win_in_max_ply;

fn isValid(v: c_int) bool {
    return v != value_none;
}

fn isWin(v: c_int) bool {
    return v >= value_tb_win_in_max_ply;
}

fn isLoss(v: c_int) bool {
    return v <= value_tb_loss_in_max_ply;
}

fn isMate(v: c_int) bool {
    return v >= value_mate_in_max_ply;
}

fn isMated(v: c_int) bool {
    return v <= value_mated_in_max_ply;
}

pub fn toCorrectedStaticEval(v: c_int, cv: c_int) c_int {
    const adjusted = v + @divTrunc(cv, 131072);
    return std.math.clamp(adjusted, value_tb_loss_in_max_ply + 1, value_tb_win_in_max_ply - 1);
}

pub fn valueDraw(nodes: usize) c_int {
    return value_draw - 1 + @as(c_int, @intCast(nodes & 0x2));
}

// Adjusts a mate or TB score to "plies to mate from the current position"
// before storing it in the transposition table. Standard scores are unchanged.
pub fn valueToTt(v: c_int, ply: c_int) c_int {
    if (isWin(v)) return v + ply;
    if (isLoss(v)) return v - ply;
    return v;
}

// Inverse of valueToTt(): adjusts a mate/TB score read from the transposition
// table back to plies-from-root, downgrading potentially false mate/TB scores
// related to the 50-move rule and graph-history interaction.
pub fn valueFromTt(v: c_int, ply: c_int, r50c: c_int) c_int {
    if (!isValid(v)) return value_none;

    // handle TB win or better
    if (isWin(v)) {
        // Downgrade a potentially false mate score.
        if (isMate(v) and value_mate - v > 100 - r50c)
            return value_tb_win_in_max_ply - 1;

        // Downgrade a potentially false TB score.
        if (value_tb - v > 100 - r50c)
            return value_tb_win_in_max_ply - 1;

        return v - ply;
    }

    // handle TB loss or worse
    if (isLoss(v)) {
        // Downgrade a potentially false mate score.
        if (isMated(v) and value_mate + v > 100 - r50c)
            return value_tb_loss_in_max_ply + 1;

        // Downgrade a potentially false TB score.
        if (value_tb + v > 100 - r50c)
            return value_tb_loss_in_max_ply + 1;

        return v + ply;
    }

    return v;
}

// Populate the reductions[] lookup table: reductions[i] = int(2834/128.0 * ln i)
// for i in [1, count). Index 0 is left untouched, matching upstream clear().
pub fn fillReductions(reductions_ptr: [*]c_int, count: usize) void {
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const logv = @log(@as(f64, @floatFromInt(i)));
        reductions_ptr[i] = @intFromFloat(2834.0 / 128.0 * logv);
    }
}

pub fn reduction(
    reductions_ptr: [*]const c_int,
    depth: c_int,
    move_number: c_int,
    delta: c_int,
    root_delta: c_int,
    improving: bool,
) c_int {
    const depth_index: usize = @intCast(depth);
    const move_index: usize = @intCast(move_number);
    const reduction_scale = reductions_ptr[depth_index] * reductions_ptr[move_index];
    return reduction_scale - @divTrunc(delta * 617, root_delta) + (if (!improving) @divTrunc(reduction_scale * 194, 512) else 0) + 1027;
}
