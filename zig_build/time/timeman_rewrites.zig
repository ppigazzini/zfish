const std = @import("std");

pub const TimemanInput = extern struct {
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

pub const TimemanOutput = extern struct {
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
