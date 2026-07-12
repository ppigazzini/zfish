//! Injected Syzygy tablebase probe for the search.
//!
//! Probing tablebases is disk I/O -- a platform service -- so the search reaches it
//! through function pointers the platform registers at startup rather than importing
//! a platform module. The probe result type lives here (it is a search-facing value);
//! the platform tablebase module re-exports it. The defaults report "no tablebases",
//! so a headless engine build runs with no prober attached; the shipped engine injects
//! the platform prober (a stub today), so tablebase behaviour is the platform's.

const std = @import("std");

pub const ProbeResult = struct {
    available: u8,
    wdl: c_int,
    wdl_state: c_int,
    dtz: c_int,
    dtz_state: c_int,
};

fn noTablebases() usize {
    return 0;
}
fn unavailable(_: [*]const u8, _: usize, _: u8) ProbeResult {
    return .{ .available = 0, .wdl = 0, .wdl_state = 0, .dtz = 0, .dtz_state = 0 };
}

/// Largest position (piece count) the tablebases cover; 0 when none are loaded.
pub var maxCardinality: *const fn () usize = &noTablebases;
/// Probe a FEN; `available == 0` means no result.
pub var probeFen: *const fn (fen_ptr: [*]const u8, fen_len: usize, chess960: u8) ProbeResult = &unavailable;

test {
    try std.testing.expectEqual(@as(usize, 0), maxCardinality());
    try std.testing.expectEqual(@as(u8, 0), probeFen("", 0, 0).available);
}
