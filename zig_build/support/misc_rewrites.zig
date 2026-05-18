const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

pub fn hashBytes(data: []const u8) u64 {
    const m: u64 = 0xc6a4a7935bd1e995;
    const r: u6 = 47;

    var hash: u64 = @as(u64, data.len) *% m;
    const aligned_end = data.len & ~@as(usize, 7);

    var index: usize = 0;
    while (index < aligned_end) : (index += 8) {
        var k = std.mem.readInt(u64, data[index..][0..8], .little);
        k *%= m;
        k ^= k >> r;
        k *%= m;

        hash ^= k;
        hash *%= m;
    }

    if ((data.len & 7) != 0) {
        var k: u64 = 0;
        var tail_index = data.len & 7;
        while (tail_index != 0) {
            tail_index -= 1;
            k = (k << 8) | data[aligned_end + tail_index];
        }
        hash ^= k;
        hash *%= m;
    }

    hash ^= hash >> r;
    hash *%= m;
    hash ^= hash >> r;

    return hash;
}

pub fn strToSizeT(input: []const u8) usize {
    var index: usize = 0;
    while (index < input.len and isSpaceByte(input[index])) : (index += 1) {}

    if (index < input.len and input[index] == '+') {
        index += 1;
    }

    const digits_start = index;
    var value: u64 = 0;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (byte < '0' or byte > '9') {
            break;
        }

        const digit = @as(u64, byte - '0');
        const multiplied = @mulWithOverflow(value, @as(u64, 10));
        if (multiplied[1] != 0) {
            c.exit(c.EXIT_FAILURE);
        }

        const next_value = @addWithOverflow(multiplied[0], digit);
        if (next_value[1] != 0) {
            c.exit(c.EXIT_FAILURE);
        }

        value = next_value[0];
    }

    if (digits_start == index) {
        c.exit(c.EXIT_FAILURE);
    }

    if (value > std.math.maxInt(usize)) {
        c.exit(c.EXIT_FAILURE);
    }
    return @intCast(value);
}

pub fn readFileToString(path: []const u8) ?[*:0]u8 {
    return readFileToStringAlloc(path) catch null;
}

pub fn removeWhitespace(input: []const u8) ?[*:0]u8 {
    return removeWhitespaceAlloc(input) catch null;
}

pub fn isWhitespace(input: []const u8) bool {
    for (input) |byte| {
        if (!isSpaceByte(byte)) {
            return false;
        }
    }
    return true;
}

pub fn getBinaryDirectory(argv0: []const u8) ?[*:0]u8 {
    return getBinaryDirectoryAlloc(argv0) catch null;
}

pub fn getWorkingDirectory() ?[*:0]u8 {
    return getWorkingDirectoryAlloc() catch null;
}

fn readFileToStringAlloc(path: []const u8) ![*:0]u8 {
    const allocator = std.heap.c_allocator;
    const contents = try readFileAlloc(allocator, path);
    defer allocator.free(contents);
    return try allocCString(contents);
}

fn removeWhitespaceAlloc(input: []const u8) ![*:0]u8 {
    const allocator = std.heap.c_allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    for (input) |byte| {
        if (!isSpaceByte(byte)) {
            try buffer.append(allocator, byte);
        }
    }

    return try allocCString(buffer.items);
}

fn getBinaryDirectoryAlloc(argv0: []const u8) ![*:0]u8 {
    const allocator = std.heap.c_allocator;
    const path_separator = "/";
    const working_directory = try takeOwnedString(try getWorkingDirectoryAlloc());
    defer allocator.free(working_directory);

    var binary_directory = std.ArrayList(u8).empty;
    defer binary_directory.deinit(allocator);
    try binary_directory.appendSlice(allocator, argv0);

    const separator_index = std.mem.lastIndexOfAny(u8, binary_directory.items, "\\/");
    if (separator_index) |index| {
        binary_directory.shrinkRetainingCapacity(index + 1);
    } else {
        binary_directory.clearRetainingCapacity();
        try binary_directory.appendSlice(allocator, ".");
        try binary_directory.appendSlice(allocator, path_separator);
    }

    if (std.mem.startsWith(u8, binary_directory.items, "." ++ path_separator)) {
        var resolved = std.ArrayList(u8).empty;
        defer resolved.deinit(allocator);
        try resolved.appendSlice(allocator, working_directory);
        try resolved.appendSlice(allocator, binary_directory.items[1..]);
        return try allocCString(resolved.items);
    }

    return try allocCString(binary_directory.items);
}

fn getWorkingDirectoryAlloc() ![*:0]u8 {
    var buffer: [40000]u8 = undefined;
    const cwd = c.getcwd(@ptrCast(&buffer), buffer.len);
    if (cwd == null) {
        return try allocCString("");
    }

    const length = std.mem.indexOfScalar(u8, &buffer, 0) orelse buffer.len;
    return try allocCString(buffer[0..length]);
}

fn allocCString(value: []const u8) ![*:0]u8 {
    const allocator = std.heap.c_allocator;
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result[0..value.len], value);
    return result.ptr;
}

fn takeOwnedString(pointer: [*:0]u8) ![]u8 {
    const slice = std.mem.span(pointer);
    const allocator = std.heap.c_allocator;
    const owned = try allocator.alloc(u8, slice.len);
    @memcpy(owned, slice);
    c.free(@ptrCast(pointer));
    return owned;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const c_path = try allocCString(path);
    defer c.free(@ptrCast(c_path));

    const file = c.fopen(c_path, "rb") orelse return error.FileOpenFailed;
    defer _ = c.fclose(file);

    if (c.fseek(file, 0, c.SEEK_END) != 0) {
        return error.FileOpenFailed;
    }

    const file_size = c.ftell(file);
    if (file_size < 0) {
        return error.FileOpenFailed;
    }

    if (c.fseek(file, 0, c.SEEK_SET) != 0) {
        return error.FileOpenFailed;
    }

    const buffer = try allocator.alloc(u8, @intCast(file_size));
    errdefer allocator.free(buffer);

    const bytes_read = c.fread(buffer.ptr, 1, buffer.len, file);
    if (bytes_read != buffer.len and c.ferror(file) != 0) {
        return error.FileOpenFailed;
    }

    return buffer;
}

fn isSpaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}
