const std = @import("std");

pub const TimemanInput = struct {
    time_us: i64,
    inc_us: i64,
    start_time: i64,
    npmsec: i64,
    move_overhead: i64,
    available_nodes: i64,
    current_optimum_time: i64,
    current_maximum_time: i64,
    movestogo: c_int,
    ply: c_int,
    original_time_adjust: f64,
    ponder: u8,
};

pub const TimemanOutput = struct {
    time_us: i64,
    inc_us: i64,
    start_time: i64,
    npmsec: i64,
    available_nodes: i64,
    optimum_time: i64,
    maximum_time: i64,
    original_time_adjust: f64,
    use_nodes_time: u8,
};

pub fn init(input: TimemanInput) TimemanOutput {
    var output = TimemanOutput{
        .time_us = input.time_us,
        .inc_us = input.inc_us,
        .start_time = input.start_time,
        .npmsec = input.npmsec,
        .available_nodes = input.available_nodes,
        .optimum_time = input.current_optimum_time,
        .maximum_time = input.current_maximum_time,
        .original_time_adjust = input.original_time_adjust,
        .use_nodes_time = if (input.npmsec != 0) 1 else 0,
    };

    if (input.time_us == 0) {
        return output;
    }

    var move_overhead = input.move_overhead;

    if (output.use_nodes_time != 0) {
        if (output.available_nodes == -1) {
            output.available_nodes = input.npmsec * input.time_us;
        }

        output.time_us = output.available_nodes;
        output.inc_us *= input.npmsec;
        move_overhead *= input.npmsec;
    }

    const scale_factor: i64 = if (output.use_nodes_time != 0) input.npmsec else 1;
    const scaled_time = @divTrunc(output.time_us, scale_factor);

    var mtg: i64 = if (input.movestogo != 0)
        @min(@as(i64, input.movestogo), 50)
    else
        50;

    if (scaled_time < 1000) {
        mtg = @intFromFloat(@as(f64, @floatFromInt(scaled_time)) * 0.05);
    }

    const time_left = @max(
        @as(i64, 1),
        output.time_us + output.inc_us * (mtg - 1) - move_overhead * (2 + mtg),
    );

    var opt_scale: f64 = undefined;
    var max_scale: f64 = undefined;
    var original_time_adjust = output.original_time_adjust;

    if (input.movestogo == 0) {
        if (original_time_adjust < 0) {
            original_time_adjust = 0.3272 * @log10(@as(f64, @floatFromInt(time_left))) - 0.4141;
        }

        const log_time_in_sec =
            @log10(@as(f64, @floatFromInt(scaled_time)) / 1000.0);
        const opt_constant = @min(0.0029869 + 0.00033554 * log_time_in_sec, 0.004905);
        const max_constant = @max(3.3744 + 3.0608 * log_time_in_sec, 3.1441);

        opt_scale = @min(
            0.012112 + std.math.pow(f64, @as(f64, @floatFromInt(input.ply)) + 3.22713, 0.46866) * opt_constant,
            0.19404 * @as(f64, @floatFromInt(output.time_us)) / @as(f64, @floatFromInt(time_left)),
        ) * original_time_adjust;

        max_scale = @min(6.873, max_constant + @as(f64, @floatFromInt(input.ply)) / 12.352);
    } else {
        opt_scale = @min(
            (0.88 + @as(f64, @floatFromInt(input.ply)) / 116.4) / @as(f64, @floatFromInt(mtg)),
            0.88 * @as(f64, @floatFromInt(output.time_us)) / @as(f64, @floatFromInt(time_left)),
        );
        max_scale = 1.3 + 0.11 * @as(f64, @floatFromInt(mtg));
    }

    output.optimum_time = @intFromFloat(@max(
        1.0,
        opt_scale * @as(f64, @floatFromInt(time_left)),
    ));
    output.maximum_time = @intFromFloat(@max(
        @as(f64, @floatFromInt(output.optimum_time)),
        @min(
            0.8097 * @as(f64, @floatFromInt(output.time_us)) - @as(f64, @floatFromInt(move_overhead)),
            max_scale * @as(f64, @floatFromInt(output.optimum_time)),
        ),
    ));

    if (input.ponder != 0) {
        output.optimum_time += @divTrunc(output.optimum_time, 4);
    }

    output.original_time_adjust = original_time_adjust;
    return output;
}

// --- tests--------------------------------------------------------------
// Pure port of Stockfish TimeManagement::init. The exact float outputs are not
// pinned (they track upstream constants); these assert the structural invariants.
const base = TimemanInput{
    .time_us = 60_000_000,
    .inc_us = 100_000,
    .start_time = 0,
    .npmsec = 0,
    .move_overhead = 10_000,
    .available_nodes = -1,
    .current_optimum_time = 0,
    .current_maximum_time = 0,
    .movestogo = 0,
    .ply = 20,
    .original_time_adjust = -1,
    .ponder = 0,
};

test "timeman: zero time is a pass-through" {
    var in = base;
    in.time_us = 0;
    in.current_optimum_time = 111;
    in.current_maximum_time = 222;
    const out = init(in);
    try std.testing.expectEqual(@as(i64, 111), out.optimum_time);
    try std.testing.expectEqual(@as(i64, 222), out.maximum_time);
    try std.testing.expectEqual(@as(u8, 0), out.use_nodes_time);
}

test "timeman: a real budget yields 0 < optimum <= maximum" {
    const out = init(base);
    try std.testing.expect(out.optimum_time > 0);
    try std.testing.expect(out.maximum_time >= out.optimum_time);
    // and with an explicit movestogo
    var mtg = base;
    mtg.movestogo = 30;
    const out2 = init(mtg);
    try std.testing.expect(out2.optimum_time > 0);
    try std.testing.expect(out2.maximum_time >= out2.optimum_time);
}

test "timeman: ponder boosts optimum by exactly 25%" {
    var in = base;
    in.original_time_adjust = 1.0;
    const no_ponder = init(in);
    in.ponder = 1;
    const with_ponder = init(in);
    try std.testing.expectEqual(
        no_ponder.optimum_time + @divTrunc(no_ponder.optimum_time, 4),
        with_ponder.optimum_time,
    );
}

test "timeman: npmsec != 0 enables nodes-time mode" {
    var in = base;
    in.npmsec = 600;
    in.time_us = 1000;
    in.movestogo = 40;
    try std.testing.expectEqual(@as(u8, 1), init(in).use_nodes_time);
    try std.testing.expectEqual(@as(u8, 0), init(base).use_nodes_time);
}
