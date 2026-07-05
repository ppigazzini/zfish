// Native UCI output primitive + log-file sink (M16.7, relocated from main.zig).
//
// A leaf module (libc + builtin only) so any layer can print without a cycle: the
// coordinated line writer tees stdout to an optional log file, replacing the C++
// sync_cout wrapper. `printLine` is the single output funnel; `startLogger`
// opens/closes the log destination.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("libc");

// C stdio stdout, obtained portably. @cImport's translation of the stdout macro is
// not uniform across the owned OSes -- a comptime-uncallable __acrt_iob_func() on
// Windows, an inline getter on macOS -- so the underlying entry points are declared
// directly: glibc's global FILE* symbol, macOS's __stdoutp global, or the Windows
// CRT __acrt_iob_func(n) accessor. Each arm is comptime-selected.
const std_streams = struct {
    extern "c" fn __acrt_iob_func(index: c_uint) callconv(.c) *c.FILE;
    extern "c" var __stdoutp: *c.FILE;
    extern "c" var stdout: *c.FILE;
};

fn cStdout() *c.FILE {
    return switch (builtin.os.tag) {
        .windows => std_streams.__acrt_iob_func(1),
        .macos, .ios, .tvos, .watchos, .visionos => std_streams.__stdoutp,
        else => std_streams.stdout,
    };
}

var log_file: ?*c.FILE = null;

// Latest whole-search node count, published by the search-driver info emit and read
// by the uci layer's `nodes` accessor. A shared leaf home so both sides reach it
// without a cycle (M16.7).
var last_nodes_searched = std.atomic.Value(u64).init(0);
pub fn setLastNodesSearched(nodes: u64) void {
    last_nodes_searched.store(nodes, .monotonic);
}
pub fn lastNodesSearched() u64 {
    return last_nodes_searched.load(.monotonic);
}
pub fn resetLastNodesSearched() void {
    last_nodes_searched.store(0, .monotonic);
}

// Quiet mode (bench/speedtest): the search-driver emit functions are no-ops. Set by
// the uci listener-mode command, read by the emit path.
var quiet_mode: bool = false;
pub fn setQuietMode(quiet: bool) void {
    quiet_mode = quiet;
}
pub fn isQuiet() bool {
    return quiet_mode;
}

// Write one line to stdout (and, if open, tee it to the log file), flushing both.
pub fn printLine(str: [*]const u8, len: usize) void {
    const out = cStdout();
    _ = c.fwrite(str, 1, len, out);
    _ = c.fputc('\n', out);
    _ = c.fflush(out);
    if (log_file) |f| {
        _ = c.fwrite(str, 1, len, f);
        _ = c.fputc('\n', f);
        _ = c.fflush(f);
    }
}

// Open/close the log destination (printLine tees output to it). An empty name
// closes any current log; a non-empty name (re)opens for writing.
pub fn startLogger(name_ptr: [*]const u8, name_len: usize) void {
    if (log_file) |f| {
        _ = c.fclose(f);
        log_file = null;
    }
    if (name_len == 0 or name_len >= 4095) return;
    var buf: [4096]u8 = undefined;
    @memcpy(buf[0..name_len], name_ptr[0..name_len]);
    buf[name_len] = 0;
    log_file = c.fopen(@ptrCast(&buf), "w");
}
