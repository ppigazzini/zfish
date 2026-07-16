// Provide engine string/format helpers + shared POD types.
//
// Build pure C-string alloc + ArrayList append helpers and the small shared value
// types (ByteView, CountPair) used across engine.zig's info-formatting, trace, and
// setup clusters. Split into a base leaf so those clusters can move into their own
// modules without duplicating the helpers. Depend only on std; nothing in
// the engine graph, so no cycle. engine.zig re-exports ByteView (its external port
// surface) and aliases the rest.

const std = @import("std");

pub const ByteView = struct {
    ptr: ?[*]const u8,
    len: usize,
};

pub const CountPair = struct {
    current: usize,
    total: usize,
};

pub fn allocMessage(comptime fmt: []const u8, args: anytype) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const rendered = std.fmt.allocPrint(allocator, fmt, args) catch return null;
    defer allocator.free(rendered);
    const owned = allocator.allocSentinel(u8, rendered.len, 0) catch return null;
    @memcpy(owned[0..rendered.len], rendered);
    return owned.ptr;
}

pub fn appendFormat(buffer: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const allocator = std.heap.c_allocator;
    const rendered = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(rendered);
    try buffer.appendSlice(allocator, rendered);
}

pub fn appendHexKey(buffer: *std.ArrayList(u8), key: u64) !void {
    // Match C `%016llX` byte-for-byte with `{X:0>16}` (uppercase hex, zero-padded to 16).
    var numeric: [32]u8 = undefined;
    const rendered = std.fmt.bufPrint(&numeric, "{X:0>16}", .{key}) catch unreachable;
    try buffer.appendSlice(std.heap.c_allocator, rendered);
}

pub fn appendPaddedInt(buffer: *std.ArrayList(u8), value: c_int) !void {
    // Emulate C `%4d` = space-pad the decimal to width 4, right-aligned. std.fmt emits a `+`
    // when a width is applied directly to a signed int (`{d:4}` -> "+5"), so render the
    // digits first, then pad the *string* -- string padding carries no sign semantics.
    var digits: [16]u8 = undefined;
    const body = std.fmt.bufPrint(&digits, "{d}", .{value}) catch unreachable;
    var numeric: [32]u8 = undefined;
    const rendered = std.fmt.bufPrint(&numeric, "{s: >4}", .{body}) catch unreachable;
    try buffer.appendSlice(std.heap.c_allocator, rendered);
}

pub fn appendCheckers(buffer: *std.ArrayList(u8), checkers: u64) !void {
    var remaining = checkers;
    while (remaining != 0) {
        const square: usize = @intCast(@ctz(remaining));
        remaining &= remaining - 1;

        const square_text = [_]u8{
            @as(u8, 'a') + @as(u8, @intCast(square % 8)),
            @as(u8, '1') + @as(u8, @intCast(square / 8)),
        };
        try buffer.appendSlice(std.heap.c_allocator, &square_text);
        try buffer.append(std.heap.c_allocator, ' ');
    }
}

// --- tests--------------------------------------------------------------
// Pin the byte-exactness of the formatters that replaced C snprintf
// (%016llX / %4d) -- a regression here would drift the eval-trace goldens.
const ally = std.heap.c_allocator;

test "appendHexKey: 16-digit uppercase zero-padded (== C %016llX)" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(ally);
    try appendHexKey(&buf, 0xDEADBEEF);
    try std.testing.expectEqualStrings("00000000DEADBEEF", buf.items);
    buf.clearRetainingCapacity();
    try appendHexKey(&buf, 0xFFFFFFFFFFFFFFFF);
    try std.testing.expectEqualStrings("FFFFFFFFFFFFFFFF", buf.items);
}

test "appendPaddedInt: width-4 right-aligned, no forced sign (== C %4d)" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(ally);
    try appendPaddedInt(&buf, 5);
    try std.testing.expectEqualStrings("   5", buf.items);
    buf.clearRetainingCapacity();
    try appendPaddedInt(&buf, -5);
    try std.testing.expectEqualStrings("  -5", buf.items);
    buf.clearRetainingCapacity();
    try appendPaddedInt(&buf, 12345); // overflows the field, not truncated
    try std.testing.expectEqualStrings("12345", buf.items);
}

test "appendCheckers: renders occupied squares as algebraic + space" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(ally);
    // a1 (bit 0) and h8 (bit 63)
    try appendCheckers(&buf, (@as(u64, 1) << 0) | (@as(u64, 1) << 63));
    try std.testing.expectEqualStrings("a1 h8 ", buf.items);
}
