// PositionStorage — the owner of the engine's `pos` member's
// storage. The Position ALGORITHMS live in board/position.zig (which operates
// on a Position by offset); this provides OWNERSHIP of the 1032-byte
// Position object the engine holds by value. This is that storage: one aligned,
// zeroed block the runtime hands to the position ops as the live Position.
//
// Treated as opaque bytes (Position internals are written/read by position.zig).
//
// ALIGNMENT NOTE: sizeof(Position) == 1032 is pinned by graph_layout.zig.
// alignof(Position) is not separately probed; 8 covers its u64/pointer members. If
// a future upstream Position gains an over-aligned (SIMD) member, the layout
// verifier must bump this — flagged there, harmless until then.

const std = @import("std");

/// sizeof(Position), pinned by graph_layout.zig (= 1032).
pub const position_size: usize = 1032;
pub const position_align: usize = 8;

pub const PositionStorage = struct {
    bytes: [position_size]u8 align(position_align),

    /// A fresh, zeroed Position block (matches the value-initialized `pos`
    /// member before pos.set(StartFEN) runs).
    pub fn zeroed() PositionStorage {
        return .{ .bytes = [_]u8{0} ** position_size };
    }

    /// Address of the Position object, handed to the position ops.
    pub fn ptr(self: *PositionStorage) *anyopaque {
        return @ptrCast(&self.bytes);
    }
};

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "PositionStorage is a zeroed 1032-byte block at its base address" {
    var pos = PositionStorage.zeroed();
    try testing.expectEqual(@as(usize, 1032), @sizeOf([position_size]u8));
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&pos.bytes)), pos.ptr());
    for (pos.bytes) |b| try testing.expectEqual(@as(u8, 0), b);
    // 8-byte aligned base (Position holds u64/pointer members)
    try testing.expectEqual(@as(usize, 0), @intFromPtr(pos.ptr()) % position_align);
}
