//! Syzygy tablebase facade: the platform-registered probe surface the shell/engine call as
//! ordinary Zig. File discovery + `init`/`maxCardinality` scan SyzygyPath (syzygy/tables.zig);
//! `probeFen` returns the Syzygy WDL + DTZ for a position up to the discovered cardinality, and
//! `probeWdlPos` is the in-search variant that probes the live search Position directly.

const std = @import("std");
const tables = @import("syzygy/tables.zig");
const encode = @import("syzygy/encode.zig"); // position->index geometry; test-referenced
const probe = @import("syzygy/probe.zig"); // probe data model + pure helpers; test-referenced
const decode = @import("syzygy/decode.zig"); // file parse + RE-PAIR decoder; test-referenced
const registry = @import("syzygy/registry.zig"); // TBTable registry + file load + set
const wdl = @import("syzygy/wdl.zig"); // WDL/DTZ probe algorithm

// The probe result type is a search-facing value owned by the engine tb_source seam;
// re-export it so the shell inspection commands keep reaching it as tablebase.ProbeResult.
pub const ProbeResult = @import("tb_source").ProbeResult;

// Scan SyzygyPath, count `.rtbw`/`.rtbz` files, set maxCardinality.
pub const init = tables.init;
pub const maxCardinality = tables.maxCardinality; // search-facing: 0 when no path is set
pub const discoveredMax = tables.discoveredMax; // disk discovery: for the "up to N-man" message
pub const foundWdl = tables.foundWdl;
pub const foundDtz = tables.foundDtz;

// WDL/DTZ probe: parse the position's FEN, look up its material key in the registry, and return
// the Syzygy WDL + DTZ. `available == 0` when no table serves the position.
pub const probeFen = wdl.probeFen;
// In-search WDL probe on the live search Position (search Step 6).
pub const probeWdlPos = wdl.probeWdlPos;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(tables);
    std.testing.refAllDecls(encode);
    std.testing.refAllDecls(probe);
    std.testing.refAllDecls(decode);
    std.testing.refAllDecls(registry);
    std.testing.refAllDecls(wdl);
}
