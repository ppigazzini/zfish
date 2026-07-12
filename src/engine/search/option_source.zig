//! Injected UCI-option reads for the search.
//!
//! A few search decisions depend on UCI option values (the Syzygy probe settings,
//! and integer options looked up by name). The options live in the shell's UCI
//! model, so the engine reads them through function pointers the shell registers at
//! startup rather than importing a shell module. The defaults return neutral values
//! (0 / false), so a headless engine build compiles and runs with no options
//! attached; the shipped engine injects the real UCI model, so option-driven
//! behaviour is the shell's.

const std = @import("std");

fn zeroInt() c_int {
    return 0;
}
fn zeroIntByName(_: []const u8) c_int {
    return 0;
}
fn falseRule() bool {
    return false;
}

/// Value of an integer UCI option, by name (0 if unset / no model attached).
pub var intByName: *const fn (name: []const u8) c_int = &zeroIntByName;
/// Syzygy tablebase probe settings.
pub var syzygyProbeDepth: *const fn () c_int = &zeroInt;
pub var syzygyProbeLimit: *const fn () c_int = &zeroInt;
pub var syzygy50MoveRule: *const fn () bool = &falseRule;

test {
    // Headless defaults are neutral.
    try std.testing.expectEqual(@as(c_int, 0), intByName("MultiPV"));
    try std.testing.expectEqual(@as(c_int, 0), syzygyProbeLimit());
    try std.testing.expectEqual(false, syzygy50MoveRule());
}
