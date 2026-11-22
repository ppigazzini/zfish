const std = @import("std");
const tt_types = @import("tt_types");

const cluster_size = tt_types.cluster_size;
const key_bits = tt_types.key_bits;
const key_mask: u64 = (1 << key_bits) - 1;
const value_none: i16 = 32002;
const generation_bits: u8 = 5;
const generation_mask: u8 = (1 << generation_bits) - 1;
const bound_shift: u8 = generation_bits;
const bound_mask: u8 = 0b11 << bound_shift;
const pv_shift: u8 = bound_shift + 2;
const pv_mask: u8 = 1 << pv_shift;
/// Define the is_decisive threshold (VALUE_TB_WIN_IN_MAX_PLY); used by secondary TT aging.
const value_tb_win_in_max_ply: i32 = 31507;
/// Define VALUE_INFINITE; secondary aging excludes |value| == VALUE_INFINITE.
const value_infinite: i32 = 32001;

/// Subtract from a stored depth, saturating at 0 -- upstream's
/// `std::max(int(depth8) - n, 0)` with the comment "guard against racy underflows, default
/// to unoccupied" (tt.cpp:121, tt.cpp:146). Zig's `-%=` WRAPS, so a shallow entry
/// penalized past zero became depth ~253: the DEEPEST possible entry instead of the
/// shallowest, and `depth8 != 0` (the occupancy test at entryRelativeAge's caller) then
/// read a cleared slot as occupied. The clamp is not a C++ nicety; its absence inverted
/// the value.
fn depthSaturatingSub(depth8: u8, n: u8) u8 {
    return depth8 -| n;
}

pub const TtEntry = tt_types.TtEntry;
pub const TtCluster = tt_types.TtCluster;

pub const TtReadOutput = struct {
    move16: u16,
    value16: i16,
    eval16: i16,
    depth: i32,
    bound: u8,
    is_pv: u8,
};

/// Carry the probe result the way upstream's `std::tuple<bool, TTData, TTWriter>` does: the
/// writer is the ENTRY POINTER the walk already held, not upstream's (cluster, index) pair. A
/// pair is a second word live across the whole node, and the store needs it once: entrySave
/// recovers both halves from the address, since a cluster is aligned to its own size.
pub const TtProbeOutput = struct {
    found: u8,
    writer_ptr: *TtEntry,
    data: TtReadOutput,
};

const page_alloc = @import("page_alloc");
const worker_layout = @import("worker_layout");
const thread_ops = @import("thread_ops");
fn reportAllocFailure(mb: usize) noreturn {
    std.debug.print("Failed to allocate {d}MB for transposition table.\n", .{mb});
    std.process.exit(1);
}
/// Zero a [start_cluster, start_cluster+cluster_len) span of the TT -- one thread's share
/// of the parallel clear (single-node: upstream's NUMA-sorted dispatch order is a no-op
/// here, so the spans go out in plain thread order).
fn zeroTtSlice(table_ptr: ?[*]TtCluster, start_cluster: usize, cluster_len: usize) void {
    if (cluster_len == 0) return;
    const table = table_ptr orelse return;
    const cs = @sizeOf(TtCluster);
    const base: [*]u8 = @ptrCast(table);
    @memset(base[start_cluster * cs .. (start_cluster + cluster_len) * cs], 0);
}

pub fn resizeState(
    table_ptr: *?[*]TtCluster,
    cluster_count_ptr: *usize,
    generation_ptr: *u8,
    mb: usize,
    threads: *worker_layout.ThreadPool,
) void {
    // Work in raw bytes here -- the large-page allocator's currency; cluster typing resumes the
    // moment the buffer is handed back to the typed graph handle.
    page_alloc.free(@ptrCast(table_ptr.*));

    const cluster_count = mb * 1024 * 1024 / @sizeOf(TtCluster);
    cluster_count_ptr.* = cluster_count;

    const raw = page_alloc.alloc(cluster_count * @sizeOf(TtCluster)) orelse
        reportAllocFailure(mb);
    const table: [*]TtCluster = @ptrCast(@alignCast(raw));
    table_ptr.* = table;

    clearState(table, cluster_count, generation_ptr, threads);
}

/// Carry one thread's clear span to its zeroing job; the array outlives the dispatch
/// because clearState waits on every thread before returning.
const ClearSliceCtx = struct {
    table: ?[*]TtCluster,
    start: usize,
    len: usize,
};

