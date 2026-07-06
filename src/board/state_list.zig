// Native StateList — the engine `states` member (modeling StateListPtr =
// std::unique_ptr<std::deque<StateInfo>>), holding the chain of StateInfo records
// that back a position and its applied moves.
//
// CONTRACT (models a std::deque<StateInfo>):
//   - starts non-empty (one root StateInfo), like `new std::deque<StateInfo>(1)`;
//   - reset()  -> drops to a single fresh root and returns its address;
//   - push()   -> appends one StateInfo and returns its address;
//   - back()   -> address of the most recently added StateInfo;
//   - POINTER STABILITY is mandatory: Position::do_move writes into the latest
//     StateInfo while earlier ones remain referenced by the search, so a record's
//     address must never change once handed out. std::deque guarantees this by
//     chunking; here every StateInfo is its own heap allocation, which is strictly
//     pointer-stable and keeps the type free of any libstdc++ ABI dependency.
//
// StateInfo is treated as an opaque 192-byte POD block (graph_layout.state_info_size);
// the native runtime memsets/fills it via Position, so this module owns lifetime +
// ordering only, not StateInfo's internals.

const std = @import("std");

/// sizeof(Stockfish::StateInfo). Pinned by graph_layout.zig (state_info_size = 192).
pub const state_info_size: usize = 192;
pub const state_info_align: usize = 8;

/// One StateInfo record. 8-byte aligned (C++ StateInfo has 8-byte members);
/// treated as opaque bytes here — Position fills the internals.
const StateInfo = struct {
    bytes: [state_info_size]u8 align(state_info_align),
};

pub const StateList = struct {
    allocator: std.mem.Allocator,
    /// One heap block per StateInfo → addresses are stable for the block's lifetime.
    blocks: std.ArrayListUnmanaged(*StateInfo),

    /// Construct with a single zeroed root StateInfo, matching
    /// `new std::deque<StateInfo>(1)`.
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
        @memset(&block.bytes, 0);
        try self.blocks.append(self.allocator, block);
        return block;
    }

    /// Drop to a single fresh root StateInfo and return its address. Mirrors
    /// `storage.states = StateListPtr(new std::deque<StateInfo>(1))`.
    pub fn reset(self: *StateList) error{OutOfMemory}!*anyopaque {
        // Reuse the first block (already allocated) and free the rest, so reset
        // cannot fail after the list exists.
        for (self.blocks.items[1..]) |block| self.allocator.destroy(block);
        self.blocks.shrinkRetainingCapacity(1);
        @memset(&self.blocks.items[0].bytes, 0);
        return @ptrCast(self.blocks.items[0]);
    }

    /// Append one StateInfo and return its address. Mirrors `emplace_back` + `&back()`.
    pub fn push(self: *StateList) error{OutOfMemory}!*anyopaque {
        return @ptrCast(try self.appendBlock());
    }

    /// Address of the most recently added StateInfo (`&back()`).
    pub fn back(self: *StateList) *anyopaque {
        return @ptrCast(self.blocks.items[self.blocks.items.len - 1]);
    }

    /// Whether the list currently holds any StateInfo (models `states ? 1 : 0`;
    /// after a handoff the owning pointer is nulled).
    pub fn hasStates(self: *const StateList) bool {
        return self.blocks.items.len != 0;
    }

    pub fn len(self: *const StateList) usize {
        return self.blocks.items.len;
    }
};

// Owns a StateList and supports the std::unique_ptr MOVE semantics the setupStates
// adopt relies on: moveOut() hands the StateList to the pool and NULLS the wrapper, so a
// later destroy() frees nothing (mirroring `pool.setupStates = std::move(storage.states)`
// followed by storage destruction). The position-setup flow (engine.zig) builds the chain
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
    /// list if it was moved out (mirrors `storage.states = StateListPtr(new deque(1))`).
    pub fn reset(self: *PendingStateStorage) error{OutOfMemory}!*anyopaque {
        if (self.list == null) {
            const list = try self.allocator.create(StateList);
            errdefer self.allocator.destroy(list);
            list.* = try StateList.init(self.allocator);
            self.list = list;
            return list.back();
        }
        return self.list.?.reset();
    }

    pub fn push(self: *PendingStateStorage) error{OutOfMemory}!*anyopaque {
        return self.list.?.push();
    }

    pub fn hasStates(self: *const PendingStateStorage) bool {
        return self.list != null and self.list.?.hasStates();
    }

    /// MOVE the owned StateList out (mirrors std::move of the unique_ptr): returns it and
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

// Opaque-handle wrappers over PendingStateStorage for the engine/thread setup paths. The
// handle stays *anyopaque across the module boundary; the cast is confined here.
pub fn storageCreate() ?*anyopaque {
    return PendingStateStorage.create(std.heap.c_allocator) catch null;
}
pub fn storageDestroy(storage: ?*anyopaque) void {
    if (storage) |s| @as(*PendingStateStorage, @ptrCast(@alignCast(s))).destroy();
}
pub fn storageReset(storage: *anyopaque) *anyopaque {
    return @as(*PendingStateStorage, @ptrCast(@alignCast(storage))).reset() catch @panic("OOM: state reset");
}
pub fn storagePush(storage: *anyopaque) *anyopaque {
    return @as(*PendingStateStorage, @ptrCast(@alignCast(storage))).push() catch @panic("OOM: state push");
}
pub fn storageHasStates(storage: *const anyopaque) bool {
    return @as(*const PendingStateStorage, @ptrCast(@alignCast(storage))).hasStates();
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
    const root: *StateInfo = @ptrCast(@alignCast(list.back()));
    for (root.bytes) |b| try testing.expectEqual(@as(u8, 0), b);
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
    try testing.expectEqual(root, @as(*anyopaque, @ptrCast(list.blocks.items[0])));
    try testing.expectEqual(p1, @as(*anyopaque, @ptrCast(list.blocks.items[1])));

    // a value written into an early StateInfo survives later pushes
    const early: *StateInfo = @ptrCast(@alignCast(p1));
    early.bytes[0] = 0x5A;
    _ = try list.push();
    try testing.expectEqual(@as(u8, 0x5A), early.bytes[0]);
}

test "reset drops to a single fresh root and zeroes it" {
    var list = try StateList.init(testing.allocator);
    defer list.deinit();

    _ = try list.push();
    _ = try list.push();
    const back: *StateInfo = @ptrCast(@alignCast(list.back()));
    back.bytes[10] = 0xFF;
    try testing.expectEqual(@as(usize, 3), list.len());

    const root: *StateInfo = @ptrCast(@alignCast(try list.reset()));
    try testing.expectEqual(@as(usize, 1), list.len());
    for (root.bytes) |b| try testing.expectEqual(@as(u8, 0), b);
    try testing.expectEqual(@as(*anyopaque, @ptrCast(root)), list.back());
}

test "state_info_size matches the pinned C++ StateInfo footprint" {
    // state_info_size is pinned to 192 by graph_layout.zig.
    try testing.expectEqual(@as(usize, 192), state_info_size);
}
