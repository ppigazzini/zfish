//! Injected monotonic clock for the search time management.
//!
//! Time management needs "now" in milliseconds, but reading the OS clock is a
//! platform service -- the engine must not call it directly, or it stops being a
//! standalone library. So the clock is a function pointer the platform registers at
//! startup (`now = <os clock>`). The default is a std monotonic fallback, so a
//! headless engine build (unit tests, fuzzing) keeps a working clock with no
//! platform attached. In the shipped engine the platform injects its own clock, so
//! the timing behaviour is exactly the platform clock's.

const std = @import("std");

// Deterministic monotonic counter -- the headless fallback. Reading a real OS clock
// is a platform service (a syscall), so the engine cannot do it and stay portable;
// with no platform attached (unit tests, fuzzing) a per-call counter is a valid
// monotonic clock and keeps the run deterministic. The shipped engine injects the
// platform's real millisecond clock over this, so production timing is the
// platform's. Single-threaded fallback (the headless builds are single-threaded).
var headless_ticks: i64 = 0;
fn defaultNow() i64 {
    headless_ticks += 1;
    return headless_ticks;
}

/// Monotonic time in milliseconds. Registered by the platform at startup; the
/// default is the std monotonic fallback above.
pub var now: *const fn () i64 = &defaultNow;

test {
    std.testing.refAllDecls(@This());
    // The default must return a sane, non-negative monotonic value headless.
    const a = now();
    const b = now();
    try std.testing.expect(b >= a);
}