fn zeroTtSliceJob(raw: ?*anyopaque) void {
    const ctx: *const ClearSliceCtx = @ptrCast(@alignCast(raw.?));
    zeroTtSlice(ctx.table, ctx.start, ctx.len);
}

pub fn clearState(
    table: ?[*]TtCluster,
    cluster_count: usize,
    generation_ptr: *u8,
    threads: *worker_layout.ThreadPool,
) void {
    generation_ptr.* = 0;

    const thread_count = threads.numThreads();
    if (table == null or cluster_count == 0 or thread_count == 0) {
        return;
    }

    // Zero each thread's contiguous span ON that thread, as upstream's
    // TranspositionTable::clear does via run_on_thread (tt.cpp): a serial clear of a
    // multi-GB table is the dominant `ucinewgame` / Hash-resize latency, and the spans
    // are disjoint so the parallel writes need no ordering. Fall back to the calling
    // thread when the per-thread contexts cannot be allocated -- same bytes, serially.
    const ctxs = std.heap.c_allocator.alloc(ClearSliceCtx, thread_count) catch {
        zeroTtSlice(table, 0, cluster_count);
        return;
    };
    defer std.heap.c_allocator.free(ctxs);

    for (ctxs, 0..) |*ctx, thread_index| {
        const stride = cluster_count / thread_count;
        const start = stride * thread_index;
        const len = if (thread_index + 1 != thread_count)
            stride
        else
            cluster_count - start;

        ctx.* = .{ .table = table, .start = start, .len = len };
        thread_ops.runThread(threads, thread_index, &zeroTtSliceJob, ctx);
    }

    for (0..thread_count) |thread_index| {
        thread_ops.waitThread(threads, thread_index);
    }
}

/// Return the cluster that holds `entry`: clusters are aligned to their own 32 bytes.
fn clusterOf(entry: *TtEntry) *TtCluster {
    return @ptrFromInt(@intFromPtr(entry) & ~@as(usize, @sizeOf(TtCluster) - 1));
}

/// Return the bit offset of `entry`'s tag in its cluster's `keys` word.
fn tagShift(entry: *const TtEntry) u6 {
    const slot = ((@intFromPtr(entry) & (@sizeOf(TtCluster) - 1)) - @offsetOf(TtCluster, "entry")) / @sizeOf(TtEntry);
    return @intCast(slot * key_bits);
}

pub fn entrySave(
    entry: *TtEntry,
    key: u64,
    value: i32,
    pv: u8,
    bound: u8,
    depth: i32,
    depth_none: i32,
    move16: u16,
    eval: i32,
    curr_generation: u8,
) void {
    const cluster = clusterOf(entry);
    const shift = tagShift(entry);
    const keys = rlx(u64, &cluster.keys);
    // Xor the stored tag with the new one once (upstream 3bed74c62): zero is a match, and
    // xoring the difference back in at the slot's shift IS the rewrite, so the store needs
    // neither a mask-out nor an or-in.
    const key_diff = ((keys >> shift) ^ key) & key_mask;

    if (move16 != 0 or key_diff != 0) {
        setRlx(u16, &entry.move16, move16);
    }

    if (bound == 3 or key_diff != 0 or
        depth - depth_none + 2 * @as(i32, pv) > @as(i32, rlx(u8, &entry.depth8)) - 4 or
        entryRelativeAge(entry, curr_generation) != 0)
    {
        setRlx(u64, &cluster.keys, keys ^ (key_diff << shift));
        setRlx(u8, &entry.depth8, @intCast(depth - depth_none));
        setRlx(u8, &entry.gen_bound8, curr_generation | (bound << bound_shift) | (pv << pv_shift));
        setRlx(i16, &entry.value16, @intCast(value));
        setRlx(i16, &entry.eval16, @intCast(eval));
    }
    // upstream 94beadffb: apply secondary aging. Matters for elementary mate finding. Age a deep,
    // decisive, non-exact entry that we are NOT overwriting. (depth8 + DEPTH_NONE >= 5; DEPTH_NONE = depth_none = -3.)
    else if (@as(i32, rlx(u8, &entry.depth8)) + depth_none >= 5 and
        ((rlx(u8, &entry.gen_bound8) & bound_mask) >> bound_shift) != 3)
    {
        // Mirror upstream's inner test exactly (tt.cpp:120): `std::abs(v16) <
        // VALUE_INFINITE && is_decisive(v16)`. The `abs < VALUE_INFINITE` half was
        // missing, so an entry holding +/-VALUE_INFINITE was aged here and is not
        // upstream. Keep it a nested `if`, as upstream does, rather than folding it into
        // the else-if chain: the two guards are not the same condition.
        const v16: i32 = @as(i32, rlx(i16, &entry.value16));
        if (@abs(v16) < value_infinite and
            (v16 >= value_tb_win_in_max_ply or v16 <= -value_tb_win_in_max_ply))
        {
            setRlx(u8, &entry.depth8, depthSaturatingSub(rlx(u8, &entry.depth8), 1));
        }
    }
}

