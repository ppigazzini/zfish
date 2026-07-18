//! Inject the Syzygy tablebase probe for the search.
//!
//! Treat tablebase probing as disk I/O -- a platform service -- so reach it
//! through function pointers the platform registers at startup rather than importing
//! a platform module. Keep the probe result type here (a search-facing value);
//! the platform tablebase module re-exports it. Have the defaults report "no tablebases",
//! so a headless engine build runs with no prober attached; the shipped engine injects
//! the platform prober (a stub today), so tablebase behaviour is the platform's.
//!
//! hook-class: service — a leaf answering a query it must not import the answer for.
//!
//! Treat these 3 as GENUINELY SAFE unregistered: the default IS the right answer when the
//! subsystem is absent. "No tablebases are loaded" is exactly true when no prober is
//! attached, and a search that does not probe is the correct search, not a degraded
//! one. No registration is required for correctness -- unlike option_source/thread_ops,
//! whose defaults are correct only because every root is accounted for.

const std = @import("std");
const position_types = @import("position_types");

pub const ProbeResult = struct {
    available: u8,
    wdl: i32,
    wdl_state: i32,
    dtz: i32,
    dtz_state: i32,
};

fn noTablebases() usize {
    return 0;
}
fn unavailable(_: [*]const u8, _: usize, _: u8) ProbeResult {
    return .{ .available = 0, .wdl = 0, .wdl_state = 0, .dtz = 0, .dtz_state = 0 };
}
fn unavailablePos(_: *position_types.Position) ProbeResult {
    return .{ .available = 0, .wdl = 0, .wdl_state = 0, .dtz = 0, .dtz_state = 0 };
}

/// Return the largest position (piece count) the tablebases cover; 0 when none are loaded.
/// failure: silent — 0 cardinality, which is precisely true with no prober attached:
/// the tablebases cover nothing, so the search correctly never probes.
pub var maxCardinality: *const fn () usize = &noTablebases;
/// Probe a FEN; `available == 0` means no result.
/// failure: silent — `available = 0`, the encoding for "no result", which is the
/// honest answer when no tablebases exist. Callers already handle it.
pub var probeFen: *const fn (fen_ptr: [*]const u8, fen_len: usize, chess960: u8) ProbeResult = &unavailable;
/// Probe the WDL in-search on the live search Position (Step 6); `available == 0` means FAIL/no result.
/// Do/undo on `pos` for the capture recursion and restore it exactly.
/// failure: silent — `available = 0` (FAIL), the same "no result" the real prober
/// returns for an uncovered position. Correct with no tablebases loaded.
pub var probeWdlPos: *const fn (pos: *position_types.Position) ProbeResult = &unavailablePos;

test {
    try std.testing.expectEqual(@as(usize, 0), maxCardinality());
    try std.testing.expectEqual(@as(u8, 0), probeFen("", 0, 0).available);
}
