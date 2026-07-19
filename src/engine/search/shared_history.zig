// Manage the shared-history arena.
//
// Provide the per-numa-node SharedHistories block (correction + pawn history), its
// large-page allocation / free / clear / verify management, and the accessors the
// search reads it through (sharedOf / pawnEntryRow / corrBundle). Serve as the history
// *storage* layer; depend on nothing search-specific -- only the worker/board POD
// leaves plus the memory and sizing helpers.

const std = @import("std");
const page_alloc = @import("page_alloc");
const shared_hist = @import("shared_histories");
const shared_histories_map = @import("shared_histories_map");
const worker_histories = @import("worker_histories");
const search_types = @import("search_types");
const position_types = @import("position_types");
const shared_history_types = @import("shared_history_types");

const WorkerHistories = worker_histories.WorkerHistories;
const hist_pieceto = worker_histories.hist_pieceto;
const CorrectionBundle = search_types.CorrectionBundle;
const Position = position_types.Position;

pub const SharedHistories = shared_history_types.SharedHistories;

pub inline fn sharedOf(w: *const WorkerHistories) *SharedHistories {
    return w.shared_history.?;
}

// Partition `size` entries by numa: [start, end).
inline fn dynRange(size: usize, thread_idx: usize, numa_total: usize) struct { start: usize, end: usize } {
    const start = thread_idx * size / numa_total;
    const end = if (thread_idx + 1 == numa_total) size else (thread_idx + 1) * size / numa_total;
    return .{ .start = start, .end = end };
}

// Clear a SharedHistories: fill correctionHistory entries (each [2]CorrectionBundle, 8 int16)
// to -5 and pawnHistory pages (each a [16][64] int16 page) to -1338, over
// this thread's numa partition.
pub fn clearSharedHistory(shared: *SharedHistories, thread_idx: usize, numa_total: usize) void {
    const corr_entry_i16: usize = @sizeOf([2]CorrectionBundle) / @sizeOf(i16);
    {
        const r = dynRange(shared.corr_size, thread_idx, numa_total);
        const base: [*]i16 = @ptrCast(@alignCast(shared.corr_data));
        var i = r.start * corr_entry_i16;
        const stop = r.end * corr_entry_i16;
        while (i < stop) : (i += 1) base[i] = -5;
    }
    {
        const r = dynRange(shared.pawn_size, thread_idx, numa_total);
        var i = r.start * hist_pieceto;
        const stop = r.end * hist_pieceto;
        while (i < stop) : (i += 1) shared.pawn_data[i] = -1338;
    }
}

// Construct one node's SharedHistories. Allocate the two DynStats arrays
// from large pages (corr: [2]CorrectionBundle elements; pawn: [16][64] int16 pages,
// exposed as a flat int16 array) and fill in the size fields + index masks.
// `thread_count` is nextPowerOfTwo(threads on the node), so the counts are powers of two
// and the masks are (count - 1). Element strides come from the same types the
// search reads the histories through, so the layouts match; the COUNT logic is shared
// with shared_histories.zig (sharedHistoriesSizes).
pub fn constructSharedHistories(thread_count: usize) error{OutOfMemory}!SharedHistories {
    const sizes = shared_hist.sharedHistoriesSizes(thread_count);
    const corr_bytes = sizes.corr * @sizeOf([2]CorrectionBundle);
    const pawn_bytes = sizes.pawn * hist_pieceto * @sizeOf(i16);

    const corr_ptr = page_alloc.alloc(corr_bytes) orelse return error.OutOfMemory;
    const pawn_ptr = page_alloc.alloc(pawn_bytes) orelse {
        page_alloc.free(corr_ptr); // don't leak corr if pawn alloc fails
        return error.OutOfMemory;
    };

    return .{
        .corr_size = sizes.corr,
        .corr_data = @ptrCast(@alignCast(corr_ptr)),
        .pawn_size = sizes.pawn,
        .pawn_data = @ptrCast(@alignCast(pawn_ptr)),
        .size_minus1 = sizes.corr - 1,
        .pawn_hist_size_minus1 = sizes.pawn - 1,
    };
}

// Release a SharedHistories' two large-page arrays — the free hook the
// sharedHists map (SharedHistoriesMap) calls per element on erase/clear.
pub fn deinitSharedHistories(sh: *SharedHistories) void {
    page_alloc.free(@ptrCast(sh.corr_data));
    page_alloc.free(@ptrCast(sh.pawn_data));
    sh.* = undefined;
}

// Define the engine `sharedHists` member: NumaIndex -> SharedHistories, built with the
// large-page-backed construct/free hooks.
pub const SharedHistoriesMap = shared_histories_map.SharedHistoriesMapOf(SharedHistories);

// Read a SharedHistories and confirm its four size fields match the sizing for
// `thread_count`.
pub fn verifySharedHistories(shared: *const SharedHistories, thread_count: usize) bool {
    return shared_hist.verifySizes(
        shared.corr_size,
        shared.pawn_size,
        shared.size_minus1,
        shared.pawn_hist_size_minus1,
        thread_count,
    );
}

// Return the pawn_entry(pos) row base: pawnHistory[pawn_key & mask] is a [16][64] page.
pub inline fn pawnEntryRow(shared: *SharedHistories, pos: *const Position) [*]i16 {
    const idx: usize = @intCast(pos.st.pawn_key & @as(u64, shared.pawn_hist_size_minus1));
    return shared.pawn_data + idx * hist_pieceto;
}

// Return the correctionHistory[key & sizeMinus1][us] bundle.
pub inline fn corrBundle(shared: *SharedHistories, key: u64) *[2]CorrectionBundle {
    const idx: usize = @intCast(key & @as(u64, shared.size_minus1));
    return &shared.corr_data[idx];
}

test {
    @import("std").testing.refAllDecls(@This());
}
