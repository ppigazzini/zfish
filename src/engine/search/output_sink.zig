//! Injected UCI output sink for the search's info / bestmove lines.
//!
//! Writing to the UCI output stream (and the quiet-mode flag that gates it) is a
//! shell service, so the search hands its formatted lines to function pointers the
//! shell registers at startup rather than importing the shell output module. The
//! defaults drop the output (and report not-quiet, so the formatting still runs and
//! is fuzz-exercised), so a headless engine build produces no output with no shell
//! attached. In the shipped engine the shell injects its real writer, so the UCI
//! output is byte-identical.
//!
//! hook-class: service — a leaf answering a query it must not import the answer for.
//!
//! These 3 are DEGRADED rather than safe when unregistered, and that is a judgement
//! call recorded here on purpose: the search still computes the same move, but
//! `dropLine` discards every UCI line INCLUDING `bestmove`. That is not "correct when
//! unregistered" -- it is a wrong answer that happens not to be a wrong MOVE. Whether
//! a UCI engine that computes correctly and says nothing should abort instead is a
//! decision someone should make deliberately; it is defensible today only because
//! main.zig:68 registers all 3 before the engine is reachable (main.zig:79), and the
//! hook-lint REGISTERED rule keeps that true.

fn dropLine(_: [*]const u8, _: usize) void {}
fn notQuiet() bool {
    return false;
}
fn ignoreNodes(_: u64) void {}

/// Write one already-formatted UCI line.
/// failure: silent — DEGRADED, not safe: drops every line including `bestmove`, so a
/// headless build produces no output with no shell attached. Right move, no answer.
pub var printLine: *const fn (str: [*]const u8, len: usize) void = &dropLine;
/// Whether output is suppressed (bench / quiet mode).
/// failure: silent — not-quiet, deliberately: the formatting still runs, so the fuzz
/// roots exercise the whole line-building path even though the lines are dropped.
pub var isQuiet: *const fn () bool = &notQuiet;
/// Publish the whole-search node count (read back by the bench signature line).
/// failure: silent — discards the count. Safe: the value is only read back by the
/// shell's bench signature line, which does not exist with no shell attached.
pub var setLastNodesSearched: *const fn (nodes: u64) void = &ignoreNodes;

test {
    // Defaults are safe headless no-ops.
    printLine("x", 1);
    setLastNodesSearched(0);
    try @import("std").testing.expectEqual(false, isQuiet());
}
