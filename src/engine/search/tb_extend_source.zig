//! Inject the Syzygy PV extension for the UCI reporter.
//!
//! hook-class: service — a leaf answering a query it must not import the answer for.
//!
//! Extending a tablebase-scored PV needs a scratch position, legal movegen and the DTZ ranking,
//! all of which live at or below `position`. The reporter (`search_emit`) sits above
//! `search_driver`, which `position` imports, so reaching that machinery directly closes a
//! module cycle. Take the extender as a function pointer the composition root installs
//! (`root_move_build.syzygyExtendPv`) and the reporter calls a leaf instead.
//!
//! Default to returning the PV unchanged, which is the correct answer whenever no tablebase is
//! loaded: with no TB there is no DTZ to walk and upstream leaves the PV as the search built it.

const std = @import("std");
const position_types = @import("position_types");

/// Carry the extension's outcome: the PV length to report, the score (a walk that ends in a draw
/// corrects it to VALUE_DRAW), and whether the deadline cut the walk short.
pub const ExtendPvResult = struct {
    pv_len: usize,
    value: i32,
    timed_out: bool,
};

fn keepPv(
    _: *const position_types.Position,
    _: u8,
    _: []u16,
    pv_len: usize,
    value: i32,
    _: bool,
) ExtendPvResult {
    return .{ .pv_len = pv_len, .value = value, .timed_out = false };
}

/// Correct and extend `pv[0..pv_len]` for a root move holding a tablebase score, returning the
/// PV length and score to report.
/// failure: silent — the PV and score pass through unchanged, which is what an engine with no
/// tablebase loaded must report. Unregistered costs only the DTZ extension, never a wrong move:
/// the reporter calls this after the search has already chosen `pv[0]`.
pub var extendPv: *const fn (
    pos: *const position_types.Position,
    chess960: u8,
    pv: []u16,
    pv_len: usize,
    value: i32,
    use_time_management: bool,
) ExtendPvResult = &keepPv;

test {
    std.testing.refAllDecls(@This());
}
