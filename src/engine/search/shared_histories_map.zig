// Native shared-histories map — the engine member mapping NumaIndex -> SharedHistories.
// One SharedHistories per NUMA node, built lazily by try_emplace(numa, threadCount) and
// read by workers via at(numa). The element (SharedHistories) owns two large-page
// arrays, so the map needs a construct hook (constructSharedHistories) and a free hook
// (release the arrays).
//
// Defined as a generic over the entry type + its construct/free, so the CONTAINER
// logic unit-tests standalone (std-only) with a mock entry, while board/position.zig
// instantiates it with the real SharedHistories + the large-page-backed hooks.

const std = @import("std");

/// NumaIndex map key.
pub const NumaIndex = usize;

pub fn SharedHistoriesMapOf(comptime Entry: type) type {
    return struct {
        const Self = @This();

        /// Build one node's Entry sized for `thread_count` threads (try_emplace's value
        /// ctor). May fail to allocate.
        pub const ConstructFn = *const fn (thread_count: usize) error{OutOfMemory}!Entry;
        /// Release one node's Entry (free its large-page arrays).
        pub const FreeFn = *const fn (entry: *Entry) void;

        entries: std.AutoHashMapUnmanaged(NumaIndex, Entry) = .empty,
        allocator: std.mem.Allocator,
        construct: ConstructFn,
        free: FreeFn,

        pub fn init(allocator: std.mem.Allocator, construct: ConstructFn, free: FreeFn) Self {
            return .{ .allocator = allocator, .construct = construct, .free = free };
        }

        pub fn deinit(self: *Self) void {
            self.clear();
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }

        /// try_emplace(numa, threadCount): construct + insert iff absent.
        pub fn tryEmplace(self: *Self, numa: NumaIndex, thread_count: usize) !void {
            const gop = try self.entries.getOrPut(self.allocator, numa);
            if (!gop.found_existing) {
                gop.value_ptr.* = self.construct(thread_count) catch |e| {
                    _ = self.entries.remove(numa);
                    return e;
                };
            }
        }

        /// at(numa): the node's Entry (must exist).
        pub fn at(self: *Self, numa: NumaIndex) *Entry {
            return self.entries.getPtr(numa) orelse unreachable;
        }

        pub fn contains(self: *const Self, numa: NumaIndex) bool {
            return self.entries.contains(numa);
        }

        pub fn count(self: *const Self) usize {
            return self.entries.count();
        }

        /// clear(): free + drop every entry.
        pub fn clear(self: *Self) void {
            var it = self.entries.iterator();
            while (it.next()) |e| self.free(e.value_ptr);
            self.entries.clearRetainingCapacity();
        }
    };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

// Mock entry: a tagged value + a global live-count so free() is observable.
const MockEntry = struct { thread_count: usize, freed: bool = false };
var live_entries: usize = 0;

fn mockConstruct(thread_count: usize) error{OutOfMemory}!MockEntry {
    live_entries += 1;
    return .{ .thread_count = thread_count };
}
fn mockFree(entry: *MockEntry) void {
    live_entries -= 1;
    entry.freed = true;
}

const MockMap = SharedHistoriesMapOf(MockEntry);

test "tryEmplace constructs once per node; at returns it; clear frees all" {
    live_entries = 0;
    var map = MockMap.init(testing.allocator, mockConstruct, mockFree);
    defer map.deinit();

    try map.tryEmplace(0, 8);
    try map.tryEmplace(1, 4);
    try map.tryEmplace(0, 99); // already present → no reconstruct
    try testing.expectEqual(@as(usize, 2), map.count());
    try testing.expectEqual(@as(usize, 2), live_entries);
    try testing.expectEqual(@as(usize, 8), map.at(0).thread_count); // not overwritten
    try testing.expectEqual(@as(usize, 4), map.at(1).thread_count);
    try testing.expect(map.contains(0) and !map.contains(2));

    map.clear();
    try testing.expectEqual(@as(usize, 0), map.count());
    try testing.expectEqual(@as(usize, 0), live_entries); // every entry freed
}

test "deinit frees outstanding entries (no leak of element arrays)" {
    live_entries = 0;
    var map = MockMap.init(testing.allocator, mockConstruct, mockFree);
    try map.tryEmplace(0, 1);
    try map.tryEmplace(3, 2);
    try testing.expectEqual(@as(usize, 2), live_entries);
    map.deinit();
    try testing.expectEqual(@as(usize, 0), live_entries);
}

// Construct-failure rollback. try_emplace inserts the map slot (getOrPut) BEFORE
// building the value, so if construct fails it must remove that slot again -- otherwise
// a later at()/clear() would touch an uninitialized Entry (and clear would call free on
// garbage). A checkAllAllocationFailures gate can't reach this branch (mockConstruct
// doesn't allocate, so the failing allocator never trips it), so drive it directly with
// a construct hook that fails.
fn mockConstructFail(thread_count: usize) error{OutOfMemory}!MockEntry {
    _ = thread_count;
    return error.OutOfMemory;
}

test "tryEmplace rolls back the inserted slot when construct fails" {
    live_entries = 0;
    var map = MockMap.init(testing.allocator, mockConstructFail, mockFree);
    defer map.deinit();

    try testing.expectError(error.OutOfMemory, map.tryEmplace(0, 8));
    // the failed construct must leave NO trace: no slot, no phantom live entry.
    try testing.expectEqual(@as(usize, 0), map.count());
    try testing.expect(!map.contains(0));
    try testing.expectEqual(@as(usize, 0), live_entries);

    // and the map is still usable afterwards -- a good construct now succeeds.
    map.construct = mockConstruct;
    try map.tryEmplace(0, 8);
    try testing.expectEqual(@as(usize, 1), map.count());
    try testing.expectEqual(@as(usize, 8), map.at(0).thread_count);
}
