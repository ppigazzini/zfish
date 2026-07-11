// Engine side shared-histories map (ANNEX B.6): the numa-replicated history map the
// engine owns outside the WorkerLayout graph, + its accessors and teardown. Owns its
// state (the lazy map); position + std only.

const std = @import("std");
const position_port = @import("position");

var side_shared_histories: ?position_port.SharedHistoriesMap = null;

fn sideSharedHistories() *position_port.SharedHistoriesMap {
    if (side_shared_histories == null) {
        side_shared_histories = position_port.SharedHistoriesMap.init(
            std.heap.c_allocator,
            position_port.constructSharedHistories,
            position_port.deinitSharedHistories,
        );
    }
    return &side_shared_histories.?;
}

pub fn sharedHistoriesPtr() *position_port.SharedHistoriesMap {
    return sideSharedHistories();
}

pub fn sharedHistoriesClear(map: *position_port.SharedHistoriesMap) void {
    map.clear();
}

pub fn sharedHistoriesInsert(map: *position_port.SharedHistoriesMap, numa_index: usize, size: usize) void {
    map.tryEmplace(numa_index, size) catch @panic("OOM: native sharedHistories insert");
}

pub fn sharedHistoriesAt(map: *position_port.SharedHistoriesMap, numa_index: usize) *position_port.SharedHistories {
    return map.at(numa_index);
}

// Free the side map (each element's large-page DynStats arrays + the bucket
// storage) at engine teardown + reset for any re-construct (H5/valgrind).
pub fn freeSharedHistories() void {
    if (side_shared_histories) |*m| {
        m.deinit();
        side_shared_histories = null;
    }
}
