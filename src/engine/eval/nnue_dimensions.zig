//! Own the feature transformer's shape: the cardinalities of the two feature sets
//! that share one weight array, and the byte layout those cardinalities determine.
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
//!
//! The blob layout below is here for the same reason, one step further out. It was
//! derived TWICE -- `nnue_parse.zig` computed the offsets it WRITES each region at,
//! `nnue_ft.zig` computed the offsets its accessors READ them back from -- with two
//! round-up helpers, two spellings of 64, and no consumer in common to relate them.
//! Edit either side alone and the parser writes every weight where the accessors do
//! not look, which fails in the worst available way: the net still loads, every gate
//! still runs, and the evaluation is a plausible wrong number. One derivation cannot
//! disagree with itself.

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

// ---- the blob layout those cardinalities determine ---------------------------

// Size the transformer's own arrays. `half_dimensions` is upstream's
// TransformedFeatureDimensions and `psq_feature_dimensions` is HalfKAv2_hm::Dimensions;
// `psqt_buckets` is PSQTBuckets.
pub const half_dimensions: usize = 1024;
pub const psq_feature_dimensions: usize = 22528;
pub const psqt_buckets: usize = 8;

// Align every region on a cache line, which is what upstream's `alignas(CacheLineSize)`
// on each member spells. The accumulator arena carries the same alignment for the same
// SIMD reason and derives it from here rather than restating 64.
pub const cache_line_bytes: usize = 64;

fn roundUp(x: usize, a: usize) usize {
    return (x + a - 1) / a * a;
}

// Count the elements of the feature-transformer arrays. The threat weight/psqt regions
// hold the FullThreats rows followed by the PP_3Wide rows (one contiguous array each).
pub const biases_count = half_dimensions; // i16
pub const psq_weights_count = half_dimensions * psq_feature_dimensions; // i16
pub const threat_weights_count = half_dimensions * threat_and_pp_dimensions; // i8 (threat ++ pp)
pub const psqt_weights_count = psq_feature_dimensions * psqt_buckets; // i32
pub const threat_psqt_weights_count = threat_and_pp_dimensions * psqt_buckets; // i32 (threat ++ pp)

// The stream splits the two concatenated regions back into separate sections (threat,
// then pp), each framed on its own; these are the per-section element counts.
pub const threat_only_weights_count = half_dimensions * threat_dimensions; // i8
pub const pp_only_weights_count = half_dimensions * pp_dimensions; // i8
pub const threat_only_psqt_count = threat_dimensions * psqt_buckets; // i32
pub const pp_only_psqt_count = pp_dimensions * psqt_buckets; // i32

// Lay out the in-memory byte offsets (member order, each alignas(64)): biases,
// weights(psq), threatAndPpWeights, psqtWeights, threatAndPpPsqtWeights.
pub const biases_off = 0;
pub const weights_off = roundUp(biases_count * 2, cache_line_bytes);
pub const threat_weights_off = roundUp(weights_off + psq_weights_count * 2, cache_line_bytes);
pub const psqt_weights_off = roundUp(threat_weights_off + threat_weights_count * 1, cache_line_bytes);
pub const threat_psqt_weights_off = roundUp(psqt_weights_off + psqt_weights_count * 4, cache_line_bytes);
pub const ft_total_bytes = roundUp(threat_psqt_weights_off + threat_psqt_weights_count * 4, cache_line_bytes);
// Byte offsets of the pp sub-regions within the concatenated threat regions.
pub const pp_weights_off = threat_weights_off + threat_only_weights_count * 1;
pub const pp_psqt_weights_off = threat_psqt_weights_off + threat_only_psqt_count * 4;

comptime {
    // Require the five regions to tile ft_total_bytes with no padding. The parse is
    // the arena's only initializer (page_alloc hands the block out uninitialized), so
    // a dims change that opened an alignment gap would leak uninitialized bytes into
    // the weight image; fail the build instead.
    std.debug.assert(weights_off == biases_off + biases_count * 2);
    std.debug.assert(threat_weights_off == weights_off + psq_weights_count * 2);
    std.debug.assert(psqt_weights_off == threat_weights_off + threat_weights_count * 1);
    std.debug.assert(threat_psqt_weights_off == psqt_weights_off + psqt_weights_count * 4);
    std.debug.assert(ft_total_bytes == threat_psqt_weights_off + threat_psqt_weights_count * 4);
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