/// upstream 319d61eff: decrement a stored entry's depth as a penalty. Saturate at 0
/// (tt.cpp:146) -- a wrapping subtract turned a penalised shallow entry into the deepest
/// entry in the table.
pub fn entryPenalize(entry: *TtEntry, penalty: u8) void {
    setRlx(u8, &entry.depth8, depthSaturatingSub(rlx(u8, &entry.depth8), penalty));
}

/// Take `depth8` from the caller rather than loading it again: probe has already read that byte
/// to decide whether the entry is occupied, and a relaxed atomic load is one the compiler is not
/// allowed to fold away, so asking twice costs a second load of the same byte on every TT hit.
pub fn entryRead(entry: *const TtEntry, depth_none: i32, depth8: u8) TtReadOutput {
    // Take one load of gen_bound8 for both the bound and the pv flag: they are two fields of the
    // same byte, so a single read keeps them mutually consistent and spares a second atomic load
    // the compiler is not allowed to fold away.
    const gb = rlx(u8, &entry.gen_bound8);
    return .{
        .move16 = rlx(u16, &entry.move16),
        .value16 = rlx(i16, &entry.value16),
        .eval16 = rlx(i16, &entry.eval16),
        .depth = depth_none + @as(i32, depth8),
        .bound = (gb & bound_mask) >> bound_shift,
        .is_pv = if ((gb & pv_mask) != 0) 1 else 0,
    };
}

/// Read and write every TT field as a RELAXED atomic, mirroring upstream's RelaxedAtomic<T>
/// accessors (misc.h:351-370). tt.h states that racy concurrent updates between threads are
/// intended; relaxed is what makes that race defined rather than undefined, forbidding the
/// compiler to tear a field or rematerialise a load after the key comparison it was checked
/// against. It is NOT ordering: no field is ordered against any other, exactly as upstream.
inline fn rlx(comptime T: type, p: *const T) T {
    return @atomicLoad(T, p, .monotonic);
}
inline fn setRlx(comptime T: type, p: *T, v: T) void {
    @atomicStore(T, p, v, .monotonic);
}

/// Return the entry's age. Count generations the way a clock counts hours: `0 - 1` must be
/// 31, so the subtract WRAPS and the mask then discards the pv/bound bits the borrow ran
/// through. A saturating or checked subtract here would read every entry written just
/// before a wrap as the freshest in the table.
pub fn entryRelativeAge(entry: *const TtEntry, curr_generation: u8) u8 {
    return (curr_generation -% rlx(u8, &entry.gen_bound8)) & generation_mask;
}

pub fn generationNext(curr_generation: u8) u8 {
    return (curr_generation +% 1) & generation_mask;
}

pub fn hashfull(
    clusters: [*]const TtCluster,
    cluster_count: usize,
    generation: u8,
    max_age: i32,
) i32 {
    var count: i32 = 0;
    var cluster_index: usize = 0;
    const limit = @min(cluster_count, 1000);

    while (cluster_index < limit) : (cluster_index += 1) {
        for (0..cluster_size) |entry_index| {
            const entry = &clusters[cluster_index].entry[entry_index];
            if (rlx(u8, &entry.depth8) != 0 and entryRelativeAge(entry, generation) <= max_age) {
                count += 1;
            }
        }
    }

    return @divTrunc(count, cluster_size);
}

pub fn firstEntryIndex(key: u64, cluster_count: usize) usize {
    // mul_hi64 of anything with 0 is 0, so an unsized table indexes cluster 0 with
    // no branch; the search path never runs unsized (probeTable's contract below).
    return @intCast((@as(u128, key) * @as(u128, cluster_count)) >> 64);
}

