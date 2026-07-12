//! Monotonic steady clock (Stockfish now()).
//! Milliseconds since an arbitrary epoch; used by time management and the skill-level RNG seed.

const std = @import("std");
const builtin = @import("builtin");

// Windows steady clock: QueryPerformanceCounter is the monotonic high-res counter;
// ticks/QueryPerformanceFrequency gives seconds. Declared here (only linked on Windows, where
// the switch below references it).
extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) i32;

/// Monotonic time in milliseconds.
pub fn now() i64 {
    switch (builtin.os.tag) {
        .windows => {
            var freq: i64 = 0;
            var count: i64 = 0;
            _ = QueryPerformanceFrequency(&freq);
            _ = QueryPerformanceCounter(&count);
            if (freq == 0) return 0;
            return @intCast(@divTrunc(@as(i128, count) * 1000, @as(i128, freq)));
        },
        .linux => {
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
            return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
        },
        else => {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.MONOTONIC, &ts);
            return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
        },
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
