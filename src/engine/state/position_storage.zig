// Own the engine's `pos` member's storage. The Position ALGORITHMS live in
// board/position.zig; this provides OWNERSHIP of the Position object the engine holds
// by value. Serve as that storage: one aligned, zeroed block the runtime hands to the
// position ops as the live Position.
//
// Treat as opaque bytes (Position internals are written/read by position.zig), but size
// and align the block from `position_types.Position` itself rather than a pinned
// literal: a hand-pinned width is silently wrong the moment the type grows, and this
// block is handed out as a whole Position.

const std = @import("std");
const position_types = @import("position_types");

/// Take the block's footprint from the type it stores, so the two cannot diverge.
pub const position_size: usize = @sizeOf(position_types.Position);
pub const position_align: usize = @alignOf(position_types.Position);

pub const PositionStorage = struct {
    bytes: [position_size]u8 align(position_align),

    /// Return a fresh, zeroed Position block (matches the value-initialized `pos`
    /// member before pos.set(StartFEN) runs).
    pub fn zeroed() PositionStorage {
        return .{ .bytes = @splat(0) };
    }

    /// Return the address of the Position object, handed to the position ops.
    pub fn ptr(self: *PositionStorage) *anyopaque {
        return @ptrCast(&self.bytes);
    }
};

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "PositionStorage is a zeroed Position-sized block at its base address" {
    var pos = PositionStorage.zeroed();
    // Assert against the type, not a literal: the block must hold a whole Position.
    try testing.expectEqual(@sizeOf(position_types.Position), @sizeOf([position_size]u8));
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&pos.bytes)), pos.ptr());
    for (pos.bytes) |b| try testing.expectEqual(@as(u8, 0), b);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(pos.ptr()) % position_align);
}
