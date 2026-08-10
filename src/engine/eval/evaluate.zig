const std = @import("std");

pub const EvalInput = struct {
    psqt: i32,
    positional: i32,
    optimism: i32,
    material: i32,
    rule50_count: i32,
    value_tb_loss_in_max_ply: i32,
    value_tb_win_in_max_ply: i32,
};

pub const EvalTraceInput = struct {
    inner_trace_ptr: [*]const u8,
    inner_trace_len: usize,
    nnue_internal_value: i32,
    nnue_white_cp: i32,
    final_white_cp: i32,
};

/// Piece values for the SPINE-ISOLATION stub eval, in the order pawn, knight, bishop, rook,
/// queen. Deliberately round numbers with no relation to either engine's real tables: the only
/// property that matters is that upstream's patched `Eval::evaluate` uses the SAME five, so both
/// engines score every position identically and therefore search the SAME TREE. A stub that
/// diverged by one centipawn would produce two different node counts, and the whole comparison
/// would be two different workloads -- which is exactly how an earlier attempt at this
/// experiment concluded "the spine, not the NNUE, is the gap" and was wrong.
pub const stub_piece_values = [5]i32{ 100, 300, 300, 500, 900 };

/// Score a position by material alone, from the side to move's perspective. Counts are indexed
/// pawn..queen. No optimism, no complexity blend, no 50-move damping and no TB clamp -- the
/// clamp would be a no-op here anyway (max material is far inside the TB bounds), and leaving
/// all four out of BOTH engines keeps the two stubs a line-for-line match.
pub fn stubMaterialValue(white: [5]i32, black: [5]i32, side_to_move_is_white: bool) i32 {
    var w: i32 = 0;
    var b: i32 = 0;
    for (stub_piece_values, 0..) |v, i| {
        w += v * white[i];
        b += v * black[i];
    }
    return if (side_to_move_is_white) w - b else b - w;
}

pub fn computeValue(input: EvalInput) i32 {
    var nnue = @as(i64, input.psqt) + @as(i64, input.positional); // upstream 6088838: yeet psqt weights

    const nnue_complexity = absInt(@as(i64, input.psqt) - @as(i64, input.positional));
    var optimism = @as(i64, input.optimism);
    optimism += @divTrunc(optimism * nnue_complexity, 476);
    nnue -= @divTrunc(nnue * nnue_complexity, 18236);

    var value = @divTrunc(
        nnue * (91000 + @as(i64, input.material)) + optimism * 7675,
        91000,
    );

    value -= @divTrunc(value * @as(i64, input.rule50_count), 199);
    value = std.math.clamp(
        value,
        @as(i64, input.value_tb_loss_in_max_ply) + 1,
        @as(i64, input.value_tb_win_in_max_ply) - 1,
    );

    return @intCast(value);
}

pub fn formatTrace(input: EvalTraceInput) ?[]u8 {
    return formatTraceAlloc(input) catch null;
}

fn formatTraceAlloc(input: EvalTraceInput) ![]u8 {
    const allocator = std.heap.c_allocator;
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

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

    return buffer.toOwnedSlice(allocator);
}

fn appendIntLine(
    buffer: *std.ArrayList(u8),
    prefix: []const u8,
    value: i32,
    suffix: []const u8,
) !void {
    // Emit `showpos` + the value, UNPADDED. This is not C's `%+15d`: upstream is C++
    // iostreams, and its `<< std::setw(15)` (evaluate.cpp:87) is a ONE-SHOT manipulator
    // consumed by the very next insertion -- the "NNUE evaluation          " literal, which
    // is already 25 chars, so it pads nothing and resets the width to 0 before the value is
    // inserted. Padding the value to 15 (the old reading) inserted 12 extra spaces:
    //   upstream: `NNUE evaluation          +10`
    //   zfish:    `NNUE evaluation                      +10`
    // std.fmt has no force-sign flag, so emit the sign explicitly.
    var signed: [32]u8 = undefined;
    const body = std.fmt.bufPrint(&signed, "{c}{d}", .{
        @as(u8, if (value < 0) '-' else '+'),
        @abs(value),
    }) catch unreachable;
    try buffer.appendSlice(std.heap.c_allocator, prefix);
    try buffer.appendSlice(std.heap.c_allocator, body);
    try buffer.appendSlice(std.heap.c_allocator, suffix);
}

fn appendFloatLine(
    buffer: *std.ArrayList(u8),
    prefix: []const u8,
    value: f64,
    suffix: []const u8,
) !void {
    // Forced sign + 2 decimals, UNPADDED -- see appendIntLine: upstream's one-shot
    // `std::setw(15)` is consumed by the preceding string literal, never by the value, so
    // `%+15.2f` was the wrong model. std.fmt is byte-identical to C `%.2f` here because
    // `value` is always centipawns*0.01 -- a value on the 2-decimal grid, so no third
    // decimal exists and C's round-half-to-even can never disagree with std.fmt's
    // round-half-away. Proven byte-exact for every cp in [-2_000_000, 2_000_000] (60x the
    // mate-bounded eval range). std.fmt has no force-sign flag, so emit the sign explicitly.
    var digits: [32]u8 = undefined;
    const body = std.fmt.bufPrint(&digits, "{c}{d:.2}", .{
        @as(u8, if (value < 0) '-' else '+'),
        @abs(value),
    }) catch unreachable;
    try buffer.appendSlice(std.heap.c_allocator, prefix);
    try buffer.appendSlice(std.heap.c_allocator, body);
    try buffer.appendSlice(std.heap.c_allocator, suffix);
}

fn absInt(value: i64) i64 {
    return if (value < 0) -value else value;
}

// --- tests --------------------------------------------------------------
test "computeValue: zeros -> 0; equal psqt/positional passes through" {
    try std.testing.expectEqual(@as(i32, 0), computeValue(.{
        .psqt = 0,
        .positional = 0,
        .optimism = 0,
        .material = 0,
        .rule50_count = 0,
        .value_tb_loss_in_max_ply = -30000,
        .value_tb_win_in_max_ply = 30000,
    }));
    // psqt == positional -> zero complexity, zero optimism -> value == psqt+positional
    try std.testing.expectEqual(@as(i32, 200), computeValue(.{
        .psqt = 100,
        .positional = 100,
        .optimism = 0,
        .material = 0,
        .rule50_count = 0,
        .value_tb_loss_in_max_ply = -30000,
        .value_tb_win_in_max_ply = 30000,
    }));
}

test "computeValue: clamps to the tb bounds" {
    try std.testing.expectEqual(@as(i32, 30000 - 1), computeValue(.{
        .psqt = 100000,
        .positional = 100000,
        .optimism = 0,
        .material = 0,
        .rule50_count = 0,
        .value_tb_loss_in_max_ply = -30000,
        .value_tb_win_in_max_ply = 30000,
    }));
}
