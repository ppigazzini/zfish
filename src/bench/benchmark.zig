const std = @import("std");
const builtin = @import("builtin");
const c = @import("libc");
// M21: the bench/benchmark position tables live in their own pure-data leaf now.
const bench_positions = @import("bench_positions.zig");
const Defaults = bench_positions.Defaults;
const BenchmarkPositions = bench_positions.BenchmarkPositions;

// C stdio stderr, obtained portably (M-PORT). @cImport's translation of the stream macros
// is not uniform across the owned OSes (a comptime-uncallable __acrt_iob_func() macro on
// Windows, an inline getter on macOS), so the underlying entry point is declared directly:
// glibc's global FILE* symbol, macOS's __stderrp global, or the Windows CRT accessor. Each
// arm is comptime-selected, so only the target's symbol is referenced/linked.
const std_streams = struct {
    extern "c" fn __acrt_iob_func(index: c_uint) *c.FILE;
    extern "c" var __stderrp: *c.FILE;
    extern "c" var stderr: *c.FILE;
};
fn cStderr() *c.FILE {
    return switch (builtin.os.tag) {
        .windows => std_streams.__acrt_iob_func(2),
        .macos, .ios, .tvos, .watchos, .visionos => std_streams.__stderrp,
        else => std_streams.stderr,
    };
}

// Native benchmark data, ported from the retired src/bench/benchmark.cpp
pub const BenchmarkSetupOutput = struct {
    tt_size: c_int,
    threads: c_int,
    commands_ptr: ?[*:0]u8,
    original_invocation_ptr: ?[*:0]u8,
    filled_invocation_ptr: ?[*:0]u8,
};

pub fn setupBench(current_fen: []const u8, args: []const u8) ?[*:0]u8 {
    return setupBenchAlloc(current_fen, args) catch null;
}

pub fn setupBenchmark(args: []const u8, hardware_concurrency: c_int) BenchmarkSetupOutput {
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
            _ = c.fprintf(
                cStderr(),
                "Unable to open file %.*s\n",
                @as(c_int, @intCast(fen_file.len)),
                fen_file.ptr,
            );
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

fn setupBenchmarkAlloc(args: []const u8, hardware_concurrency: c_int) !BenchmarkSetupOutput {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();
    const allocator = std.heap.c_allocator;

    var token_iter = std.mem.tokenizeAny(u8, args, " \t\r\n");
    var original_invocation = std.ArrayList(u8).empty;
    defer original_invocation.deinit(allocator);

    const parsed_threads = token_iter.next();
    const threads: c_int = if (parsed_threads) |token| blk: {
        try appendOriginalToken(&original_invocation, allocator, token);
        break :blk try std.fmt.parseInt(c_int, token, 10);
    } else @max(@as(c_int, 1), hardware_concurrency);

    const parsed_tt_size = token_iter.next();
    const tt_size: c_int = if (parsed_tt_size) |token| blk: {
        try appendOriginalToken(&original_invocation, allocator, token);
        break :blk try std.fmt.parseInt(c_int, token, 10);
    } else 128 * threads;

    const parsed_desired_time = token_iter.next();
    const desired_time_s: c_int = if (parsed_desired_time) |token| blk: {
        try appendOriginalToken(&original_invocation, allocator, token);
        break :blk try std.fmt.parseInt(c_int, token, 10);
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
            total_time += @as(f32, @floatCast(getCorrectedTime(@as(c_int, @intCast(index + 1)))));
        }
    }

    const time_scale_factor = @as(f32, @floatFromInt(desired_time_s * 1000)) / total_time;

    var commands = std.ArrayList(u8).empty;
    defer commands.deinit(allocator);
    for (games) |game| {
        try appendCommand(&commands, allocator, "ucinewgame");

        var ply: c_int = 1;
        for (game) |fen| {
            try appendCommandFmt(&commands, allocator, "position fen {s}", .{fen});
            const corrected_time = @as(c_int, @intFromFloat(
                getCorrectedTime(ply) * @as(f64, @floatCast(time_scale_factor)),
            ));
            try appendCommandFmt(&commands, allocator, "go movetime {d}", .{corrected_time});
            ply += 1;
        }
    }

    const commands_ptr = try allocCString(commands.items);
    errdefer c.free(@ptrCast(commands_ptr));

    const original_invocation_ptr = try allocCString(original_invocation.items);
    errdefer c.free(@ptrCast(original_invocation_ptr));

    const filled_invocation_ptr = try allocCString(filled_invocation);
    errdefer c.free(@ptrCast(filled_invocation_ptr));

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

fn getCorrectedTime(ply: c_int) f64 {
    return 50000.0 / (@as(f64, @floatFromInt(ply)) + 15.0);
}
