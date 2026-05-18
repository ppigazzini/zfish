const std = @import("std");

const cluster_size = 3;
const generation_bits: u8 = 5;
const generation_mask: u8 = (1 << generation_bits) - 1;
const bound_shift: u8 = generation_bits;
const bound_mask: u8 = 0b11 << bound_shift;
const pv_shift: u8 = bound_shift + 2;
const pv_mask: u8 = 1 << pv_shift;

pub const TtEntry = extern struct {
    key16: u16,
    depth8: u8,
    gen_bound8: u8,
    move16: u16,
    value16: i16,
    eval16: i16,
};

pub const TtCluster = extern struct {
    entry: [cluster_size]TtEntry,
    padding: [2]u8,
};

pub const TtReadOutput = extern struct {
    move16: u16,
    value16: i16,
    eval16: i16,
    depth: c_int,
    bound: u8,
    is_pv: u8,
};

pub const TtProbeOutput = extern struct {
    found: u8,
    writer_index: u8,
    data: TtReadOutput,
};

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
            .value16 = 0,
            .eval16 = 0,
            .depth = depth_none,
            .bound = 0,
            .is_pv = 0,
        },
    };
}
