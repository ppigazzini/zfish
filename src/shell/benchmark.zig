const std = @import("std");
const builtin = @import("builtin");
const c = @import("libc");
// Import the bench/benchmark position tables from their own pure-data leaf now.
const bench_positions = @import("bench_positions.zig");
const Defaults = bench_positions.Defaults;
const BenchmarkPositions = bench_positions.BenchmarkPositions;

// Define the benchmark data.
pub const BenchmarkSetupOutput = struct {
    tt_size: i32,
    threads: i32,
    commands_ptr: ?[]u8,
    original_invocation_ptr: ?[]u8,
    filled_invocation_ptr: ?[]u8,
    // Carry the "I clamped your number" lines back to the caller, which owns stdout; this leaf
    // has no output edge. Null when every argument was already in range, so the common path
    // allocates nothing. The caller frees it like the other three strings.
    clamp_notice_ptr: ?[]u8 = null,
};

// Bound every `speedtest` argument by the range the thing it feeds will actually take.
//
// Two multiplications below are done on a number a user typed, and both used to be done in i32,
// where an overflow is illegal behaviour in Zig: silent garbage in the shipped ReleaseFast build
// and a hard panic in ReleaseSafe. Both were reachable from one command line:
//
//   speedtest 4 128 2147484   ->  desired_time_s * 1000 overflows; timeScaleFactor goes
//                                 negative and every emitted `go movetime` gets a negative
//                                 argument
//   speedtest 100000000       ->  128 * threads overflows; tt_size goes negative, is emitted
//                                 as `setoption name Hash value -N`, and the option layer's
//                                 range check rejects it -- leaving the run measuring whatever
//                                 Hash happened to be set
//
// max_seconds is what the arithmetic holds rather than a policy: it is the largest value whose
// `* 1000` still fits i32.
//
// THE THREAD CEILING IS THIS MACHINE, NOT THE `Threads` OPTION RANGE, and the difference is the
// whole safety of this clamp. `Threads` accepts up to `max(1024, 4*hw)` (session.zig initBody),
// and a Worker costs about 15.5 MB -- so clamping a mistyped `speedtest 100000000` UP TO the
// option maximum would turn an argument error into a 16 GB allocation, and the derived
// `128 * threads` Hash into a six-figure MB request beside it. That is a worse outcome than the
// overflow this commit removes, not a fix for it.
//
// hardwareConcurrency is also the RIGHT bound on its own terms: speedtest measures this box, its
// own no-argument default is the core count, and more threads than cores does not measure
// anything faster. So a number larger than the machine means "use the machine".
//
// max_hash_mb mirrors the Hash spin range registered in session.zig's initBody, because this
// file DERIVES a Hash value and emits it as a setoption line -- a producer that does not know
// the consumer's range is exactly what let the two disagree in silence. It is a ceiling on a
// number the user typed, never a value this file will reach on its own: the derived default is
// `128 * threads`, and threads is bounded by the core count first.
const max_seconds: i32 = std.math.maxInt(i32) / 1000;
const min_seconds: i32 = 1;

fn maxThreadsFor(hardware_concurrency: i32) i32 {
    return @max(@as(i32, 1), hardware_concurrency);
}

const max_hash_mb: i32 = if (@sizeOf(usize) >= 8) 33554432 else 2048;

// Clamp `value` into [lo, hi], appending a report line when it moved. A silently corrected
// number is the same failure wearing a nicer hat: the run still does not do what was asked, and
// nothing says so.
fn clampReported(
    notice: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    what: []const u8,
    value: i32,
    lo: i32,
    hi: i32,
) !i32 {
    const bounded = std.math.clamp(value, lo, hi);
    if (bounded != value) {
        const line = try std.fmt.allocPrint(
            allocator,
            "speedtest: {s} {d} is outside [{d}, {d}]; using {d}\n",
            .{ what, value, lo, hi, bounded },
        );
        defer allocator.free(line);
        try notice.appendSlice(allocator, line);
    }
    return bounded;
}

pub fn setupBench(current_fen: []const u8, args: []const u8) ?[]u8 {
    return setupBenchAlloc(current_fen, args) catch null;
}

pub fn setupBenchmark(args: []const u8, hardware_concurrency: i32) BenchmarkSetupOutput {
    return setupBenchmarkAlloc(args, hardware_concurrency) catch .{
        .tt_size = 0,
        .threads = 0,
        .commands_ptr = null,
        .original_invocation_ptr = null,
        .filled_invocation_ptr = null,
    };
}

