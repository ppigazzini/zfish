//! Own the cardinalities of the two feature sets that share one weight array.
//!
//! SFNNv16 concatenates PP_3Wide's rows onto FullThreats' rows in a single
//! `threatAndPpWeights` array, so a pawn-pair feature is addressed as
//! `pp_index_base + pair`. That base IS the threat feature count -- not a number
//! that happens to equal it. Four files re-declared the threat count and two
//! re-declared the pair count, each under its own name and its own integer type,
//! and nothing related them: a sync that moved the threat count in three of four would
//! have left the fourth addressing a real row of the wrong feature set, which
//! evaluates to a plausible wrong number rather than to a fault.
//!
//! Declare each cardinality once here as an untyped `comptime_int` and let each
//! consumer keep the width it already used, so the concatenation is a property
//! of these definitions and no consumer's type changes.

// Count the FullThreats features (upstream FullThreats::Dimensions). Also the
// index base of the pawn-pair block, and the sentinel a threat LUT stores for a
// combination that names no feature -- readers drop `>= threat_dimensions`.
pub const threat_dimensions = 59808;

// Number the pawn ids: ranks 2-7 (48 squares) per color, id = 48 * color + (sq - a2).
pub const pp_pawn_ids = 2 * 48;
// Count the PP_3Wide features: every unordered pair of pawn ids, C(pp_pawn_ids, 2).
pub const pp_dimensions = pp_pawn_ids * (pp_pawn_ids - 1) / 2;

// Place the first pawn-pair feature directly after the last threat feature. This
// is the whole reason the two sets can share one array; deriving it is what keeps
// it true.
pub const pp_index_base = threat_dimensions;

// Size the shared array both sets are stored in.
pub const threat_and_pp_dimensions = threat_dimensions + pp_dimensions;

comptime {
    // Hold the concatenation: the pair block must start where the threat block
    // ends, and the two must exactly fill the shared array.
    if (pp_index_base != threat_dimensions)
        @compileError("pp_index_base must be the threat feature count");
    if (threat_and_pp_dimensions != pp_index_base + pp_dimensions)
        @compileError("the shared array must hold both feature sets and nothing else");
}

// ---- tests ------------------------------------------------------------------

const std = @import("std");

test "the pair block starts where the threat block ends" {
    try std.testing.expectEqual(@as(u32, threat_dimensions), @as(u32, pp_index_base));
    try std.testing.expectEqual(
        @as(u32, threat_and_pp_dimensions),
        @as(u32, threat_dimensions) + @as(u32, pp_dimensions),
    );
}

test "the pair count is C(pp_pawn_ids, 2)" {
    // Count the pairs the long way, so the closed form is checked rather than restated.
    comptime var pairs: u32 = 0;
    comptime {
        var hi: u32 = 1;
        while (hi < pp_pawn_ids) : (hi += 1) pairs += hi;
    }
    try std.testing.expectEqual(pairs, @as(u32, pp_dimensions));
}
