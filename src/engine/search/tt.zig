const std = @import("std");
const tt_types = @import("tt_types");

const cluster_size = tt_types.cluster_size;
const value_none: i16 = 32002;
const generation_bits: u8 = 5;
const generation_mask: u8 = (1 << generation_bits) - 1;
const bound_shift: u8 = generation_bits;
const bound_mask: u8 = 0b11 << bound_shift;
const pv_shift: u8 = bound_shift + 2;
const pv_mask: u8 = 1 << pv_shift;
// is_decisive threshold (VALUE_TB_WIN_IN_MAX_PLY); used by secondary TT aging.
const value_tb_win_in_max_ply: c_int = 31507;

pub const TtEntry = tt_types.TtEntry;
pub const TtCluster = tt_types.TtCluster;

pub const TtReadOutput = struct {
    move16: u16,
    value16: i16,
    eval16: i16,
    depth: c_int,
    bound: u8,
    is_pv: u8,
};

pub const TtProbeOutput = struct {
    found: u8,
    writer_index: u8,
    data: TtReadOutput,
};

pub const TtProbeTableOutput = struct {
    found: u8,
    writer_ptr: ?*TtEntry,
    data: TtReadOutput,
};

const memory = @import("memory");
const graph_layout = @import("graph_layout");
const thread_port = @import("thread");
fn reportAllocFailure(mb: usize) noreturn {
    std.debug.print("Failed to allocate {d}MB for transposition table.\n", .{mb});
    std.process.exit(1);
}
// Zero a [start_cluster, start_cluster+cluster_len) span of the TT (single-node: the
// per-thread parallel-clear NUMA split is a no-op here).
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
    threads: *graph_layout.ThreadPool,
) void {
    // The large-page allocator deals in raw bytes; the cluster typing resumes the
    // moment the buffer is handed back to the typed graph handle.
    memory.alignedLargePagesFree(@ptrCast(table_ptr.*));

    const cluster_count = mb * 1024 * 1024 / @sizeOf(TtCluster);
    cluster_count_ptr.* = cluster_count;

    const raw = memory.alignedLargePagesAlloc(cluster_count * @sizeOf(TtCluster)) orelse
        reportAllocFailure(mb);
    const table: [*]TtCluster = @ptrCast(@alignCast(raw));
    table_ptr.* = table;

    clearState(table, cluster_count, generation_ptr, threads);
}

pub fn clearState(
    table: ?[*]TtCluster,
    cluster_count: usize,
    generation_ptr: *u8,
    threads: *graph_layout.ThreadPool,
) void {
    generation_ptr.* = 0;

    const thread_count = threads.numThreads();
    if (table == null or cluster_count == 0 or thread_count == 0) {
        return;
    }

    var thread_index: usize = 0;
    while (thread_index < thread_count) : (thread_index += 1) {
        const stride = cluster_count / thread_count;
        const start = stride * thread_index;
        const len = if (thread_index + 1 != thread_count)
            stride
        else
            cluster_count - start;

        zeroTtSlice(table, start, len);
    }

    thread_index = 0;
    while (thread_index < thread_count) : (thread_index += 1) {
        thread_port.waitThread(threads, thread_index);
    }
}

pub fn entrySave(
    entry: *TtEntry,
    key: u64,
    value: c_int,
    pv: u8,
    bound: u8,
    depth: c_int,
    depth_none: c_int,
    move16: u16,
    eval: c_int,
    curr_generation: u8,
) void {
    const key16: u16 = @truncate(key);

    if (move16 != 0 or key16 != entry.key16) {
        entry.move16 = move16;
    }

    if (bound == 3 or key16 != entry.key16 or
        depth - depth_none + 2 * @as(c_int, pv) > @as(c_int, entry.depth8) - 4 or
        entryRelativeAge(entry, curr_generation) != 0)
    {
        entry.key16 = key16;
        entry.depth8 = @intCast(depth - depth_none);
        entry.gen_bound8 = curr_generation | (bound << bound_shift) | (pv << pv_shift);
        entry.value16 = @intCast(value);
        entry.eval16 = @intCast(eval);
    }
    // upstream 94beadffb: secondary aging. Important for elementary mate finding. Age a deep,
    // decisive, non-exact entry that we are NOT overwriting. (depth8 + DEPTH_NONE >= 5; DEPTH_NONE = depth_none = -3.)
    else if (@as(c_int, entry.depth8) + depth_none >= 5 and
        (@as(c_int, entry.value16) >= value_tb_win_in_max_ply or @as(c_int, entry.value16) <= -value_tb_win_in_max_ply) and
        ((entry.gen_bound8 & bound_mask) >> bound_shift) != 3)
    {
        entry.depth8 -%= 1;
    }
}

