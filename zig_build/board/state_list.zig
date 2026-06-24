// Native StateList — the post-src/ replacement for the C++ engine `states` member
// (StateListPtr = std::unique_ptr<std::deque<StateInfo>>), used to hold the chain
// of StateInfo records that back a position and its applied moves.
//
// CONTRACT (mirrors the C++ deque the bridge's ZfishPendingStateListStorage wraps):
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
// StateInfo is treated as an opaque 192-byte POD block (graph_layout.state_info_size
// / zfish_graph_layout_size(9)); the native runtime memsets/fills it via Position,
// so this module owns lifetime + ordering only, not StateInfo's internals.
//
// This is iteration 1 of the native-graph cut (REPORT-9 Annex B 7.3+). It is a
// ready-to-wire native type: the live runtime still uses the C++ storage until the
// atomic flip moves `states` (and the pool's setupStates it is std::move'd into)
// native together — wiring it alone is impossible while the pool is C++.

const std = @import("std");

/// sizeof(Stockfish::StateInfo). Pinned against the C++ build by
/// graph_layout.zig (state_info_size = 192, cross-checked by zfish_graph_layout_size).
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

    /// Whether the list currently holds any StateInfo (the C++ storage's
    /// `states ? 1 : 0` after a handoff nulls the unique_ptr).
    pub fn hasStates(self: *const StateList) bool {
        return self.blocks.items.len != 0;
    }

    pub fn len(self: *const StateList) usize {
        return self.blocks.items.len;
    }
};

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

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
    // Cross-checked at build time by graph_layout.zig against zfish_graph_layout_size(9).
    try testing.expectEqual(@as(usize, 192), state_info_size);
}
