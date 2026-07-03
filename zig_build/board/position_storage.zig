// Native PositionStorage — the post-src/ owner of the engine's `pos` member's
// storage. The Position ALGORITHMS are already native (board/position.zig operates
// on a Position by offset); what the cut still needs is native OWNERSHIP of the
// 1032-byte Position object the C++ Engine holds by value (today `new Position()`
// in the bridge). This is that storage: one aligned, zeroed block the native runtime
// hands to the position ops as the live Position.
//
// Treated as opaque bytes (Position internals are written/read by position.zig).
// Native-graph cut iteration 5 (REPORT-09 Annex B, ITERATION-157); ready-to-wire.
//
// ALIGNMENT NOTE: sizeof(Position) == 1032 is pinned by graph_layout.zig against the
// C++ build (zfish_graph_layout_size(8)). alignof(Position) is not separately
// probed; 8 covers its u64/pointer members. If a future upstream Position gains an
// over-aligned (SIMD) member, the flip's layout verifier must bump this — flagged
// there, harmless until then.

const std = @import("std");

/// sizeof(Stockfish::Position), pinned by graph_layout.zig (= 1032).
pub const position_size: usize = 1032;
pub const position_align: usize = 8;

pub const PositionStorage = struct {
    bytes: [position_size]u8 align(position_align),

    /// A fresh, zeroed Position block (matches the value-initialized C++ `pos`
    /// member before pos.set(StartFEN) runs).
    pub fn zeroed() PositionStorage {
        return .{ .bytes = [_]u8{0} ** position_size };
    }

    /// Address of the Position object, handed to the native position ops.
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
