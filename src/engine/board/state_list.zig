// Native StateList — the engine `states` member, holding the chain of StateInfo
// records that back a position and its applied moves.
//
// CONTRACT:
//   - starts non-empty (one root StateInfo);
//   - reset()  -> drops to a single fresh root and returns its address;
//   - push()   -> appends one StateInfo and returns its address;
//   - back()   -> address of the most recently added StateInfo;
//   - POINTER STABILITY is mandatory: doMove writes into the latest StateInfo
//     while earlier ones remain referenced by the search, so a record's address
//     must never change once handed out. Here every StateInfo is its own heap
//     allocation, which is strictly pointer-stable.
//
// StateInfo is treated as an opaque 192-byte POD block (graph_layout.state_info_size);
// the native runtime memsets/fills it via Position, so this module owns lifetime +
// ordering only, not StateInfo's internals.

const std = @import("std");
const position_types = @import("position_types");

/// The typed StateInfo the engine fills through Position. This module owns
/// its lifetime + ordering only, not its internals, but the handles it hands out are
/// now typed `*StateInfo` rather than `*anyopaque`. @sizeOf(StateInfo) == 192, pinned
/// in position_types + graph_layout, so the per-record heap block is exactly one.
pub const StateInfo = position_types.StateInfo;

/// The StateInfo block size. Pinned by graph_layout.zig (state_info_size = 192).
pub const state_info_size: usize = 192;
pub const state_info_align: usize = 8;

comptime {
    std.debug.assert(@sizeOf(StateInfo) == state_info_size);
}

pub const StateList = struct {
    allocator: std.mem.Allocator,
    /// One heap block per StateInfo → addresses are stable for the block's lifetime.
    blocks: std.ArrayListUnmanaged(*StateInfo),

    /// Construct with a single zeroed root StateInfo.
    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!StateList {
        var self = StateList{ .allocator = allocator, .blocks = .empty };
        errdefer self.deinit();
        _ = try self.appendBlock();
        return self;
    }

    pub fn deinit(self: *StateList) void {
        for (self.blocks.items) |block| self.allocator.destroy(block);
        self.blocks.deinit(self.allocator);
        self.* = undefined;
    }

    fn appendBlock(self: *StateList) error{OutOfMemory}!*StateInfo {
        const block = try self.allocator.create(StateInfo);
        // If the blocks-vector growth below fails, `block` isn't tracked yet, so free
        // it here -- otherwise deinit (which only walks blocks.items) would leak it.
        errdefer self.allocator.destroy(block);
        @memset(std.mem.asBytes(block), 0);
        try self.blocks.append(self.allocator, block);
        return block;
    }

    /// Drop to a single fresh root StateInfo and return its address.
    pub fn reset(self: *StateList) error{OutOfMemory}!*StateInfo {
        // Reuse the first block (already allocated) and free the rest, so reset
        // cannot fail after the list exists.
        for (self.blocks.items[1..]) |block| self.allocator.destroy(block);
        self.blocks.shrinkRetainingCapacity(1);
        @memset(std.mem.asBytes(self.blocks.items[0]), 0);
        return self.blocks.items[0];
    }

    /// Append one StateInfo and return its address.
    pub fn push(self: *StateList) error{OutOfMemory}!*StateInfo {
        return self.appendBlock();
    }

    /// Address of the most recently added StateInfo (`&back()`).
    pub fn back(self: *StateList) *StateInfo {
        return self.blocks.items[self.blocks.items.len - 1];
    }

    /// Whether the list currently holds any StateInfo (after a handoff the owning
    /// pointer is nulled).
    pub fn hasStates(self: *const StateList) bool {
        return self.blocks.items.len != 0;
    }

    pub fn len(self: *const StateList) usize {
        return self.blocks.items.len;
    }
};

