//! Inject UCI-option reads for the search.
//!
//! hook-class: service — a leaf answering a query it must not import the answer for.
//! Note that a caller decides how often a service is asked and the hook cannot tell, so these
//! are the class that carries the live risk (an optimizer barrier per call).
//!
//! Read the UCI option values a few search decisions depend on (the Syzygy probe settings,
//! and integer options looked up by name). The options live in the shell's UCI
//! model, so the engine reads them through function pointers the shell registers at
//! startup rather than importing a shell module. Return neutral values by default
//! (0 / false), so a headless engine build compiles and runs with no options
//! attached; the shipped engine injects the real UCI model, so option-driven
//! behaviour is the shell's.
//!
//! Treat these 4 as SEARCH-AFFECTING when unregistered: they answer rather than abort, so
//! a missing registration is a wrong search, not a crash -- the one failure shape
//! bench=2792255 cannot catch. That is tolerated only because both roots are
//! accounted for, and the hook-lint REGISTERED rule is what keeps it true:
//!   * shipped exe -- main.zig:68 installRuntimeHooks registers all 4, before the
//!     engine is first reachable at main.zig:79. No shipped path can read a default.
//!   * headless roots -- headless_search.zig registers intByName deliberately and
//!     relies on 0 for the rest, which is the correct answer for a depth-only search
//!     with no option model attached.

const std = @import("std");

fn zeroInt() i32 {
    return 0;
}
fn zeroIntByName(_: []const u8) i32 {
    return 0;
}
fn falseRule() bool {
    return false;
}

/// Read the value of an integer UCI option, by name (0 if unset / no model attached).
/// failure: silent — 0 for every option, which is the correct answer for a headless
/// depth-only search with no UCI model attached (headless_search.zig registers its own).
/// SEARCH-AFFECTING in a shipped build; main.zig:68 registers it before main.zig:79.
pub var intByName: *const fn (name: []const u8) i32 = &zeroIntByName;
/// Read the Syzygy tablebase probe settings.
/// failure: silent — 0 probe depth, which reads as "never probe". Correct headless:
/// no tablebases are loaded there either, so not probing is the right search.
pub var syzygyProbeDepth: *const fn () i32 = &zeroInt;
/// failure: silent — 0 probe limit, i.e. no position is probed. Same reason.
pub var syzygyProbeLimit: *const fn () i32 = &zeroInt;
/// failure: silent — false, i.e. the 50-move rule is not applied to TB scores. Only
/// reachable with tablebases, which a headless root never loads, so it cannot be read.
pub var syzygy50MoveRule: *const fn () bool = &falseRule;

test {
    // Confirm the headless defaults are neutral.
    try std.testing.expectEqual(@as(i32, 0), intByName("MultiPV"));
    try std.testing.expectEqual(@as(i32, 0), syzygyProbeLimit());
    try std.testing.expectEqual(false, syzygy50MoveRule());
}
