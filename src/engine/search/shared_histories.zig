// Size the engine's `shared_histories` member. One SharedHistories per
// NUMA node sizes two thread-shared DynStats arrays:
//   correctionHistory : DynStats<[2]CorrectionBundle, CORRHIST_BASE_SIZE>
//   pawnHistory       : DynStats<[16][64] int16,      PAWN_HISTORY_BASE_SIZE>
// DynStats(s) sets its element count to s * SizeMultiplier, so for a node built with
// `threadCount` (always a power of two: nextPowerOfTwo(threads-on-node)):
//   corr element count = threadCount * CORRHIST_BASE_SIZE
//   pawn element count  = threadCount * PAWN_HISTORY_BASE_SIZE
// and the two index masks are (count - 1) (counts are powers of two, used as `key &
// mask`). Hold the COUNT logic only here — pure usize math, no allocation — so
// it unit-tests in `zig build test-graph` and is shared by the construction
// (board/position.zig constructSharedHistories) and the verifySizes check below.
//
// Validate the element BYTE sizes (@sizeOf([2]CorrectionBundle), the 1024-int16 pawn page)
// independently: the search reads these histories through
// board/position.zig, so its element strides match the layout.

const std = @import("std");

/// UINT_16_HISTORY_SIZE = std.math.maxInt(u16) + 1.
pub const corrhist_base_size: usize = 65536;
/// PAWN_HISTORY_BASE_SIZE.
pub const pawn_history_base_size: usize = 8192;

pub const Sizes = struct {
    /// Hold the correctionHistory element count (DynStats size).
    corr: usize,
    /// Hold the pawnHistory element count (DynStats size).
    pawn: usize,
};

/// Return the element counts of the two DynStats arrays for a node built with `thread_count`
/// (= nextPowerOfTwo(threads on the node)).
pub fn sharedHistoriesSizes(thread_count: usize) Sizes {
    return .{
        .corr = thread_count * corrhist_base_size,
        .pawn = thread_count * pawn_history_base_size,
    };
}

/// Check whether a constructed SharedHistories' four size fields (corr_size,
/// pawn_size, and the two masks) match the expected counts for `thread_count`.
pub fn verifySizes(
    corr_size: usize,
    pawn_size: usize,
    size_minus1: usize,
    pawn_hist_size_minus1: usize,
    thread_count: usize,
) bool {
    const s = sharedHistoriesSizes(thread_count);
    return corr_size == s.corr and
        pawn_size == s.pawn and
        size_minus1 == s.corr - 1 and
        pawn_hist_size_minus1 == s.pawn - 1;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "sharedHistoriesSizes scales each array by its base size" {
    try testing.expectEqual(Sizes{ .corr = 65536, .pawn = 8192 }, sharedHistoriesSizes(1));
    try testing.expectEqual(Sizes{ .corr = 131072, .pawn = 16384 }, sharedHistoriesSizes(2));
    try testing.expectEqual(Sizes{ .corr = 262144, .pawn = 32768 }, sharedHistoriesSizes(4));
}

test "verifySizes matches a correctly-sized node and rejects any perturbation" {
    const s = sharedHistoriesSizes(2);
    try testing.expect(verifySizes(s.corr, s.pawn, s.corr - 1, s.pawn - 1, 2));
    // reject a wrong thread_count
    try testing.expect(!verifySizes(s.corr, s.pawn, s.corr - 1, s.pawn - 1, 1));
    // reject any single field off
    try testing.expect(!verifySizes(s.corr + 1, s.pawn, s.corr - 1, s.pawn - 1, 2));
    try testing.expect(!verifySizes(s.corr, s.pawn - 1, s.corr - 1, s.pawn - 1, 2));
    try testing.expect(!verifySizes(s.corr, s.pawn, s.corr, s.pawn - 1, 2)); // reject a bad mask
    try testing.expect(!verifySizes(s.corr, s.pawn, s.corr - 1, s.pawn, 2)); // reject a bad mask
}