fn setupBenchAlloc(current_fen: []const u8, args: []const u8) ![]u8 {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();
    const allocator = std.heap.c_allocator;

    var token_iter = std.mem.tokenizeAny(u8, args, " \t\r\n");
    const tt_size = token_iter.next() orelse "16";
    const threads = token_iter.next() orelse "1";
    const limit = token_iter.next() orelse "13";
    const fen_file = token_iter.next() orelse "default";
    const limit_type = token_iter.next() orelse "depth";
    // Sixth token: repeat count for the `setup` workload (ignored otherwise). Repeating the
    // position list amortises the fixed one-time startup (net load, magic init, large-page
    // zero-fill) so the recurring per-search / per-refresh setup work dominates the profile.
    const setup_repeat: usize = blk: {
        const tok = token_iter.next() orelse break :blk 20;
        break :blk std.fmt.parseInt(usize, tok, 10) catch 20;
    };

    const go = if (std.mem.eql(u8, limit_type, "eval"))
        "eval"
    else
        try std.fmt.allocPrint(arena, "go {s} {s}", .{ limit_type, limit });

    var commands = std.ArrayList(u8).empty;
    defer commands.deinit(allocator);

    try appendCommandFmt(&commands, allocator, "setoption name Threads value {s}", .{threads});
    try appendCommandFmt(&commands, allocator, "setoption name Hash value {s}", .{tt_size});
    try appendCommand(&commands, allocator, "ucinewgame");

    if (std.mem.eql(u8, fen_file, "default")) {
        const defaults: []const []const u8 = &Defaults;
        for (defaults) |line| {
            try appendBenchmarkLine(&commands, allocator, line, go);
        }
    } else if (std.mem.eql(u8, fen_file, "setup")) {
        // Setup/refresh-weighted workload: emit `ucinewgame` before EACH default position.
        // A standard bench issues one `ucinewgame` and amortises the per-search setup (the
        // low-ply / worker-history fills, and the refresh-cache clear + full accumulator
        // refresh) over a deep node-dominated tree, so those costs fall below the measurement
        // floor. Firing `ucinewgame` per position instead recurs the worker-history clear and
        // the finny-cache reset ~50x and forces every position's first eval to refresh from an
        // emptied cache -- run it at a SHALLOW depth (e.g. `bench 16 1 2 setup`) so the setup
        // work dominates the node work. Deterministic (fixed positions/depth, resets between);
        // a SEPARATE workload that leaves the `bench 16 1 13` anchor untouched.
        const defaults: []const []const u8 = &Defaults;
        var rep: usize = 0;
        while (rep < setup_repeat) : (rep += 1) {
            for (defaults) |line| {
                if (std.mem.find(u8, line, "setoption") == null)
                    try appendCommand(&commands, allocator, "ucinewgame");
                try appendBenchmarkLine(&commands, allocator, line, go);
            }
        }
    } else if (std.mem.eql(u8, fen_file, "current")) {
        try appendBenchmarkLine(&commands, allocator, current_fen, go);
    } else {
        const file_data = readFileAlloc(allocator, fen_file) catch {
            std.debug.print("Unable to open file {s}\n", .{fen_file});
            c.exit(1);
        };
        defer allocator.free(file_data);

        var line_iter = std.mem.splitScalar(u8, file_data, '\n');
        while (line_iter.next()) |raw_line| {
            const line = if (raw_line.len != 0 and raw_line[raw_line.len - 1] == '\r')
                raw_line[0 .. raw_line.len - 1]
            else
                raw_line;
            if (line.len == 0) {
                continue;
            }
            try appendBenchmarkLine(&commands, allocator, line, go);
        }
    }

    return try allocCString(commands.items);
}

