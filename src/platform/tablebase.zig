//! Expose the Syzygy tablebase facade: the platform-registered probe surface the shell/engine call
//! as ordinary Zig. Discover files and scan SyzygyPath via `init`/`maxCardinality` (syzygy/tables.zig);
//! return via `probeFen` the Syzygy WDL + DTZ for a position up to the discovered cardinality, and
//! probe the live search Position directly via the in-search variant `probeWdlPos`.

const std = @import("std");
const tables = @import("syzygy/tables.zig");
const encode = @import("syzygy/encode.zig"); // Encode position->index geometry; test-referenced
const probe = @import("syzygy/probe.zig"); // Provide the probe data model + pure helpers; test-referenced
const decode = @import("syzygy/decode.zig"); // Parse files + run the RE-PAIR decoder; test-referenced
const registry = @import("syzygy/registry.zig"); // Register TBTables, load files, and set
const wdl = @import("syzygy/wdl.zig"); // Probe WDL/DTZ

// Re-export the probe result type -- a search-facing value owned by the engine tb_source seam --
// so the shell inspection commands keep reaching it as tablebase.ProbeResult.
pub const ProbeResult = @import("tb_source").ProbeResult;

// Scan SyzygyPath, count `.rtbw`/`.rtbz` files, set maxCardinality.
pub const init = tables.init;
pub const maxCardinality = tables.maxCardinality; // Search-facing: report 0 when no path is set
pub const discoveredMax = tables.discoveredMax; // Disk discovery: supply the "up to N-man" message
pub const foundWdl = tables.foundWdl;
pub const foundDtz = tables.foundDtz;

// WDL/DTZ probe: parse the position's FEN, look up its material key in the registry, and return
// the Syzygy WDL + DTZ. Report `available == 0` when no table serves the position.
pub const probeFen = wdl.probeFen;
// Probe WDL in-search on the live search Position (search Step 6).
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
