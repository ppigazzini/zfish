// Debug statistics counters (extracted from misc.zig).
//
// Stockfish's dbg_hit_on / dbg_mean_of / dbg_stdev_of / dbg_extremes_of /
// dbg_correl_of instrumentation: lock-free per-slot accumulators + a print/clear
// pair. Std-only (atomics + std.debug.print), no engine dependency -- misc.zig
// re-exports these so `misc.dbgPrint()` (the UCI debug dump) keeps working.

const std = @import("std");

const max_debug_slots: usize = 32;

var dbg_hit: [max_debug_slots][2]i64 = .{.{ 0, 0 }} ** max_debug_slots;
var dbg_mean: [max_debug_slots][2]i64 = .{.{ 0, 0 }} ** max_debug_slots;
var dbg_stdev: [max_debug_slots][3]i64 = .{.{ 0, 0, 0 }} ** max_debug_slots;
var dbg_correl: [max_debug_slots][6]i64 = .{.{ 0, 0, 0, 0, 0, 0 }} ** max_debug_slots;
var dbg_extremes_count: [max_debug_slots]i64 = [_]i64{0} ** max_debug_slots;
var dbg_extremes_max: [max_debug_slots]i64 = [_]i64{std.math.minInt(i64)} ** max_debug_slots;
var dbg_extremes_min: [max_debug_slots]i64 = [_]i64{std.math.maxInt(i64)} ** max_debug_slots;

fn slotIndex(slot: c_int) usize {
    std.debug.assert(slot >= 0 and slot < max_debug_slots);
    return @intCast(slot);
}

fn asFloat(value: i64) f64 {
    return @as(f64, @floatFromInt(value));
}

pub fn dbgHitOn(cond: bool, slot: c_int) void {
    const index = slotIndex(slot);
    _ = @atomicRmw(i64, &dbg_hit[index][0], .Add, 1, .seq_cst);
    if (cond) {
        _ = @atomicRmw(i64, &dbg_hit[index][1], .Add, 1, .seq_cst);
    }
}

pub fn dbgMeanOf(value: i64, slot: c_int) void {
    const index = slotIndex(slot);
    _ = @atomicRmw(i64, &dbg_mean[index][0], .Add, 1, .seq_cst);
    _ = @atomicRmw(i64, &dbg_mean[index][1], .Add, value, .seq_cst);
}

pub fn dbgStdevOf(value: i64, slot: c_int) void {
    const index = slotIndex(slot);
    _ = @atomicRmw(i64, &dbg_stdev[index][0], .Add, 1, .seq_cst);
    _ = @atomicRmw(i64, &dbg_stdev[index][1], .Add, value, .seq_cst);
    _ = @atomicRmw(i64, &dbg_stdev[index][2], .Add, value * value, .seq_cst);
}

pub fn dbgExtremesOf(value: i64, slot: c_int) void {
    const index = slotIndex(slot);
    _ = @atomicRmw(i64, &dbg_extremes_count[index], .Add, 1, .seq_cst);

    var current_max = @atomicLoad(i64, &dbg_extremes_max[index], .seq_cst);
    while (current_max < value) {
        const previous = @cmpxchgWeak(i64, &dbg_extremes_max[index], current_max, value, .seq_cst, .seq_cst);
        if (previous == null) {
            break;
        }
        current_max = previous.?;
    }

    var current_min = @atomicLoad(i64, &dbg_extremes_min[index], .seq_cst);
    while (current_min > value) {
        const previous = @cmpxchgWeak(i64, &dbg_extremes_min[index], current_min, value, .seq_cst, .seq_cst);
        if (previous == null) {
            break;
        }
        current_min = previous.?;
    }
}

pub fn dbgCorrelOf(value1: i64, value2: i64, slot: c_int) void {
    const index = slotIndex(slot);
    _ = @atomicRmw(i64, &dbg_correl[index][0], .Add, 1, .seq_cst);
    _ = @atomicRmw(i64, &dbg_correl[index][1], .Add, value1, .seq_cst);
    _ = @atomicRmw(i64, &dbg_correl[index][2], .Add, value1 * value1, .seq_cst);
    _ = @atomicRmw(i64, &dbg_correl[index][3], .Add, value2, .seq_cst);
    _ = @atomicRmw(i64, &dbg_correl[index][4], .Add, value2 * value2, .seq_cst);
    _ = @atomicRmw(i64, &dbg_correl[index][5], .Add, value1 * value2, .seq_cst);
}

