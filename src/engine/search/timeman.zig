//! Port Stockfish's TimeManagement::init.
//!
//! EVERY time quantity here is MILLISECONDS, the unit upstream uses and the unit both ends of
//! this call already speak: `limits.time`/`limits.inc` come straight off the UCI `go wtime`/
//! `winc` tokens (uci.zig:59), `Move Overhead` is a spin option in ms, and clock.now() reports
//! ms. That matters because the formula below compares against BARE CONSTANTS that only hold in
//! ms -- `scaled_time < 1000` means "under one second", and `log10(scaled_time / 1000.0)` means
//! "log10 of the seconds remaining". Feed this microseconds and neither line means what it says:
//! the moves-to-go reduction would stop firing and the log would sit three decades off, with the
//! engine silently mis-budgeting every move. No gate in this repo would notice -- bench, parity
//! and every perf harness are node-limited, so they never execute a line of time management.
//! Keep the `_ms` suffixes; they are the only place that invariant is written down.

const std = @import("std");

pub const TimemanInput = struct {
    time_ms: i64,
    inc_ms: i64,
    start_time: i64,
    npmsec: i64,
    movetime_ms: i64,
    move_overhead: i64,
    available_nodes: i64,
    current_optimum_time: i64,
    current_maximum_time: i64,
    movestogo: i32,
    ply: i32,
    original_time_adjust: f64,
    ponder: u8,
};

// Stand for "no time bound" in the two budget members. Half of i64's range rather than all of
// it, so the comparisons that add to a budget (`elapsed > maximum`, and the sums
// search_id_loop forms from it) cannot overflow the way an actual maxInt would.
pub const no_bound: i64 = std.math.maxInt(i64) / 2;

pub const TimemanOutput = struct {
    time_ms: i64,
    inc_ms: i64,
    start_time: i64,
    npmsec: i64,
    movetime_ms: i64,
    available_nodes: i64,
    optimum_time: i64,
    maximum_time: i64,
    original_time_adjust: f64,
    use_nodes_time: u8,
};

