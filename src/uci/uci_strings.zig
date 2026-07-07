// UCI C-string helpers (M17.3u).
//
// The std-only C-string alloc / format / trim primitives shared across uci.zig's
// formatter, parser, dispatch, and runtime clusters. Split into a base leaf so
// those clusters can move into their own modules (uci_format / uci_parse / ...)
// without duplicating these helpers. Depends only on std; uci.zig and the leaves
// import it and alias the names so their bodies stay unqualified.

const std = @import("std");

pub fn appendFormatted(buffer: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const allocator = std.heap.c_allocator;
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try buffer.appendSlice(allocator, formatted);
}

pub fn allocFormatted(comptime fmt: []const u8, args: anytype) !?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    return try allocCString(formatted);
}

pub fn allocCString(value: []const u8) !?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result[0..value.len], value);
    return result.ptr;
}

pub fn freeMaybeCString(value: ?[*:0]u8) void {
    if (value) |ptr|
        std.heap.c_allocator.free(std.mem.span(ptr));
}

pub fn trimAsciiWhitespace(input: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = input.len;
    while (start < end and isSpaceByte(input[start])) : (start += 1) {}
    while (end > start and isSpaceByte(input[end - 1])) {
        end -= 1;
    }
    return input[start..end];
}

pub fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

pub fn isSpaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}
