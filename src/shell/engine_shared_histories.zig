// Engine side shared-histories map (ANNEX B.6): the numa-replicated history map the
// engine owns outside the WorkerLayout graph, + its accessors and teardown. Owns its
// state (the lazy map); position + std only.

const std = @import("std");
const position_port = @import("position");
const search_driver = @import("search_driver");

var side_shared_histories: ?search_driver.SharedHistoriesMap = null;

fn sideSharedHistories() *search_driver.SharedHistoriesMap {
    if (side_shared_histories == null) {
        side_shared_histories = search_driver.SharedHistoriesMap.init(
            std.heap.c_allocator,
            search_driver.constructSharedHistories,
            search_driver.deinitSharedHistories,
        );
    }
    return &side_shared_histories.?;
}

pub fn sharedHistoriesPtr() *search_driver.SharedHistoriesMap {
    return sideSharedHistories();
}

pub fn sharedHistoriesClear(map: *search_driver.SharedHistoriesMap) void {
    map.clear();
}

pub fn sharedHistoriesInsert(map: *search_driver.SharedHistoriesMap, numa_index: usize, size: usize) void {
    map.tryEmplace(numa_index, size) catch @panic("OOM: native sharedHistories insert");
}

pub fn sharedHistoriesAt(map: *search_driver.SharedHistoriesMap, numa_index: usize) *search_driver.SharedHistories {
    return map.at(numa_index);
}

// Free the side map (each element's large-page DynStats arrays + the bucket
// storage) at engine teardown + reset for any re-construct (valgrind).
pub fn freeSharedHistories() void {
    if (side_shared_histories) |*m| {
        m.deinit();
        side_shared_histories = null;
    }
}