// upstream 319d61eff: decrement a stored entry's depth as a penalty.
pub fn entryPenalize(entry: *TtEntry, penalty: u8) void {
    entry.depth8 -%= penalty;
}

pub fn entryRead(entry: *const TtEntry, depth_none: c_int) TtReadOutput {
    return .{
        .move16 = entry.move16,
        .value16 = entry.value16,
        .eval16 = entry.eval16,
        .depth = depth_none + @as(c_int, entry.depth8),
        .bound = (entry.gen_bound8 & bound_mask) >> bound_shift,
        .is_pv = if ((entry.gen_bound8 & pv_mask) != 0) 1 else 0,
    };
}

pub fn entryRelativeAge(entry: *const TtEntry, curr_generation: u8) u8 {
    return (curr_generation -% entry.gen_bound8) & generation_mask;
}

pub fn generationNext(curr_generation: u8) u8 {
    return (curr_generation +% 1) & generation_mask;
}

pub fn hashfull(
    clusters: [*]const TtCluster,
    cluster_count: usize,
    generation: u8,
    max_age: c_int,
) c_int {
    var count: c_int = 0;
    var cluster_index: usize = 0;
    const limit = @min(cluster_count, 1000);

    while (cluster_index < limit) : (cluster_index += 1) {
        var entry_index: usize = 0;
        while (entry_index < cluster_size) : (entry_index += 1) {
            const entry = &clusters[cluster_index].entry[entry_index];
            if (entry.depth8 != 0 and entryRelativeAge(entry, generation) <= max_age) {
                count += 1;
            }
        }
    }

    return @divTrunc(count, cluster_size);
}

pub fn firstEntryIndex(key: u64, cluster_count: usize) usize {
    if (cluster_count == 0) {
        return 0;
    }

    return @intCast((@as(u128, key) * @as(u128, cluster_count)) >> 64);
}

pub fn probe(
    cluster: *const TtCluster,
    key: u64,
    generation: u8,
    depth_none: c_int,
) TtProbeOutput {
    const key16: u16 = @truncate(key);

    var entry_index: usize = 0;
    while (entry_index < cluster_size) : (entry_index += 1) {
        const entry = &cluster.entry[entry_index];
        if (entry.key16 == key16) {
            return .{
                .found = if (entry.depth8 != 0) 1 else 0,
                .writer_index = @intCast(entry_index),
                .data = entryRead(entry, depth_none),
            };
        }
    }

    var replace_index: usize = 0;
    var candidate_index: usize = 1;
    while (candidate_index < cluster_size) : (candidate_index += 1) {
        const replace_entry = &cluster.entry[replace_index];
        const candidate_entry = &cluster.entry[candidate_index];
        const replace_score = @as(c_int, replace_entry.depth8) - 8 * @as(c_int, entryRelativeAge(replace_entry, generation));
        const candidate_score = @as(c_int, candidate_entry.depth8) - 8 * @as(c_int, entryRelativeAge(candidate_entry, generation));
        if (replace_score > candidate_score) {
            replace_index = candidate_index;
        }
    }

    return .{
        .found = 0,
        .writer_index = @intCast(replace_index),
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

pub fn probeTable(
    table: ?[*]TtCluster,
    cluster_count: usize,
    key: u64,
    generation: u8,
    depth_none: c_int,
) TtProbeTableOutput {
    if (table == null or cluster_count == 0) {
        return .{
            .found = 0,
            .writer_ptr = null,
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

    const cluster_index = firstEntryIndex(key, cluster_count);
    const clusters: [*]TtCluster = table.?;
    const result = probe(&clusters[cluster_index], key, generation, depth_none);

    const writer_ptr: *TtEntry = &clusters[cluster_index].entry[result.writer_index];

    return .{
        .found = result.found,
        .writer_ptr = writer_ptr,
        .data = result.data,
    };
}

// TranspositionTable handle: a 24-byte object holding a TtCluster* table, the
// cluster count and the 8-bit generation. The heavy logic lives in the functions above;
// this is the owning object the Engine graph holds, delegating to them.
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
    pub fn hashfullPermille(self: *const TranspositionTable, max_age: c_int) c_int {
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
    try std.testing.expect(tt.generation() != g0); // generation advanced by GENERATION_DELTA
}
