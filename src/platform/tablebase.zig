//! Syzygy tablebase probe surface. Currently a stub:
//! zfish does not ship the Syzygy prober, so max-cardinality is 0, every probe reports
//! "unavailable", and init is a no-op. Kept as a real module (not main.zig C-ABI glue) so the
//! search/engine paths call it as ordinary Zig.

// The probe result type is a search-facing value owned by the engine tb_source seam;
// re-export it so the shell inspection commands keep reaching it as tablebase.ProbeResult.
pub const ProbeResult = @import("tb_source").ProbeResult;

pub fn maxCardinality() usize {
    return 0;
}

pub fn probeFen(fen_ptr: [*]const u8, fen_len: usize, chess960: u8) ProbeResult {
    _ = fen_ptr;
    _ = fen_len;
    _ = chess960;
    return .{ .available = 0, .wdl = 0, .wdl_state = 0, .dtz = 0, .dtz_state = 0 };
}

pub fn init(path_ptr: [*]const u8, path_len: usize) void {
    _ = path_ptr;
    _ = path_len;
}

test {
    @import("std").testing.refAllDecls(@This());
}
