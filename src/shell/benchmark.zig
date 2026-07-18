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
    commands_ptr: ?[*:0]u8,
    original_invocation_ptr: ?[*:0]u8,
    filled_invocation_ptr: ?[*:0]u8,
};

pub fn setupBench(current_fen: []const u8, args: []const u8) ?[*:0]u8 {
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

fn setupBenchAlloc(current_fen: []const u8, args: []const u8) ![*:0]u8 {
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

    const parsed_threads = token_iter.next();
    const threads: i32 = if (parsed_threads) |token| blk: {
        try appendOriginalToken(&original_invocation, allocator, token);
        break :blk try std.fmt.parseInt(i32, token, 10);
    } else @max(@as(i32, 1), hardware_concurrency);

    const parsed_tt_size = token_iter.next();
    const tt_size: i32 = if (parsed_tt_size) |token| blk: {
        try appendOriginalToken(&original_invocation, allocator, token);
        break :blk try std.fmt.parseInt(i32, token, 10);
    } else 128 * threads;

    const parsed_desired_time = token_iter.next();
    const desired_time_s: i32 = if (parsed_desired_time) |token| blk: {
        try appendOriginalToken(&original_invocation, allocator, token);
        break :blk try std.fmt.parseInt(i32, token, 10);
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
    errdefer std.heap.c_allocator.free(std.mem.span(commands_ptr));

    const original_invocation_ptr = try allocCString(original_invocation.items);
    errdefer std.heap.c_allocator.free(std.mem.span(original_invocation_ptr));

    const filled_invocation_ptr = try allocCString(filled_invocation);
    errdefer std.heap.c_allocator.free(std.mem.span(filled_invocation_ptr));

    return .{
        .tt_size = tt_size,
        .threads = threads,
        .commands_ptr = commands_ptr,
        .original_invocation_ptr = original_invocation_ptr,
        .filled_invocation_ptr = filled_invocation_ptr,
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
    if (std.mem.indexOf(u8, line, "setoption") != null) {
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

fn allocCString(value: []const u8) ![*:0]u8 {
    const allocator = std.heap.c_allocator;
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result[0..value.len], value);
    return result.ptr;
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

test {
    @import("std").testing.refAllDecls(@This());
}
