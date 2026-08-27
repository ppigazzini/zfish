//! Convert a path the OS handed us into the WTF-8 the file APIs take.
//!
//! Own upstream's `path_from_utf8` (misc.cpp). On POSIX a path is bytes and there is nothing
//! to convert. On Windows a path is UTF-16, and Zig's file APIs reach it by transcoding the
//! WTF-8 they are given -- so a byte sequence that is not valid WTF-8 is refused with
//! `error.BadPathName` before any file is opened.
//!
//! That refusal is the defect. An old GUI (Arena is the reported one) hands the engine an
//! ANSI path in the system code page, which is not UTF-8 the moment it holds an accented
//! character, and the engine then reports the net as missing on a path that exists.
//!
//! Declare `MultiByteToWideChar` directly rather than through @cImport, the way clock.zig
//! declares the performance counters: windows.h does not cross-compile.
const std = @import("std");
const builtin = @import("builtin");

const cp_acp: u32 = 0; // CP_ACP -- the system's ANSI code page.

extern "kernel32" fn MultiByteToWideChar(
    code_page: u32,
    flags: u32,
    multi_byte_str: [*]const u8,
    multi_byte_len: i32,
    wide_char_str: ?[*]u16,
    wide_char_len: i32,
) callconv(.winapi) i32;

/// Return `path` as WTF-8, allocated with `gpa` -- the caller frees it.
///
/// Try the path as it stands first: on POSIX that is always the answer, and on Windows a
/// modern GUI already sends UTF-8. Only a path that fails WTF-8 validation takes the ANSI
/// code page, and only on Windows. A conversion that fails hands the original bytes back,
/// which fails downstream exactly the way it did before -- never worse.
pub fn toWtf8Alloc(gpa: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]u8 {
    if (builtin.os.tag != .windows or path.len == 0 or std.unicode.wtf8ValidateSlice(path))
        return gpa.dupe(u8, path);

    const len: i32 = std.math.cast(i32, path.len) orelse return gpa.dupe(u8, path);
    const wide_len = MultiByteToWideChar(cp_acp, 0, path.ptr, len, null, 0);
    if (wide_len <= 0) return gpa.dupe(u8, path);

    const wide = try gpa.alloc(u16, @intCast(wide_len));
    defer gpa.free(wide);
    if (MultiByteToWideChar(cp_acp, 0, path.ptr, len, wide.ptr, wide_len) != wide_len)
        return gpa.dupe(u8, path);

    return std.unicode.wtf16LeToWtf8Alloc(gpa, wide) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
    };
}

test "a valid path is returned unchanged" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "", "nn-1a298aa575a0.nnue", "/opt/net/nn.nnue", "C:\\Nets\\né.nnue" }) |path| {
        const out = try toWtf8Alloc(gpa, path);
        defer gpa.free(out);
        try std.testing.expectEqualStrings(path, out);
    }
}

test "an invalid sequence survives the round trip off Windows" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    // 0xE9 is 'e-acute' in CP-1252 and an invalid lead byte in UTF-8. Off Windows a path is
    // bytes, so it must pass through untouched -- converting it would break a legal filename.
    const ansi = "net\xE9.nnue";
    try std.testing.expect(!std.unicode.wtf8ValidateSlice(ansi));
    const out = try toWtf8Alloc(gpa, ansi);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(ansi, out);
}

test {
    std.testing.refAllDecls(@This());
}
