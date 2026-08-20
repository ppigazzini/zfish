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
const root_move = @import("root_move");

/// Name the carrier the extension appends to: a ROOT PV, which grows. The walk ends at mate, a
/// draw or the clock, never at a ply count, so a fixed slice cannot be its contract.
pub const RootPVMoves = root_move.RootPVMoves;

/// Carry the extension's outcome: the score (a walk that ends in a draw corrects it to
/// VALUE_DRAW) and whether the deadline cut the walk short. The PV itself is written through
/// the list the caller hands over, so there is no length to carry back.
pub const ExtendPvResult = struct {
    value: i32,
    timed_out: bool,
};

fn keepPv(
    _: *const position_types.Position,
    _: u8,
    _: *RootPVMoves,
    value: i32,
    _: bool,
) ExtendPvResult {
    return .{ .value = value, .timed_out = false };
}

/// Correct and extend `pv` in place for a root move holding a tablebase score, returning the
/// score to report.
/// failure: silent — the PV and score pass through unchanged, which is what an engine with no
/// tablebase loaded must report. Unregistered costs only the DTZ extension, never a wrong move:
/// the reporter calls this after the search has already chosen `pv[0]`.
pub var extendPv: *const fn (
    pos: *const position_types.Position,
    chess960: u8,
    pv: *RootPVMoves,
    value: i32,
    use_time_management: bool,
) ExtendPvResult = &keepPv;

test {
    std.testing.refAllDecls(@This());
}
