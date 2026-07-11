// Native UCI output primitive + log-file sink.
//
// A leaf module (std only) so any layer can print without a cycle: the coordinated
// line writer tees stdout to an optional log file, replacing the C++ sync_cout
// wrapper. `printLine` is the single output funnel; `startLogger` opens/closes the
// log destination.
//
// Output goes through std.Io, not libc stdio. The handle is
// `std.Io.Threaded.init_single_threaded` -- a BLOCKING handle that spawns no threads
// and installs no signal handlers (`have_signal_handler = false`), the same
// lightweight handle the net-file read uses, so the output path never interacts with
// the engine's own native threadpool. A `std.Io.Mutex` serialises `printLine` so the
// search info emitter and the UCI listener can never tear a line -- stronger than the
// old per-glibc-stream lock, which took a separate lock for each fwrite/fputc/fflush
// and could interleave a line with its newline.

const std = @import("std");
const builtin = @import("builtin");

// Blocking std.Io handle shared by every write. Concurrent blocking writes through one
// shared handle are safe (each is just a write syscall); the mutex below is what keeps
// whole lines intact. Proven under an 8-thread stress in the test at the bottom.
var io_threaded = std.Io.Threaded.init_single_threaded;
fn io() std.Io {
    return io_threaded.io();
}

// The stdout sink. A module-level var so the concurrency test can redirect it to a
// capture file; in production it is the process stdout. When a log file is open,
// printLine tees each line to it as well.
var out_file: std.Io.File = std.Io.File.stdout();
var log_file: ?std.Io.File = null;
var write_mutex: std.Io.Mutex = .init;

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

// Write `line` then a newline to `file`. Both writes happen while the caller holds
// write_mutex, so no other printLine can interleave between them -- the line stays
// whole even though it is two syscalls. writeStreamingAll issues the write(2) directly
// (no userspace buffer), so each line reaches the GUI immediately, as the old per-line
// fflush did. A write error (e.g. closed stdout) is ignored, matching the old code.
fn writeLineLocked(the_io: std.Io, file: std.Io.File, line: []const u8) void {
    file.writeStreamingAll(the_io, line) catch {};
    file.writeStreamingAll(the_io, "\n") catch {};
}

// Write one line to stdout (and, if open, tee it to the log file).
pub fn printLine(str: [*]const u8, len: usize) void {
    const the_io = io();
    write_mutex.lockUncancelable(the_io);
    defer write_mutex.unlock(the_io);
    writeLineLocked(the_io, out_file, str[0..len]);
    if (log_file) |f| writeLineLocked(the_io, f, str[0..len]);
}

// Open/close the log destination (printLine tees output to it). An empty name
// closes any current log; a non-empty name (re)opens for writing. Guarded by the
// same mutex as printLine so a concurrent emit never sees a half-swapped log_file.
pub fn startLogger(name_ptr: [*]const u8, name_len: usize) void {
    const the_io = io();
    write_mutex.lockUncancelable(the_io);
    defer write_mutex.unlock(the_io);
    if (log_file) |f| {
        f.close(the_io);
        log_file = null;
    }
    if (name_len == 0 or name_len >= 4095) return;
    log_file = std.Io.Dir.cwd().createFile(the_io, name_ptr[0..name_len], .{}) catch null;
}

// Property: with many threads hammering printLine, every line lands whole -- the mutex
// makes the line+newline pair atomic, so the capture file contains exactly N*M copies
// of the line and nothing torn. Removing the lock in printLine makes this fail (the two
// writeStreamingAll calls interleave across threads), which is what proves the gate real.
test "printLine: concurrent callers never tear a line" {
    const line = "info depth 12 score cp 34 pv e2e4 e7e5 g1f3";
    const threads_n = 8;
    const per_thread = 400;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cap = try tmp.dir.createFile(std.testing.io, "cap.txt", .{ .read = true });

    const saved = out_file;
    out_file = cap;
    defer out_file = saved;

    const Worker = struct {
        fn run(l: []const u8, n: usize) void {
            var i: usize = 0;
            while (i < n) : (i += 1) printLine(l.ptr, l.len);
        }
    };
    var pool: [threads_n]std.Thread = undefined;
    for (&pool) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ line, per_thread });
    for (&pool) |t| t.join();
    cap.close(std.testing.io);
    out_file = saved;

    const data = try tmp.dir.readFileAlloc(std.testing.io, "cap.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(data);

    var seen: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        if (raw.len == 0) continue; // trailing newline yields one empty tail
        try std.testing.expectEqualStrings(line, raw); // a torn line fails here
        seen += 1;
    }
    try std.testing.expectEqual(threads_n * per_thread, seen);
}