// Owns a StateList and supports the MOVE semantics the setupStates adopt relies on:
// moveOut() hands the StateList to the pool and NULLS the wrapper, so a later
// destroy() frees nothing. The position-setup flow (engine.zig) builds the chain
// here via reset()/push(); at search start the pool adopts it (moveOut) or the slot's list.
pub const PendingStateStorage = struct {
    allocator: std.mem.Allocator,
    list: ?*StateList,

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*PendingStateStorage {
        const self = try allocator.create(PendingStateStorage);
        errdefer allocator.destroy(self);
        const list = try allocator.create(StateList);
        errdefer allocator.destroy(list);
        list.* = try StateList.init(allocator);
        self.* = .{ .allocator = allocator, .list = list };
        return self;
    }

    pub fn destroy(self: *PendingStateStorage) void {
        if (self.list) |l| {
            l.deinit();
            self.allocator.destroy(l);
        }
        self.allocator.destroy(self);
    }

    /// Drop to a single fresh root and return its address (storage_reset). Re-creates the
    /// list if it was moved out.
    pub fn reset(self: *PendingStateStorage) error{OutOfMemory}!*StateInfo {
        if (self.list == null) {
            const list = try self.allocator.create(StateList);
            errdefer self.allocator.destroy(list);
            list.* = try StateList.init(self.allocator);
            self.list = list;
            return list.back();
        }
        return self.list.?.reset();
    }

    pub fn push(self: *PendingStateStorage) error{OutOfMemory}!*StateInfo {
        return self.list.?.push();
    }

    pub fn hasStates(self: *const PendingStateStorage) bool {
        return self.list != null and self.list.?.hasStates();
    }

    /// MOVE the owned StateList out: returns it and
    /// nulls the wrapper so a later destroy() frees nothing. The caller (the pool's
    /// setupStates slot) becomes the owner.
    pub fn moveOut(self: *PendingStateStorage) ?*StateList {
        const l = self.list;
        self.list = null;
        return l;
    }
};

/// Free a StateList by pointer (the pool's setupStates owner at teardown / before re-adopt).
pub fn destroyStateList(allocator: std.mem.Allocator, list: *StateList) void {
    list.deinit();
    allocator.destroy(list);
}