fn setupBenchmarkAlloc(args: []const u8, hardware_concurrency: i32) !BenchmarkSetupOutput {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();
    const allocator = std.heap.c_allocator;

    var token_iter = std.mem.tokenizeAny(u8, args, " \t\r\n");
    var original_invocation = std.ArrayList(u8).empty;
    defer original_invocation.deinit(allocator);

    var notice = std.ArrayList(u8).empty;
    defer notice.deinit(allocator);

    const parsed_threads = token_iter.next();
    const threads: i32 = if (parsed_threads) |token| blk: {
        try appendOriginalToken(&original_invocation, allocator, token);
        const given = try std.fmt.parseInt(i32, token, 10);
        break :blk try clampReported(&notice, allocator, "threads", given, 1, maxThreadsFor(hardware_concurrency));
    } else @max(@as(i32, 1), hardware_concurrency);

    const parsed_tt_size = token_iter.next();
    const tt_size: i32 = if (parsed_tt_size) |token| blk: {
        try appendOriginalToken(&original_invocation, allocator, token);
        const given = try std.fmt.parseInt(i32, token, 10);
        break :blk try clampReported(&notice, allocator, "hash", given, 1, max_hash_mb);
        // The DEFAULT below is derived, not typed, so it cannot be reported as the user's
        // number -- widen the multiply to i64 and clamp it into the same Hash range. `threads`
        // is already bounded above, so 128 * threads cannot leave i64.
    } else @intCast(std.math.clamp(@as(i64, 128) * @as(i64, threads), 1, max_hash_mb));

    const parsed_desired_time = token_iter.next();
    const desired_time_s: i32 = if (parsed_desired_time) |token| blk: {
        try appendOriginalToken(&original_invocation, allocator, token);
        const given = try std.fmt.parseInt(i32, token, 10);
        break :blk try clampReported(&notice, allocator, "seconds", given, min_seconds, max_seconds);
    } else 150;

    const filled_invocation = try std.fmt.allocPrint(
        arena,
        "{d} {d} {d}",
        .{ threads, tt_size, desired_time_s },
    );

    const games: []const []const []const u8 = &BenchmarkPositions;

    var total_time: f32 = 0;
    for (games) |game| {
        var index: usize = 0;
        while (index < game.len) : (index += 1) {
            total_time += @as(f32, @floatCast(getCorrectedTime(@as(i32, @intCast(index + 1)))));
        }
    }

    const time_scale_factor = @as(f32, @floatFromInt(desired_time_s * 1000)) / total_time;

    var commands = std.ArrayList(u8).empty;
    defer commands.deinit(allocator);
    for (games) |game| {
        try appendCommand(&commands, allocator, "ucinewgame");

        var ply: i32 = 1;
        for (game) |fen| {
            try appendCommandFmt(&commands, allocator, "position fen {s}", .{fen});
            const corrected_time = @as(i32, @intFromFloat(
                getCorrectedTime(ply) * @as(f64, @floatCast(time_scale_factor)),
            ));
            try appendCommandFmt(&commands, allocator, "go movetime {d}", .{corrected_time});
            ply += 1;
        }
    }

    const commands_ptr = try allocCString(commands.items);
    errdefer std.heap.c_allocator.free(commands_ptr);

    const original_invocation_ptr = try allocCString(original_invocation.items);
    errdefer std.heap.c_allocator.free(original_invocation_ptr);

    const filled_invocation_ptr = try allocCString(filled_invocation);
    errdefer std.heap.c_allocator.free(filled_invocation_ptr);

    const clamp_notice_ptr: ?[]u8 = if (notice.items.len != 0)
        try allocCString(notice.items)
    else
        null;

    return .{
        .tt_size = tt_size,
        .threads = threads,
        .commands_ptr = commands_ptr,
        .original_invocation_ptr = original_invocation_ptr,
        .filled_invocation_ptr = filled_invocation_ptr,
        .clamp_notice_ptr = clamp_notice_ptr,
    };
}

fn appendCommand(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, command: []const u8) !void {
    if (buffer.items.len != 0) {
        try buffer.append(allocator, '\n');
    }
    try buffer.appendSlice(allocator, command);
}

fn appendCommandFmt(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const command = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(command);
    try appendCommand(buffer, allocator, command);
}

fn appendBenchmarkLine(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    line: []const u8,
    go: []const u8,
) !void {
    if (std.mem.find(u8, line, "setoption") != null) {
        try appendCommand(buffer, allocator, line);
        return;
    }

    try appendCommandFmt(buffer, allocator, "position fen {s}", .{line});
    try appendCommand(buffer, allocator, go);
}

fn appendOriginalToken(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    token: []const u8,
) !void {
    if (buffer.items.len != 0) {
        try buffer.append(allocator, ' ');
    }
    try buffer.appendSlice(allocator, token);
}