/// Preload the cluster KEY maps onto, a non-blocking read hint issued a few instructions
/// ahead of the matching probeTable so the line is arriving by the time the probe reads it
/// (upstream tt.cpp first_entry, called from the search do_move). The hint changes no
/// value, only when the line lands. Uses the SAME mul_hi64 index the probe uses. Read
/// hint (rw=.read), highest temporal locality (locality=3): the cluster is about to be
/// probed and re-read on a hit. Take the table non-null, per probeTable's contract:
/// the guard branches ran once per do_move against a table the search cannot lack.
pub inline fn prefetch(clusters: [*]TtCluster, cluster_count: usize, key: u64) void {
    @prefetch(&clusters[firstEntryIndex(key, cluster_count)], .{ .rw = .read, .locality = 3, .cache = .data });
}

/// Score an entry for replacement: depth is worth keeping, and each generation of staleness
/// costs eight plies of it.
inline fn replacementScore(entry: *const TtEntry, generation: u8) i32 {
    return @as(i32, rlx(u8, &entry.depth8)) - 8 * @as(i32, entryRelativeAge(entry, generation));
}

pub fn probe(
    cluster: *TtCluster,
    key: u64,
    generation: u8,
    depth_none: i32,
) TtProbeOutput {
    // Compare the key's low 21 bits with all three tags at once (upstream ff3a6c508). The
    // borrow trick sets bit 20 of the FIRST block that matches: no block below a match can
    // borrow, so the lowest set bit is exact, and only blocks above it may carry garbage.
    const key_lsb: u64 = 1 | (1 << key_bits) | (1 << (2 * key_bits));
    const key_msb: u64 = key_lsb << (key_bits - 1);
    const key_xors = rlx(u64, &cluster.keys) ^ (key_lsb * (key & key_mask));
    const matches = (key_xors -% key_lsb) & ~key_xors & key_msb;

    if (matches != 0) {
        // The match bit is bit 20 of its block -- 20, 41 or 62 -- so a shift by 4 minus one
        // names the slot without a divide by 21 (upstream 3bed74c62).
        comptime std.debug.assert(key_bits == 21);
        const entry = &cluster.entry[(@ctz(matches) >> 4) - 1];
        const depth8 = rlx(u8, &entry.depth8);
        return .{
            .found = if (depth8 != 0) 1 else 0,
            .writer_ptr = entry,
            .data = entryRead(entry, depth_none, depth8),
        };
    }

    // Carry the running minimum's score rather than re-reading the incumbent's two fields at
    // every comparison (upstream 3bed74c62).
    var replace: *TtEntry = &cluster.entry[0];
    var replace_score = replacementScore(replace, generation);
    var candidate_index: usize = 1;
    while (candidate_index < cluster_size) : (candidate_index += 1) {
        const candidate_entry = &cluster.entry[candidate_index];
        const candidate_score = replacementScore(candidate_entry, generation);
        if (replace_score > candidate_score) {
            replace = candidate_entry;
            replace_score = candidate_score;
        }
    }

    return .{
        .found = 0,
        .writer_ptr = replace,
        .data = .{
            .move16 = 0,
            .value16 = value_none,
            .eval16 = value_none,
            .depth = depth_none,
            .bound = 0,
            .is_pv = 0,
        },
    };
}

/// Probe the sized table. Contract: the table exists and cluster_count > 0 -- every
/// caller runs inside a search, and a search cannot run on an unsized table (the very
/// first entrySave would write through the writer pointer). The old per-probe null/zero
/// guard paid two loads and two branches per node for a case that could only crash
/// later anyway; the QCtx now carries the non-optional pointer.
pub fn probeTable(
    clusters: [*]TtCluster,
    cluster_count: usize,
    key: u64,
    generation: u8,
    depth_none: i32,
) TtProbeOutput {
    return probe(&clusters[firstEntryIndex(key, cluster_count)], key, generation, depth_none);
}

