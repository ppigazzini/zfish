// Provide the UCI output primitive + log-file sink.
//
// Keep a leaf module (std only) so any layer can print without a cycle: the coordinated
// line writer tees stdout to an optional log file. Treat `printLine` as the single
// output funnel; `startLogger` opens/closes the log destination.
//
// Route output through std.Io, not libc stdio. Use the handle
// `std.Io.Threaded.init_single_threaded` -- a BLOCKING handle that spawns no threads
// and installs no signal handlers (`have_signal_handler = false`), the same
// lightweight handle the net-file read uses, so the output path never interacts with
// the engine's own thread pool. Let a `std.Io.Mutex` serialise `printLine` so the
// search info emitter and the UCI listener can never tear a line -- stronger than the
// old per-glibc-stream lock, which took a separate lock for each fwrite/fputc/fflush
// and could interleave a line with its newline.

const std = @import("std");
const builtin = @import("builtin");

// Share one blocking std.Io handle across every write. Concurrent blocking writes through one
// shared handle are safe (each is just a write syscall); the mutex below is what keeps
// whole lines intact. Prove it under an 8-thread stress in the test at the bottom.
var io_threaded = std.Io.Threaded.init_single_threaded;
fn io() std.Io {
    return io_threaded.io();
}

// Hold the stdout sink. Treat `null` as the process stdout, resolved lazily on first use: on
// Windows `std.Io.File.stdout()` is a runtime PEB query (not comptime-evaluable), so it
// must NOT be a container-level comptime initializer -- an eager `= std.Io.File.stdout()`
// compiles on Linux/macOS (fd 1 is comptime) but breaks the Windows build. Keep a module-level
// var so the concurrency test can redirect it to a capture file. When a log file is open,
// printLine tees each line to it as well.
var out_file: ?std.Io.File = null;
var log_file: ?std.Io.File = null;
var write_mutex: std.Io.Mutex = .init;

// Resolve the stdout sink, caching the process stdout on first use. Only ever called
// while holding write_mutex, so the lazy set is race-free.
fn resolveOut() std.Io.File {
    if (out_file) |f| return f;
    const f = std.Io.File.stdout();
    out_file = f;
    return f;
}

// Hold the latest whole-search node count, published by the search-driver info emit and read
// by the uci layer's `nodes` accessor. Keep a shared leaf home so both sides reach it
// without a cycle.
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

// Track quiet mode (bench/speedtest): the search-driver emit functions are no-ops. Set it
// from the uci listener-mode command, read it from the emit path.
var quiet_mode: bool = false;
pub fn setQuietMode(quiet: bool) void {
    quiet_mode = quiet;
}
pub fn isQuiet() bool {
    return quiet_mode;
}

// Track the `bench` command's go loop: upstream's bench calls engine.go() directly, bypassing
// the interactive `go` handler's numa/thread `info string` emission (uci.cpp:261-284 vs 131-132),
// so those lines must NOT be re-emitted per bench position. Set around benchRuntime's loop.
var bench_go_active: bool = false;
pub fn setBenchGoActive(active: bool) void {
    bench_go_active = active;
}
pub fn benchGoActive() bool {
    return bench_go_active;
}

// Write `line` then a newline to `file`. Both writes happen while the caller holds
// write_mutex, so no other printLine can interleave between them -- the line stays
// whole even though it is two syscalls. writeStreamingAll issues the write(2) directly
// (no userspace buffer), so each line reaches the GUI immediately, as the old per-line
// fflush did. Ignore a write error (e.g. closed stdout), matching the old code.
fn writeLineLocked(the_io: std.Io, file: std.Io.File, line: []const u8) void {
    file.writeStreamingAll(the_io, line) catch {};
    file.writeStreamingAll(the_io, "\n") catch {};
}

// Write one line to stdout (and, if open, tee it to the log file).
pub fn printLine(str: [*]const u8, len: usize) void {
    const the_io = io();
    write_mutex.lockUncancelable(the_io);
    defer write_mutex.unlock(the_io);
    writeLineLocked(the_io, resolveOut(), str[0..len]);
    if (log_file) |f| writeLineLocked(the_io, f, str[0..len]);
}

// Open/close the log destination (printLine tees output to it). Close any current log
// on an empty name; (re)open for writing on a non-empty name. Guard with the
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

// Assert the property: with many threads hammering printLine, every line lands whole -- the mutex
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
        if (raw.len == 0) continue; // skip the empty tail the trailing newline yields
        try std.testing.expectEqualStrings(line, raw); // fail here on a torn line
        seen += 1;
    }
    try std.testing.expectEqual(threads_n * per_thread, seen);
}
