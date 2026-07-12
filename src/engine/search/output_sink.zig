//! Injected UCI output sink for the search's info / bestmove lines.
//!
//! Writing to the UCI output stream (and the quiet-mode flag that gates it) is a
//! shell service, so the search hands its formatted lines to function pointers the
//! shell registers at startup rather than importing the shell output module. The
//! defaults drop the output (and report not-quiet, so the formatting still runs and
//! is fuzz-exercised), so a headless engine build produces no output with no shell
//! attached. In the shipped engine the shell injects its real writer, so the UCI
//! output is byte-identical.

fn dropLine(_: [*]const u8, _: usize) void {}
fn notQuiet() bool {
    return false;
}
fn ignoreNodes(_: u64) void {}

/// Write one already-formatted UCI line.
pub var printLine: *const fn (str: [*]const u8, len: usize) void = &dropLine;
/// Whether output is suppressed (bench / quiet mode).
pub var isQuiet: *const fn () bool = &notQuiet;
/// Publish the whole-search node count (read back by the bench signature line).
pub var setLastNodesSearched: *const fn (nodes: u64) void = &ignoreNodes;

test {
    // Defaults are safe headless no-ops.
    printLine("x", 1);
    setLastNodesSearched(0);
    try @import("std").testing.expectEqual(false, isQuiet());
}