/// Hold the TranspositionTable handle: a 24-byte object holding a TtCluster* table, the
/// cluster count and the 8-bit generation. The heavy logic lives in the functions above;
/// serve as the owning object the Engine graph holds, delegating to them.
pub const TranspositionTable = struct {
    table: ?[*]TtCluster = null,
    cluster_count: usize = 0,
    generation8: u8 = 0,

    pub fn newSearch(self: *TranspositionTable) void {
        self.generation8 = generationNext(self.generation8);
    }
    pub fn generation(self: *const TranspositionTable) u8 {
        return self.generation8;
    }
    pub fn firstEntry(self: *const TranspositionTable, key: u64) usize {
        return firstEntryIndex(key, self.cluster_count);
    }
    pub fn hashfullPermille(self: *const TranspositionTable, max_age: i32) i32 {
        return hashfull(self.table.?, self.cluster_count, self.generation8, max_age);
    }
};

comptime {
    // TranspositionTable handle
}

test "TranspositionTable handle: layout and generation cycling" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(TranspositionTable));
    var tt = TranspositionTable{ .cluster_count = 1000, .generation8 = 0 };
    try std.testing.expectEqual(@as(usize, 0), tt.firstEntry(0));
    const g0 = tt.generation();
    tt.newSearch();
    try std.testing.expect(tt.generation() != g0); // advance the generation by GENERATION_DELTA
}

test "tt: the probe matches the first of three 21-bit tags, and a store rewrites only its own" {
    var cluster: TtCluster = std.mem.zeroes(TtCluster);
    const key_a: u64 = 0xABCD_EF01_2345_6789;
    const key_b: u64 = key_a ^ (1 << 20); // differs from key_a in bit 20 alone: 16 bits miss it
    const key_c: u64 = key_a ^ (1 << 40); // differs above the tag: the same tag as key_a

    // A miss on an empty cluster picks slot 0; store key_b there.
    const miss = probe(&cluster, key_b, 0, -3);
    try std.testing.expectEqual(@as(u8, 0), miss.found);
    try std.testing.expectEqual(&cluster.entry[0], miss.writer_ptr);
    entrySave(miss.writer_ptr, key_b, 10, 0, 1, 5, -3, 0x123, 7, 0);

    // key_a misses key_b's tag and takes the next victim, slot 1 (slot 0 is deeper now).
    const miss_a = probe(&cluster, key_a, 0, -3);
    try std.testing.expectEqual(@as(u8, 0), miss_a.found);
    try std.testing.expectEqual(&cluster.entry[1], miss_a.writer_ptr);
    entrySave(miss_a.writer_ptr, key_a, 20, 0, 1, 6, -3, 0x456, 8, 0);

    // Both tags sit in their own blocks, and the third block is still empty.
    try std.testing.expectEqual(key_b & key_mask, cluster.keys & key_mask);
    try std.testing.expectEqual(key_a & key_mask, (cluster.keys >> key_bits) & key_mask);
    try std.testing.expectEqual(@as(u64, 0), cluster.keys >> (2 * key_bits));

    const hit_b = probe(&cluster, key_b, 0, -3);
    try std.testing.expectEqual(@as(u8, 1), hit_b.found);
    try std.testing.expectEqual(@as(u16, 0x123), hit_b.data.move16);
    const hit_a = probe(&cluster, key_a, 0, -3);
    try std.testing.expectEqual(&cluster.entry[1], hit_a.writer_ptr);
    try std.testing.expectEqual(@as(u16, 0x456), hit_a.data.move16);
    // A key that agrees in the low 21 bits is the same tag: a collision, as upstream.
    try std.testing.expectEqual(&cluster.entry[1], probe(&cluster, key_c, 0, -3).writer_ptr);
}

test "tt: depth penalty saturates at 0 instead of wrapping" {
    // Drive the exact case the wrapping subtract inverted: penalise a shallow entry past
    // zero. `-%=` yielded 253 -- the deepest possible entry, and non-zero, so the slot
    // also read as occupied. Upstream clamps to 0 (tt.cpp:146).
    var entry: TtEntry = std.mem.zeroes(TtEntry);
    entry.depth8 = 2;
    entryPenalize(&entry, 5);
    try std.testing.expectEqual(@as(u8, 0), entry.depth8);
    try std.testing.expectEqual(@as(u8, 2 -% @as(u8, 5)), @as(u8, 253)); // what it used to do

    entry.depth8 = 20;
    entryPenalize(&entry, 5);
    try std.testing.expectEqual(@as(u8, 15), entry.depth8); // normal path unchanged
}
