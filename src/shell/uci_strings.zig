// Provide the UCI string helpers.
//
// Share the std-only alloc / format / trim primitives across uci.zig's formatter,
// parser, dispatch, and runtime clusters. Split into a base leaf so those clusters can
// move into their own modules (uci_format / uci_parse / ...) without duplicating these
// helpers. Depend only on std; uci.zig and the leaves import it and alias the names so
// their bodies stay unqualified.
//
// Every producer here returns an owned SLICE. A rendered string has a length the
// renderer already knows, so handing back a bare sentinel pointer throws it away and
// forces every consumer to walk the bytes again to get it back.

const std = @import("std");

pub fn appendFormatted(
    gpa: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try buffer.print(gpa, fmt, args);
}

/// Render `fmt` into a fresh owned slice.
pub fn allocFormatted(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(gpa, fmt, args);
}

/// Free an optional owned slice, for the `orelse return null` producers below.
pub fn freeMaybe(gpa: std.mem.Allocator, value: ?[]u8) void {
    if (value) |slice| gpa.free(slice);
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

// --- tests--------------------------------------------------------------
test "trimAsciiWhitespace strips leading/trailing ws, preserves interior" {
    try std.testing.expectEqualStrings("hi", trimAsciiWhitespace("  \t hi \n "));
    try std.testing.expectEqualStrings("", trimAsciiWhitespace("   \t\r\n"));
    try std.testing.expectEqualStrings("a b", trimAsciiWhitespace("a b"));
    try std.testing.expectEqualStrings("x", trimAsciiWhitespace("x"));
}

test "asciiLower / isSpaceByte" {
    try std.testing.expectEqual(@as(u8, 'a'), asciiLower('A'));
    try std.testing.expectEqual(@as(u8, 'z'), asciiLower('Z'));
    try std.testing.expectEqual(@as(u8, '5'), asciiLower('5')); // keep non-alpha unchanged
    try std.testing.expect(isSpaceByte(' ') and isSpaceByte('\t') and isSpaceByte('\n') and isSpaceByte('\r'));
    try std.testing.expect(!isSpaceByte('x') and !isSpaceByte('0'));
}

test "allocFormatted renders into an owned slice with a known length" {
    const gpa = std.testing.allocator;
    const s = try allocFormatted(gpa, "a{d}c", .{7});
    defer gpa.free(s);
    try std.testing.expectEqualStrings("a7c", s);
}

test "freeMaybe accepts null and frees a slice" {
    const gpa = std.testing.allocator;
    freeMaybe(gpa, null);
    freeMaybe(gpa, try gpa.dupe(u8, "owned"));
}