// Typed wrappers over PendingStateStorage for the engine/thread setup paths: the
// handle is `*PendingStateStorage` end-to-end now -- the engine side-table and the thread
// scratch both hold the concrete type, and only the runtime_hooks adopt boundary coerces it
// to *anyopaque (implicitly). No cast survives here.
pub fn storageCreate() ?*PendingStateStorage {
    return PendingStateStorage.create(std.heap.c_allocator) catch null;
}
pub fn storageDestroy(storage: ?*PendingStateStorage) void {
    if (storage) |s| s.destroy();
}
// The StateList is legitimately growable (bounded by UCI
// game-move input, not max_ply), so OOM here propagates as error rather than panicking -- the
// callers are on error-capable paths (buildRootMoves is !void; traceEvalEngine returns optional).
pub fn storageReset(storage: *PendingStateStorage) error{OutOfMemory}!*StateInfo {
    return storage.reset();
}
pub fn storagePush(storage: *PendingStateStorage) error{OutOfMemory}!*StateInfo {
    return storage.push();
}
pub fn storageHasStates(storage: *const PendingStateStorage) bool {
    return storage.hasStates();
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "PendingStateStorage builds a chain, moves it out leak-free, destroy frees nothing after move" {
    var storage = try PendingStateStorage.create(testing.allocator);
    // build a 3-deep chain (root + 2 moves), like position setup
    _ = try storage.reset();
    _ = try storage.push();
    _ = try storage.push();
    try testing.expect(storage.hasStates());

    // adopt: move the list out to a "pool" owner; the wrapper is now empty
    const adopted = storage.moveOut().?;
    try testing.expect(storage.list == null);
    try testing.expect(!storage.hasStates());
    try testing.expectEqual(@as(usize, 3), adopted.len());

    // storage destroy frees nothing (already moved out) — no double free
    storage.destroy();
    // the pool owner frees the adopted list
    destroyStateList(testing.allocator, adopted);
}

test "PendingStateStorage destroy frees its list when NOT moved out" {
    var storage = try PendingStateStorage.create(testing.allocator);
    _ = try storage.reset();
    _ = try storage.push();
    try testing.expect(storage.hasStates());
    storage.destroy(); // testing.allocator fails on leak → proves the unused chain is freed
}

test "PendingStateStorage reset after moveOut re-creates the list" {
    var storage = try PendingStateStorage.create(testing.allocator);
    const moved = storage.moveOut().?;
    destroyStateList(testing.allocator, moved);
    try testing.expect(storage.list == null);
    _ = try storage.reset(); // re-creates
    try testing.expect(storage.hasStates());
    try testing.expectEqual(@as(usize, 1), storage.list.?.len());
    storage.destroy();
}

test "StateList starts with one zeroed root, like deque<StateInfo>(1)" {
    var list = try StateList.init(testing.allocator);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.len());
    try testing.expect(list.hasStates());
    const root = list.back();
    for (std.mem.asBytes(root)) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "push grows and keeps earlier StateInfo addresses stable" {
    var list = try StateList.init(testing.allocator);
    defer list.deinit();

    const root = list.back();
    const p1 = try list.push();
    const p2 = try list.push();
    const p3 = try list.push();

    // distinct, ordered, and back() tracks the latest
    try testing.expect(root != p1 and p1 != p2 and p2 != p3);
    try testing.expectEqual(p3, list.back());
    try testing.expectEqual(@as(usize, 4), list.len());

    // pointer stability: the root and earlier pushes are unchanged after growth
    try testing.expectEqual(root, list.blocks.items[0]);
    try testing.expectEqual(p1, list.blocks.items[1]);

    // a value written into an early StateInfo survives later pushes
    std.mem.asBytes(p1)[0] = 0x5A;
    _ = try list.push();
    try testing.expectEqual(@as(u8, 0x5A), std.mem.asBytes(p1)[0]);
}

test "reset drops to a single fresh root and zeroes it" {
    var list = try StateList.init(testing.allocator);
    defer list.deinit();

    _ = try list.push();
    _ = try list.push();
    const back = list.back();
    std.mem.asBytes(back)[10] = 0xFF;
    try testing.expectEqual(@as(usize, 3), list.len());

    const root = try list.reset();
    try testing.expectEqual(@as(usize, 1), list.len());
    for (std.mem.asBytes(root)) |b| try testing.expectEqual(@as(u8, 0), b);
    try testing.expectEqual(root, list.back());
}

test "state_info_size matches the pinned C++ StateInfo footprint" {
    // state_info_size is pinned to 192 by graph_layout.zig.
    try testing.expectEqual(@as(usize, 192), state_info_size);
}

// Prove the allocation error paths actually unwind. std.testing
// .checkAllAllocationFailures runs the body once cleanly, then again failing each
// successive allocation in turn, and asserts every run either succeeds or returns
// error.OutOfMemory while leaking nothing -- so the errdefer/defer chains are
// verified on every partial-failure point, not just the happy path.
test "StateList.init/push/reset unwind leak-free on every allocation failure" {
    const Roundtrip = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var list = try StateList.init(allocator);
            defer list.deinit();
            _ = try list.push();
            _ = try list.push();
            _ = try list.reset();
            _ = try list.push();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Roundtrip.run, .{});
}

test "PendingStateStorage.create/reset/push unwind leak-free on every allocation failure" {
    // create() has a 3-deep errdefer chain (self -> list -> StateList.init); a failure
    // at any step must free the earlier ones, and a later reset/push failure must leave
    // destroy() with a consistent chain to free.
    const Roundtrip = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const storage = try PendingStateStorage.create(allocator);
            defer storage.destroy();
            _ = try storage.reset();
            _ = try storage.push();
            _ = try storage.push();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Roundtrip.run, .{});
}
