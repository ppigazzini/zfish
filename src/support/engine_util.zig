// Engine string/format helpers + shared POD types (M17.3x).
//
// The pure C-string alloc + ArrayList append builders and the small shared value
// types (ByteView, CountPair) used across engine.zig's info-formatting, trace, and
// setup clusters. Split into a base leaf so those clusters can move into their own
// modules without duplicating the helpers. Depends only on std + libc; nothing in
// the engine graph, so no cycle. engine.zig re-exports ByteView (its external port
// surface) and aliases the rest.

const std = @import("std");
const c = @import("libc");

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
    var numeric: [32]u8 = undefined;
    const len = c.snprintf(&numeric, numeric.len, "%016llX", @as(c_ulonglong, key));
    try buffer.appendSlice(std.heap.c_allocator, numeric[0..@intCast(len)]);
}

pub fn appendPaddedInt(buffer: *std.ArrayList(u8), value: c_int) !void {
    var numeric: [32]u8 = undefined;
    const len = c.snprintf(&numeric, numeric.len, "%4d", value);
    try buffer.appendSlice(std.heap.c_allocator, numeric[0..@intCast(len)]);
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