pub fn init(input: TimemanInput) TimemanOutput {
    var output = TimemanOutput{
        .time_ms = input.time_ms,
        .inc_ms = input.inc_ms,
        .start_time = input.start_time,
        .npmsec = input.npmsec,
        .movetime_ms = input.movetime_ms,
        .available_nodes = input.available_nodes,
        .optimum_time = input.current_optimum_time,
        .maximum_time = input.current_maximum_time,
        .original_time_adjust = input.original_time_adjust,
        .use_nodes_time = if (input.npmsec != 0) 1 else 0,
    };

    // Convert `movetime` into the unit the search compares it in. Under `nodestime` the
    // search's `elapsed` is a NODE count, and checkTime tests `elapsed >= movetime` against
    // the raw UCI figure -- so `go movetime N` used to stop after N nodes rather than after
    // the N milliseconds' worth of nodes the caller asked for. Upstream ceb059eb scales the
    // limit here instead, beside the clock and the increment, and does it BEFORE the
    // no-clock early return so `go movetime N` alone is converted too.
    if (output.use_nodes_time != 0) output.movetime_ms *= input.npmsec;

    // No clock for the SIDE TO MOVE. Write both budgets anyway.
    //
    // The readers are gated by `use_time_management`, which is `time[WHITE] or time[BLACK]`
    // (search_setup.zig) -- so it is true whenever EITHER side has a clock, and `go btime N`
    // with White to move passes the guard while taking this early return. Leaving the two
    // members alone is therefore not "no time management", it is the PREVIOUS search's:
    // `go wtime 200 btime 200` followed by `go btime 1000` stopped at depth 6 in about a
    // millisecond, spending a budget that belonged to the move before it. On the first search
    // of a process they are still zero, which is an instant move at depth 3. Neither is a
    // decision anybody made.
    //
    // NO_BOUND RATHER THAN ZERO, because the value chosen IS the behaviour on this input.
    // Zero makes the case an instant move; no_bound makes it a search that runs until
    // something else stops it -- `stop`, a node limit, or the caller -- and that is the answer
    // that cannot lose a game on a clock the caller never sent. A real GUI sends both clocks;
    // this states once what the malformed case means instead of letting it fall out of
    // whatever the last search left behind.
    //
    // Upstream reads two uninitialised members here (memcheck reports both, at `check_time`'s
    // `elapsed > tm.maximum()` and at iterative_deepening's `min(totalTime, tm.maximum())`),
    // so there is no upstream behaviour to be faithful TO on this input -- which is why this
    // costs the bench nothing: it is a path no bench, golden or differential reaches.
    if (input.time_ms == 0) {
        output.optimum_time = no_bound;
        output.maximum_time = no_bound;
        return output;
    }

    var move_overhead = input.move_overhead;

    if (output.use_nodes_time != 0) {
        if (output.available_nodes == -1) {
            output.available_nodes = input.npmsec * input.time_ms;
        }

        output.time_ms = output.available_nodes;
        output.inc_ms *= input.npmsec;
        move_overhead *= input.npmsec;
    }

    const scale_factor: i64 = if (output.use_nodes_time != 0) input.npmsec else 1;
    const scaled_time = @divTrunc(output.time_ms, scale_factor);

    var mtg: i64 = if (input.movestogo != 0)
        @min(@as(i64, input.movestogo), 50)
    else
        50;

    if (scaled_time < 1000) {
        mtg = @intFromFloat(@as(f64, @floatFromInt(scaled_time)) * 0.05);
    }

    const time_left = @max(
        @as(i64, 1),
        output.time_ms + output.inc_ms * (mtg - 1) - move_overhead * (2 + mtg),
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
            0.19404 * @as(f64, @floatFromInt(output.time_ms)) / @as(f64, @floatFromInt(time_left)),
        ) * original_time_adjust;

        max_scale = @min(6.873, max_constant + @as(f64, @floatFromInt(input.ply)) / 12.352);
    } else {
        opt_scale = @min(
            (0.88 + @as(f64, @floatFromInt(input.ply)) / 116.4) / @as(f64, @floatFromInt(mtg)),
            0.88 * @as(f64, @floatFromInt(output.time_ms)) / @as(f64, @floatFromInt(time_left)),
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
            0.8097 * @as(f64, @floatFromInt(output.time_ms)) - @as(f64, @floatFromInt(move_overhead)),
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
// Mirror Stockfish's TimeManagement::init. The exact float outputs are not
// pinned (they track upstream constants); these assert the structural invariants.
const base = TimemanInput{
    .time_ms = 60_000, // 60s + 0.1s, the classic bullet TC -- in MILLISECONDS, as the engine
    .inc_ms = 100, // feeds it. The old values were these three scaled by 1000, i.e. read as
    .start_time = 0, // microseconds; they described a 16-hour game and exercised a branch of the
    .npmsec = 0, // formula (scaled_time >= 1000) that a real bullet TC never takes.
    .movetime_ms = 0,
    .move_overhead = 10,
    .available_nodes = -1,
    .current_optimum_time = 0,
    .current_maximum_time = 0,
    .movestogo = 0,
    .ply = 20,
    .original_time_adjust = -1,
    .ponder = 0,
};

test "timeman: no clock for the side to move yields no bound, not the last search's budget" {
    // This test used to assert the pass-through -- that 111 and 222 came back out -- which
    // PINNED the defect rather than the behaviour. The readers are gated by
    // `use_time_management`, which is `time[WHITE] or time[BLACK]`, so `go btime N` with White
    // to move passes the guard and takes this path; carrying the incoming values then spends
    // the PREVIOUS search's budget on this one. Measured before the fix: `go wtime 200 btime
    // 200` followed by `go btime 1000` stopped at depth 6 in about a millisecond.
    var in = base;
    in.time_ms = 0;
    in.current_optimum_time = 111; // the previous search's budget, which must NOT survive
    in.current_maximum_time = 222;
    const out = init(in);
    try std.testing.expectEqual(no_bound, out.optimum_time);
    try std.testing.expectEqual(no_bound, out.maximum_time);
    try std.testing.expectEqual(@as(u8, 0), out.use_nodes_time);

    // A fresh process carries zeros rather than a stale budget, and zero is the other wrong
    // answer: an instant move at depth 3. The path must not distinguish the two.
    var fresh = base;
    fresh.time_ms = 0;
    const out_fresh = init(fresh);
    try std.testing.expectEqual(no_bound, out_fresh.optimum_time);
    try std.testing.expectEqual(no_bound, out_fresh.maximum_time);

    // no_bound must survive the arithmetic that reads it. search_id_loop forms sums against
    // `maximum`, so half the range rather than all of it is what keeps those from overflowing.
    try std.testing.expect(out.maximum_time > 0);
    try std.testing.expect(out.maximum_time < std.math.maxInt(i64) - out.maximum_time);

    // The side-to-move DOES have a clock: the ordinary path, which must still compute a real
    // budget rather than the sentinel.
    var real = base;
    real.time_ms = 1000;
    const out_real = init(real);
    try std.testing.expect(out_real.maximum_time < no_bound);
    try std.testing.expect(out_real.optimum_time > 0);
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

// Pin the MILLISECOND contract at the three TCs the Elo matrix actually plays. Sub-second
// budgets are the only ones that take the `scaled_time < 1000` moves-to-go reduction, so they
// are what a unit slip breaks first: read as microseconds, 0.4s leaves mtg at 50 instead of 20,
// `time_left` collapses from 256 to 76, and `optimum_time` bottoms out at the max(1.0, ...)
// floor -- the engine budgets 1ms per move and plays the rest of the game on the increment.
// Assert the floor is NOT hit, which is the symptom, rather than the internal mtg.
test "timeman: sub-second budgets take the moves-to-go reduction (ms, not us)" {
    for ([_]struct { t: i64, i: i64 }{ .{ .t = 100, .i = 1 }, .{ .t = 400, .i = 4 }, .{ .t = 700, .i = 7 } }) |tc| {
        var in = base;
        in.time_ms = tc.t;
        in.inc_ms = tc.i;
        const out = init(in);
        // Never hand out more than the whole clock, and keep the pair ordered.
        try std.testing.expect(out.maximum_time <= tc.t);
        try std.testing.expect(out.optimum_time <= out.maximum_time);
    }
    // 0.4s is the discriminating case: 2ms on the ms reading, the 1ms floor on the us reading.
    var in = base;
    in.time_ms = 400;
    in.inc_ms = 4;
    try std.testing.expect(init(in).optimum_time > 1);
}

test "timeman: nodestime converts movetime into nodes" {
    // checkTime compares `movetime` against a NODE count under nodestime, so the limit has to
    // be scaled here or `go movetime N` stops after N nodes. Converted before the no-clock
    // early return, so `go movetime N` with no clock at all is converted too.
    var in = base;
    in.npmsec = 600;
    in.movetime_ms = 500;
    try std.testing.expectEqual(@as(i64, 300_000), init(in).movetime_ms);

    var no_clock = in;
    no_clock.time_ms = 0;
    try std.testing.expectEqual(@as(i64, 300_000), init(no_clock).movetime_ms);

    // Without nodestime the figure passes through as the millisecond count it is.
    var off = base;
    off.movetime_ms = 500;
    try std.testing.expectEqual(@as(i64, 500), init(off).movetime_ms);
}

test "timeman: npmsec != 0 enables nodes-time mode" {
    var in = base;
    in.npmsec = 600;
    in.time_ms = 1000;
    in.movestogo = 40;
    try std.testing.expectEqual(@as(u8, 1), init(in).use_nodes_time);
    try std.testing.expectEqual(@as(u8, 0), init(base).use_nodes_time);
}
