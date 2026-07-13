//! Syzygy tablebase facade: the platform-registered probe surface the shell/engine call as
//! ordinary Zig. File discovery + `init`/`maxCardinality` are real (M-SZ-1, in syzygy/tables.zig);
//! WDL/DTZ *probing* is still a stub (M-SZ-2+), so `probeFen` reports "unavailable" and search
//! behaviour is unchanged until the prober lands.

const std = @import("std");
const tables = @import("syzygy/tables.zig");
const encode = @import("syzygy/encode.zig"); // M-SZ-2a geometry (dead until M-SZ-2c); test-referenced
const probe = @import("syzygy/probe.zig"); // M-SZ-2b probe model + pure helpers; test-referenced
const decode = @import("syzygy/decode.zig"); // M-SZ-2c pt1 parse+decompress (WIP, ungated); test-ref

// The probe result type is a search-facing value owned by the engine tb_source seam;
// re-export it so the shell inspection commands keep reaching it as tablebase.ProbeResult.
pub const ProbeResult = @import("tb_source").ProbeResult;

// Real (M-SZ-1): scan SyzygyPath, count `.rtbw`/`.rtbz` files, set maxCardinality.
pub const init = tables.init;
pub const maxCardinality = tables.maxCardinality; // search-facing: 0 until M-SZ-2
pub const discoveredMax = tables.discoveredMax; // disk discovery: for the "up to N-man" message
pub const foundWdl = tables.foundWdl;
pub const foundDtz = tables.foundDtz;

// Stub until M-SZ-2: no prober, so every probe is "unavailable".
pub fn probeFen(fen_ptr: [*]const u8, fen_len: usize, chess960: u8) ProbeResult {
    _ = fen_ptr;
    _ = fen_len;
    _ = chess960;
    return .{ .available = 0, .wdl = 0, .wdl_state = 0, .dtz = 0, .dtz_state = 0 };
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(tables);
    std.testing.refAllDecls(encode);
    std.testing.refAllDecls(probe);
    std.testing.refAllDecls(decode);
}
