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
// Define the is_decisive threshold (VALUE_TB_WIN_IN_MAX_PLY); used by secondary TT aging.
const value_tb_win_in_max_ply: i32 = 31507;
// Define VALUE_INFINITE; secondary aging excludes |value| == VALUE_INFINITE.
const value_infinite: i32 = 32001;

// Subtract from a stored depth, saturating at 0 -- upstream's
// `std::max(int(depth8) - n, 0)` with the comment "guard against racy underflows, default
// to unoccupied" (tt.cpp:121, tt.cpp:146). Zig's `-%=` WRAPS, so a shallow entry
// penalized past zero became depth ~253: the DEEPEST possible entry instead of the
// shallowest, and `depth8 != 0` (the occupancy test at entryRelativeAge's caller) then
// read a cleared slot as occupied. The clamp is not a C++ nicety; its absence inverted
// the value.
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

const page_alloc = @import("page_alloc");
const worker_layout = @import("worker_layout");
const thread_ops = @import("thread_ops");
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
        thread_ops.waitThread(threads, thread_index);
    }
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
    const key16: u16 = @truncate(key);

    if (move16 != 0 or key16 != rlx(u16, &entry.key16)) {
        setRlx(u16, &entry.move16, move16);
    }

    if (bound == 3 or key16 != rlx(u16, &entry.key16) or
        depth - depth_none + 2 * @as(i32, pv) > @as(i32, rlx(u8, &entry.depth8)) - 4 or
        entryRelativeAge(entry, curr_generation) != 0)
    {
        setRlx(u16, &entry.key16, key16);
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

// upstream 319d61eff: decrement a stored entry's depth as a penalty. Saturate at 0
// (tt.cpp:146) -- a wrapping subtract turned a penalised shallow entry into the deepest
// entry in the table.
pub fn entryPenalize(entry: *TtEntry, penalty: u8) void {
    setRlx(u8, &entry.depth8, depthSaturatingSub(rlx(u8, &entry.depth8), penalty));
}

pub fn entryRead(entry: *const TtEntry, depth_none: i32) TtReadOutput {
    // Take one load of gen_bound8 for both the bound and the pv flag: they are two fields of the
    // same byte, so a single read keeps them mutually consistent and spares a second atomic load
    // the compiler is not allowed to fold away.
    const gb = rlx(u8, &entry.gen_bound8);
    return .{
        .move16 = rlx(u16, &entry.move16),
        .value16 = rlx(i16, &entry.value16),
        .eval16 = rlx(i16, &entry.eval16),
        .depth = depth_none + @as(i32, rlx(u8, &entry.depth8)),
        .bound = (gb & bound_mask) >> bound_shift,
        .is_pv = if ((gb & pv_mask) != 0) 1 else 0,
    };
}

// Read and write every TT field as a RELAXED atomic, mirroring upstream's RelaxedAtomic<T>
// accessors (misc.h:351-370). tt.h states that racy concurrent updates between threads are
// intended; relaxed is what makes that race defined rather than undefined, forbidding the
// compiler to tear a field or rematerialise a load after the key comparison it was checked
// against. It is NOT ordering: no field is ordered against any other, exactly as upstream.
inline fn rlx(comptime T: type, p: *const T) T {
    return @atomicLoad(T, p, .monotonic);
}
inline fn setRlx(comptime T: type, p: *T, v: T) void {
    @atomicStore(T, p, v, .monotonic);
}

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
        var entry_index: usize = 0;
        while (entry_index < cluster_size) : (entry_index += 1) {
            const entry = &clusters[cluster_index].entry[entry_index];
            if (rlx(u8, &entry.depth8) != 0 and entryRelativeAge(entry, generation) <= max_age) {
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
    depth_none: i32,
) TtProbeOutput {
    const key16: u16 = @truncate(key);

    var entry_index: usize = 0;
    while (entry_index < cluster_size) : (entry_index += 1) {
        const entry = &cluster.entry[entry_index];
        if (rlx(u16, &entry.key16) == key16) {
            return .{
                .found = if (rlx(u8, &entry.depth8) != 0) 1 else 0,
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
        const replace_score = @as(i32, rlx(u8, &replace_entry.depth8)) - 8 * @as(i32, entryRelativeAge(replace_entry, generation));
        const candidate_score = @as(i32, rlx(u8, &candidate_entry.depth8)) - 8 * @as(i32, entryRelativeAge(candidate_entry, generation));
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
    depth_none: i32,
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

// Hold the TranspositionTable handle: a 24-byte object holding a TtCluster* table, the
// cluster count and the 8-bit generation. The heavy logic lives in the functions above;
// serve as the owning object the Engine graph holds, delegating to them.
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
