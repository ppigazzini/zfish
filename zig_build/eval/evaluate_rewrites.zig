const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
});

pub const EvalInput = extern struct {
    psqt: c_int,
    positional: c_int,
    optimism: c_int,
    material: c_int,
    rule50_count: c_int,
    value_tb_loss_in_max_ply: c_int,
    value_tb_win_in_max_ply: c_int,
};

pub const EvalTraceInput = extern struct {
    inner_trace_ptr: [*]const u8,
    inner_trace_len: usize,
    nnue_internal_value: c_int,
    nnue_white_cp: c_int,
    final_white_cp: c_int,
};

pub fn computeValue(input: EvalInput) c_int {
    var nnue = @divTrunc(125 * @as(i64, input.psqt) + 131 * @as(i64, input.positional), 128);

    const nnue_complexity = absInt(@as(i64, input.psqt) - @as(i64, input.positional));
    var optimism = @as(i64, input.optimism);
    optimism += @divTrunc(optimism * nnue_complexity, 476);
    nnue -= @divTrunc(nnue * nnue_complexity, 18236);

    var value = @divTrunc(
        nnue * (77871 + @as(i64, input.material))
            + optimism * (7191 + @as(i64, input.material)),
        77871,
    );

    value -= @divTrunc(value * @as(i64, input.rule50_count), 199);
    value = std.math.clamp(
        value,
        @as(i64, input.value_tb_loss_in_max_ply) + 1,
        @as(i64, input.value_tb_win_in_max_ply) - 1,
    );

    return @intCast(value);
}

pub fn formatTrace(input: EvalTraceInput) ?[*:0]u8 {
    return formatTraceAlloc(input) catch null;
}

fn formatTraceAlloc(input: EvalTraceInput) ![*:0]u8 {
    const allocator = std.heap.c_allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    try buffer.append(allocator, '\n');
    try buffer.appendSlice(allocator, input.inner_trace_ptr[0..input.inner_trace_len]);
    try buffer.append(allocator, '\n');

    try appendIntLine(
        &buffer,
        "NNUE evaluation          ",
        input.nnue_internal_value,
        " (side to move, internal units)\n",
    );
    try appendFloatLine(
        &buffer,
        "NNUE evaluation        ",
        @as(f64, @floatFromInt(input.nnue_white_cp)) * 0.01,
        " (white side)\n",
    );
    try appendFloatLine(
        &buffer,
        "Final evaluation      ",
        @as(f64, @floatFromInt(input.final_white_cp)) * 0.01,
        " (white side) [with scaled NNUE, ...]\n",
    );

    const result = try allocator.allocSentinel(u8, buffer.items.len, 0);
    @memcpy(result[0..buffer.items.len], buffer.items);
    return result.ptr;
}

fn appendIntLine(
    buffer: *std.ArrayList(u8),
    prefix: []const u8,
    value: c_int,
    suffix: []const u8,
) !void {
    var numeric: [64]u8 = undefined;
    const len = c.snprintf(&numeric, numeric.len, "%+15d", value);
    try buffer.appendSlice(std.heap.c_allocator, prefix);
    try buffer.appendSlice(std.heap.c_allocator, numeric[0..@intCast(len)]);
    try buffer.appendSlice(std.heap.c_allocator, suffix);
}

fn appendFloatLine(
    buffer: *std.ArrayList(u8),
    prefix: []const u8,
    value: f64,
    suffix: []const u8,
) !void {
    var numeric: [64]u8 = undefined;
    const len = c.snprintf(&numeric, numeric.len, "%+15.2f", value);
    try buffer.appendSlice(std.heap.c_allocator, prefix);
    try buffer.appendSlice(std.heap.c_allocator, numeric[0..@intCast(len)]);
    try buffer.appendSlice(std.heap.c_allocator, suffix);
}

fn absInt(value: i64) i64 {
    return if (value < 0) -value else value;
}
