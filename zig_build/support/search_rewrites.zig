const std = @import("std");

const value_draw: c_int = 0;
const max_ply: c_int = 246;
const value_mate: c_int = 32000;
const value_mate_in_max_ply: c_int = value_mate - max_ply;
const value_tb: c_int = value_mate_in_max_ply - 1;
const value_tb_win_in_max_ply: c_int = value_tb - max_ply;
const value_tb_loss_in_max_ply: c_int = -value_tb_win_in_max_ply;

pub fn toCorrectedStaticEval(v: c_int, cv: c_int) c_int {
    const adjusted = v + @divTrunc(cv, 131072);
    return std.math.clamp(adjusted, value_tb_loss_in_max_ply + 1, value_tb_win_in_max_ply - 1);
}

pub fn valueDraw(nodes: usize) c_int {
    return value_draw - 1 + @as(c_int, @intCast(nodes & 0x2));
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
