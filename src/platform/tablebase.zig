//! Syzygy tablebase facade: the platform-registered probe surface the shell/engine call as
//! ordinary Zig. File discovery + `init`/`maxCardinality` are real (M-SZ-1, in syzygy/tables.zig);
//! WDL *probing* is real as of M-SZ-2c (syzygy/wdl.zig) -- `probeFen` returns the Syzygy WDL for
//! positions up to the discovered cardinality. DTZ + in-search root ranking land in M-SZ-3/4.

const std = @import("std");
const tables = @import("syzygy/tables.zig");
const encode = @import("syzygy/encode.zig"); // M-SZ-2a geometry; test-referenced
const probe = @import("syzygy/probe.zig"); // M-SZ-2b probe model + pure helpers; test-referenced
const decode = @import("syzygy/decode.zig"); // M-SZ-2c pt1 parse + RE-PAIR decoder; test-referenced
const wdl = @import("syzygy/wdl.zig"); // M-SZ-2c pt2 WDL probe orchestration

// The probe result type is a search-facing value owned by the engine tb_source seam;
// re-export it so the shell inspection commands keep reaching it as tablebase.ProbeResult.
pub const ProbeResult = @import("tb_source").ProbeResult;

// Real (M-SZ-1): scan SyzygyPath, count `.rtbw`/`.rtbz` files, set maxCardinality.
pub const init = tables.init;
pub const maxCardinality = tables.maxCardinality; // search-facing: 0 until M-SZ-2
pub const discoveredMax = tables.discoveredMax; // disk discovery: for the "up to N-man" message
pub const foundWdl = tables.foundWdl;
pub const foundDtz = tables.foundDtz;

// Real WDL probe (M-SZ-2c): parse the position's FEN, look up its material key in the registry,
// and return the Syzygy WDL. `available == 0` when no table serves the position.
pub const probeFen = wdl.probeFen;
// In-search WDL probe on the live search Position (M-SZ-4, Step 6).
pub const probeWdlPos = wdl.probeWdlPos;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(tables);
    std.testing.refAllDecls(encode);
    std.testing.refAllDecls(probe);
    std.testing.refAllDecls(decode);
    std.testing.refAllDecls(wdl);
}