fn allocCString(value: []const u8) ![]u8 {
    return std.heap.c_allocator.dupe(u8, value);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Read the whole file the idiomatic-Zig way, replacing the libc fopen/fseek/ftell/fread/fclose
    // dance. Rely on `init_single_threaded`, a BLOCKING std.Io handle: it spawns no threads and
    // installs no signal handlers (`have_signal_handler = false`), so this startup read has
    // zero interaction with the engine's own threadpool. Collapse non-OOM failures to the
    // caller's existing FileOpenFailed, keeping the error set {FileOpenFailed, OutOfMemory}.
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.FileOpenFailed,
    };
}

fn getCorrectedTime(ply: i32) f64 {
    return 50000.0 / (@as(f64, @floatFromInt(ply)) + 15.0);
}

// Free everything setupBenchmark handed back, so a test can call it without leaking.
fn freeSetup(out: BenchmarkSetupOutput) void {
    const a = std.heap.c_allocator;
    if (out.commands_ptr) |p| a.free(p);
    if (out.original_invocation_ptr) |p| a.free(p);
    if (out.filled_invocation_ptr) |p| a.free(p);
    if (out.clamp_notice_ptr) |p| a.free(p);
}

// Drive the two arguments that used to overflow, on the PURE setup function only.
//
// setupBenchmark builds a command string and allocates; it starts no search, spawns no thread
// and sizes no hash table, so the reproducers are safe to run here and are NOT safe to run
// against the binary: `speedtest 100000000` asks for a thread count whose Workers would be
// tens of GB, and reproducing a suspected OOM locally is how a box gets taken down rather than
// how a bug gets found. The string this returns carries every observable the engine would act
// on -- the emitted `setoption` values and every `go movetime` argument -- so checking it is
// checking the behaviour, one process short of the danger.
test "speedtest arguments are clamped instead of overflowing" {
    const hw: i32 = 16;

    // `desired_time_s * 1000` overflowed i32: illegal behaviour in ReleaseFast, a panic in
    // ReleaseSafe, and a negative timeScaleFactor feeding every `go movetime` if it wrapped.
    {
        const out = setupBenchmark("4 128 2147484", hw);
        defer freeSetup(out);
        const notice = out.clamp_notice_ptr orelse return error.TestExpectedClampNotice;
        try std.testing.expect(std.mem.indexOf(u8, notice, "seconds 2147484 is outside") != null);
        // No movetime may be negative, which is what the wrapped scale factor produced.
        const commands = out.commands_ptr orelse return error.TestExpectedCommands;
        try std.testing.expect(std.mem.indexOf(u8, commands, "movetime -") == null);
    }

    // `128 * threads` overflowed i32 and emitted a negative Hash, which the option range then
    // rejected -- so the run silently measured whatever Hash was already set. The thread count
    // must land on the core count, NOT on the `Threads` option maximum: clamping up to 1024
    // would trade the overflow for a multi-GB allocation.
    {
        const out = setupBenchmark("100000000", hw);
        defer freeSetup(out);
        const notice = out.clamp_notice_ptr orelse return error.TestExpectedClampNotice;
        try std.testing.expect(std.mem.indexOf(u8, notice, "threads 100000000 is outside") != null);
        try std.testing.expectEqual(hw, out.threads);
        try std.testing.expectEqual(@as(i32, 128 * hw), out.tt_size);
        try std.testing.expect(out.tt_size > 0);
    }

    // A negative argument is the same defect facing the other way, and the low bound catches it.
    {
        const out = setupBenchmark("-5 -1 -1", hw);
        defer freeSetup(out);
        try std.testing.expect(out.clamp_notice_ptr != null);
        try std.testing.expectEqual(@as(i32, 1), out.threads);
        try std.testing.expectEqual(@as(i32, 1), out.tt_size);
    }

    // An in-range invocation must be untouched and must report nothing: a clamp that fires on
    // a legal command line is a regression, and the silent path is the common one.
    {
        const out = setupBenchmark("4 128 10", hw);
        defer freeSetup(out);
        try std.testing.expectEqual(@as(?[]u8, null), out.clamp_notice_ptr);
        try std.testing.expectEqual(@as(i32, 4), out.threads);
        try std.testing.expectEqual(@as(i32, 128), out.tt_size);
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
