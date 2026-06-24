// Native sizing for the engine's `shared_histories` member (the post-src/ replacement
// for std::map<NumaIndex, SharedHistories>). One SharedHistories per NUMA node is
// built by the C++ ctor SharedHistories(threadCount) (src/history.h), which sizes two
// thread-shared DynStats arrays:
//   correctionHistory : DynStats<[2]CorrectionBundle, CORRHIST_BASE_SIZE>
//   pawnHistory       : DynStats<[16][64] int16,      PAWN_HISTORY_BASE_SIZE>
// DynStats(s) sets its element count to s * SizeMultiplier, so for a node built with
// `threadCount` (always a power of two: nextPowerOfTwo(threads-on-node)):
//   corr element count = threadCount * CORRHIST_BASE_SIZE
//   pawn element count  = threadCount * PAWN_HISTORY_BASE_SIZE
// and the two index masks are (count - 1) (counts are powers of two, used as `key &
// mask`). This module is the COUNT logic only — pure usize math, no allocation — so
// it unit-tests in `zig build test-graph` and is shared by both the native
// construction (board/position.zig constructSharedHistories) and the shadow verifier
// that checks the live C++ try_emplace result (zfish_shadow_verify_shared_histories).
//
// The element BYTE sizes (@sizeOf([2]CorrectionBundle), the 1024-int16 pawn page) are
// already validated independently: the native search reads C++-allocated histories
// through board/position.zig today, so its element strides match the C++ layout.
//
// Native-graph cut flip fire 2 (REPORT-9 Annex B, ITERATION-157).

const std = @import("std");

/// UINT_16_HISTORY_SIZE = std::numeric_limits<uint16_t>::max() + 1 (src/history.h).
pub const corrhist_base_size: usize = 65536;
/// PAWN_HISTORY_BASE_SIZE (src/history.h).
pub const pawn_history_base_size: usize = 8192;

pub const Sizes = struct {
    /// correctionHistory element count (DynStats size).
    corr: usize,
    /// pawnHistory element count (DynStats size).
    pawn: usize,
};

/// Element counts of the two DynStats arrays for a node built with `thread_count`
/// (= nextPowerOfTwo(threads on the node)).
pub fn sharedHistoriesSizes(thread_count: usize) Sizes {
    return .{
        .corr = thread_count * corrhist_base_size,
        .pawn = thread_count * pawn_history_base_size,
    };
}

/// Shadow check: do a constructed SharedHistories' four size fields (corr_size,
/// pawn_size, and the two masks) match the expected counts for `thread_count`?
/// Used against the live C++ try_emplace result to de-risk the native sizing.
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
    // wrong thread_count
    try testing.expect(!verifySizes(s.corr, s.pawn, s.corr - 1, s.pawn - 1, 1));
    // any single field off
    try testing.expect(!verifySizes(s.corr + 1, s.pawn, s.corr - 1, s.pawn - 1, 2));
    try testing.expect(!verifySizes(s.corr, s.pawn - 1, s.corr - 1, s.pawn - 1, 2));
    try testing.expect(!verifySizes(s.corr, s.pawn, s.corr, s.pawn - 1, 2)); // bad mask
    try testing.expect(!verifySizes(s.corr, s.pawn, s.corr - 1, s.pawn, 2)); // bad mask
}
