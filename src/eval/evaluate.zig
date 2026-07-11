const std = @import("std");

pub const EvalInput = struct {
    psqt: c_int,
    positional: c_int,
    optimism: c_int,
    material: c_int,
    rule50_count: c_int,
    value_tb_loss_in_max_ply: c_int,
    value_tb_win_in_max_ply: c_int,
};

pub const EvalTraceInput = struct {
    inner_trace_ptr: [*]const u8,
    inner_trace_len: usize,
    nnue_internal_value: c_int,
    nnue_white_cp: c_int,
    final_white_cp: c_int,
};

pub fn computeValue(input: EvalInput) c_int {
    var nnue = @as(i64, input.psqt) + @as(i64, input.positional); // upstream 6088838: yeet psqt weights

    const nnue_complexity = absInt(@as(i64, input.psqt) - @as(i64, input.positional));
    var optimism = @as(i64, input.optimism);
    optimism += @divTrunc(optimism * nnue_complexity, 476);
    nnue -= @divTrunc(nnue * nnue_complexity, 18236);

    var value = @divTrunc(
        nnue * (77871 + @as(i64, input.material)) + optimism * (7191 + @as(i64, input.material)),
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
    // C `%+15d` forces a leading sign then space-pads to width 15. std.fmt has no
    // force-sign flag, so emit the sign explicitly, format the magnitude, then pad the
    // resulting string (string padding adds no sign of its own). Byte-identical to C.
    var signed: [32]u8 = undefined;
    const body = std.fmt.bufPrint(&signed, "{c}{d}", .{
        @as(u8, if (value < 0) '-' else '+'),
        @abs(value),
    }) catch unreachable;
    var numeric: [64]u8 = undefined;
    const rendered = std.fmt.bufPrint(&numeric, "{s: >15}", .{body}) catch unreachable;
    try buffer.appendSlice(std.heap.c_allocator, prefix);
    try buffer.appendSlice(std.heap.c_allocator, rendered);
    try buffer.appendSlice(std.heap.c_allocator, suffix);
}

fn appendFloatLine(
    buffer: *std.ArrayList(u8),
    prefix: []const u8,
    value: f64,
    suffix: []const u8,
) !void {
    // `%+15.2f`: forced sign, 2 decimals, right-padded to width 15. std.fmt is
    // byte-identical to C `%.2f` here because `value` is always centipawns*0.01 -- a value
    // on the 2-decimal grid, so no third decimal exists and C's round-half-to-even can
    // never disagree with std.fmt's round-half-away. Proven byte-exact for every cp in
    // [-2_000_000, 2_000_000] (60x the mate-bounded eval range). std.fmt has no force-sign
    // flag, so emit the sign explicitly and pad the resulting string (no sign semantics).
    var digits: [32]u8 = undefined;
    const body = std.fmt.bufPrint(&digits, "{c}{d:.2}", .{
        @as(u8, if (value < 0) '-' else '+'),
        @abs(value),
    }) catch unreachable;
    var numeric: [64]u8 = undefined;
    const rendered = std.fmt.bufPrint(&numeric, "{s: >15}", .{body}) catch unreachable;
    try buffer.appendSlice(std.heap.c_allocator, prefix);
    try buffer.appendSlice(std.heap.c_allocator, rendered);
    try buffer.appendSlice(std.heap.c_allocator, suffix);
}

fn absInt(value: i64) i64 {
    return if (value < 0) -value else value;
}
