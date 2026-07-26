// The root tablebase configuration a search carries.
//
// Hold what the root TB ranking decided and the in-search WDL probe re-reads:
// the piece-count cardinality the probe is gated on, whether the root position
// itself was resolved in the tablebases, whether the 50-move rule counts, and the
// depth floor below which the probe is skipped.
//
// Stay a std-only leaf so both the Worker layout (which embeds one) and the root-move
// builder (which produces one) can name the same type without an edge between them.

const std = @import("std");

pub const TbConfig = struct {
    /// Probe only positions with at most this many pieces; 0 disables the probe, which
    /// is what a build without a SyzygyPath leaves it at.
    cardinality: i32 = 0,
    /// Record whether the root move ranking came out of the tablebases.
    root_in_tb: bool = false,
    /// Count the 50-move rule in the WDL verdict (the Syzygy50MoveRule option).
    use_rule50: bool = false,
    /// Skip the probe below this depth once the piece count is under cardinality.
    probe_depth: i32 = 0,
};

test {
    std.testing.refAllDecls(@This());
}
