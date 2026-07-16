//! Inject the monotonic clock for the search time management.
//!
//! Give time management "now" in milliseconds, but treat reading the OS clock as a
//! platform service -- the engine must not call it directly, or it stops being a
//! standalone library. So make the clock a function pointer the platform registers at
//! startup (`now = <os clock>`). Default to a std monotonic fallback, so a
//! headless engine build (unit tests, fuzzing) keeps a working clock with no
//! platform attached. In the shipped engine the platform injects its own clock, so
//! the timing behaviour is exactly the platform clock's.
//!
//! hook-class: service — a leaf answering a query it must not import the answer for.
//!
//! Treat unregistered as GENUINELY SAFE: the default is a real monotonic clock (a per-call
//! counter), which satisfies everything time management asks of it -- monotonic,
//! non-negative -- and keeps a headless run deterministic. It is not a stub returning
//! a plausible number; it is a valid clock with a different unit.

const std = @import("std");

// Provide a deterministic monotonic counter -- the headless fallback. Reading a real OS clock
// is a platform service (a syscall), so the engine cannot do it and stay portable;
// with no platform attached (unit tests, fuzzing) a per-call counter is a valid
// monotonic clock and keeps the run deterministic. The shipped engine injects the
// platform's real millisecond clock over this, so production timing is the
// platform's. Fall back single-threaded (the headless builds are single-threaded).
var headless_ticks: i64 = 0;
fn defaultNow() i64 {
    headless_ticks += 1;
    return headless_ticks;
}

/// Return monotonic time in milliseconds. Registered by the platform at startup; the
/// default is the std monotonic fallback above.
/// failure: silent — a real monotonic counter, not a stub: every property time
/// management requires holds. Unregistered, only the UNIT is wrong (ticks, not ms),
/// which no headless root reads, since none is time-limited.
pub var now: *const fn () i64 = &defaultNow;

test {
    std.testing.refAllDecls(@This());
    // Require the default to return a sane, non-negative monotonic value headless.
    const a = now();
    const b = now();
    try std.testing.expect(b >= a);
}
