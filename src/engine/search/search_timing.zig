//! Time the SEARCH, not the round trip around it.
//!
//! `speedtest` divides nodes by seconds, so whatever the clock brackets ends up in the
//! reported nps. Bracketing the shell's `go` dispatch charges the search for the UCI
//! parse, the thread wakeup and the lazy network verification -- work that does not
//! scale with the position and inflates nothing but the denominator. Upstream fixed
//! this by starting its clock inside `start_searching` (right after time management is
//! initialised) and stopping it as the bestmove goes out; this leaf is where those two
//! instants are recorded so the shell can read the difference.
//!
//! hook-class: service — a leaf answering a query it must not import the answer for.
//! The engine stamps, the shell reads; neither imports the other.
//!
//! Treat unregistered as GENUINELY SAFE: nobody stamping leaves the total at zero, and
//! the only reader (`speedtest`) already clamps a non-positive total to 1 ms before
//! dividing. A missing stamp costs a reported nps, never a search decision -- no engine
//! path reads any of this back.
//!
//! Only the main thread stamps: `ssTmInit` and the bestmove emit both run there, after
//! `ssWaitFinished` has joined the helpers. The atomics are for the shell's read on
//! another thread, not for writer contention.

const std = @import("std");

// Hold the instant the current search began, 0 when no search is being timed. Separate
// from the total so a bestmove with no matching start (a path that emits without going
// through time-management init) contributes nothing rather than a garbage interval.
var start_ms = std.atomic.Value(i64).init(0);
var total_ms = std.atomic.Value(i64).init(0);

/// Stamp the start of a timed search. Call once time management is initialised, so the
/// interval covers the search and nothing that merely precedes it.
pub fn markStart(now_ms: i64) void {
    start_ms.store(now_ms, .monotonic);
}

/// Close the interval as the bestmove is produced and fold it into the running total.
/// Ignore a bestmove that no start matches, and clear the start so a second bestmove
/// for the same search cannot count the interval twice.
pub fn markBestmove(now_ms: i64) void {
    const started = start_ms.swap(0, .monotonic);
    if (started == 0) return;
    const delta = now_ms - started;
    if (delta <= 0) return;
    _ = total_ms.fetchAdd(delta, .monotonic);
}

/// Drop every accumulated interval. `speedtest` calls this after its warmup, so the
/// warmup searches do not land in the measured total.
pub fn reset() void {
    start_ms.store(0, .monotonic);
    total_ms.store(0, .monotonic);
}

/// Read the accumulated search time in milliseconds.
pub fn totalMs() i64 {
    return total_ms.load(.monotonic);
}

test "accumulates one interval per start/bestmove pair" {
    reset();
    try std.testing.expectEqual(@as(i64, 0), totalMs());

    markStart(1000);
    markBestmove(1300);
    try std.testing.expectEqual(@as(i64, 300), totalMs());

    markStart(2000);
    markBestmove(2050);
    try std.testing.expectEqual(@as(i64, 350), totalMs());
}

test "ignores a bestmove with no matching start" {
    reset();
    markBestmove(9999);
    try std.testing.expectEqual(@as(i64, 0), totalMs());

    // A second bestmove for the same search must not re-count the interval.
    markStart(100);
    markBestmove(200);
    markBestmove(500);
    try std.testing.expectEqual(@as(i64, 100), totalMs());
}

test "ignores a non-advancing clock" {
    reset();
    markStart(500);
    markBestmove(500);
    try std.testing.expectEqual(@as(i64, 0), totalMs());
}