pub fn dbgPrint() void {
    var index: usize = 0;
    while (index < max_debug_slots) : (index += 1) {
        const total = @atomicLoad(i64, &dbg_hit[index][0], .seq_cst);
        if (total != 0) {
            const hits = @atomicLoad(i64, &dbg_hit[index][1], .seq_cst);
            std.debug.print(
                "Hit #{d}: Total {d} Hits {d} Hit Rate (%) {}\n",
                .{ index, total, hits, 100.0 * asFloat(hits) / asFloat(total) },
            );
        }
    }

    index = 0;
    while (index < max_debug_slots) : (index += 1) {
        const total = @atomicLoad(i64, &dbg_mean[index][0], .seq_cst);
        if (total != 0) {
            const sum = @atomicLoad(i64, &dbg_mean[index][1], .seq_cst);
            std.debug.print("Mean #{d}: Total {d} Mean {}\n", .{ index, total, asFloat(sum) / asFloat(total) });
        }
    }

    index = 0;
    while (index < max_debug_slots) : (index += 1) {
        const total = @atomicLoad(i64, &dbg_stdev[index][0], .seq_cst);
        if (total != 0) {
            const sum = @atomicLoad(i64, &dbg_stdev[index][1], .seq_cst);
            const sum_sq = @atomicLoad(i64, &dbg_stdev[index][2], .seq_cst);
            const mean = asFloat(sum) / asFloat(total);
            const variance = asFloat(sum_sq) / asFloat(total) - mean * mean;
            std.debug.print("Stdev #{d}: Total {d} Stdev {}\n", .{ index, total, @sqrt(@max(variance, 0.0)) });
        }
    }

    index = 0;
    while (index < max_debug_slots) : (index += 1) {
        const total = @atomicLoad(i64, &dbg_extremes_count[index], .seq_cst);
        if (total != 0) {
            std.debug.print(
                "Extremity #{d}: Total {d} Min {d} Max {d}\n",
                .{
                    index,
                    total,
                    @atomicLoad(i64, &dbg_extremes_min[index], .seq_cst),
                    @atomicLoad(i64, &dbg_extremes_max[index], .seq_cst),
                },
            );
        }
    }

    index = 0;
    while (index < max_debug_slots) : (index += 1) {
        const total = @atomicLoad(i64, &dbg_correl[index][0], .seq_cst);
        if (total != 0) {
            const sum1 = asFloat(@atomicLoad(i64, &dbg_correl[index][1], .seq_cst));
            const sum1_sq = asFloat(@atomicLoad(i64, &dbg_correl[index][2], .seq_cst));
            const sum2 = asFloat(@atomicLoad(i64, &dbg_correl[index][3], .seq_cst));
            const sum2_sq = asFloat(@atomicLoad(i64, &dbg_correl[index][4], .seq_cst));
            const sum12 = asFloat(@atomicLoad(i64, &dbg_correl[index][5], .seq_cst));
            const n = asFloat(total);
            const numerator = sum12 / n - (sum1 / n) * (sum2 / n);
            const denom_left = @sqrt(@max(sum1_sq / n - (sum1 / n) * (sum1 / n), 0.0));
            const denom_right = @sqrt(@max(sum2_sq / n - (sum2 / n) * (sum2 / n), 0.0));
            const coefficient = if (denom_left == 0.0 or denom_right == 0.0) 0.0 else numerator / (denom_left * denom_right);
            std.debug.print("Correl. #{d}: Total {d} Coefficient {}\n", .{ index, total, coefficient });
        }
    }
}

pub fn dbgClear() void {
    var index: usize = 0;
    while (index < max_debug_slots) : (index += 1) {
        @atomicStore(i64, &dbg_hit[index][0], 0, .seq_cst);
        @atomicStore(i64, &dbg_hit[index][1], 0, .seq_cst);
        @atomicStore(i64, &dbg_mean[index][0], 0, .seq_cst);
        @atomicStore(i64, &dbg_mean[index][1], 0, .seq_cst);
        @atomicStore(i64, &dbg_stdev[index][0], 0, .seq_cst);
        @atomicStore(i64, &dbg_stdev[index][1], 0, .seq_cst);
        @atomicStore(i64, &dbg_stdev[index][2], 0, .seq_cst);
        @atomicStore(i64, &dbg_correl[index][0], 0, .seq_cst);
        @atomicStore(i64, &dbg_correl[index][1], 0, .seq_cst);
        @atomicStore(i64, &dbg_correl[index][2], 0, .seq_cst);
        @atomicStore(i64, &dbg_correl[index][3], 0, .seq_cst);
        @atomicStore(i64, &dbg_correl[index][4], 0, .seq_cst);
        @atomicStore(i64, &dbg_correl[index][5], 0, .seq_cst);
        @atomicStore(i64, &dbg_extremes_count[index], 0, .seq_cst);
        @atomicStore(i64, &dbg_extremes_max[index], std.math.minInt(i64), .seq_cst);
        @atomicStore(i64, &dbg_extremes_min[index], std.math.maxInt(i64), .seq_cst);
    }
}

// ---- tests (drive the accumulators, read the private slot state back) --------

const testing = std.testing;

test "dbgHitOn accumulates total and conditional hits per slot" {
    dbgClear();
    dbgHitOn(true, 0);
    dbgHitOn(false, 0);
    dbgHitOn(true, 0);
    try testing.expectEqual(@as(i64, 3), dbg_hit[0][0]); // total
    try testing.expectEqual(@as(i64, 2), dbg_hit[0][1]); // conditional hits
    try testing.expectEqual(@as(i64, 0), dbg_hit[1][0]); // untouched slot
}

test "dbgMeanOf / dbgStdevOf / dbgExtremesOf accumulate; dbgClear resets" {
    dbgClear();
    dbgMeanOf(10, 2);
    dbgMeanOf(20, 2);
    try testing.expectEqual(@as(i64, 2), dbg_mean[2][0]);
    try testing.expectEqual(@as(i64, 30), dbg_mean[2][1]);

    dbgStdevOf(4, 3);
    try testing.expectEqual(@as(i64, 1), dbg_stdev[3][0]);
    try testing.expectEqual(@as(i64, 4), dbg_stdev[3][1]);
    try testing.expectEqual(@as(i64, 16), dbg_stdev[3][2]);

    dbgExtremesOf(-5, 4);
    dbgExtremesOf(9, 4);
    try testing.expectEqual(@as(i64, -5), dbg_extremes_min[4]);
    try testing.expectEqual(@as(i64, 9), dbg_extremes_max[4]);

    dbgClear();
    try testing.expectEqual(@as(i64, 0), dbg_mean[2][0]);
    try testing.expectEqual(std.math.maxInt(i64), dbg_extremes_min[4]);
    try testing.expectEqual(std.math.minInt(i64), dbg_extremes_max[4]);
}

test "all decls compile" {
    testing.refAllDecls(@This());
}
