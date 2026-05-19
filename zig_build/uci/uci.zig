const std = @import("std");

pub const ParsedLimits = extern struct {
    wtime: i64,
    btime: i64,
    winc: i64,
    binc: i64,
    movestogo: c_int,
    depth: c_int,
    mate: c_int,
    perft: c_int,
    infinite: c_int,
    movetime: i64,
    nodes: u64,
    ponder_mode: u8,
    searchmoves: ?[*:0]u8,
};

pub const ParsedPosition = extern struct {
    ok: u8,
    fen: ?[*:0]u8,
    moves: ?[*:0]u8,
};

pub fn parseLimits(input: []const u8) ParsedLimits {
    return parseLimitsAlloc(input) catch .{
        .wtime = 0,
        .btime = 0,
        .winc = 0,
        .binc = 0,
        .movestogo = 0,
        .depth = 0,
        .mate = 0,
        .perft = 0,
        .infinite = 0,
        .movetime = 0,
        .nodes = 0,
        .ponder_mode = 0,
        .searchmoves = null,
    };
}

pub fn parsePosition(input: []const u8) ParsedPosition {
    return parsePositionAlloc(input) catch .{ .ok = 0, .fen = null, .moves = null };
}

pub fn formatInfoString(input: []const u8) ?[*:0]u8 {
    return allocInfoString(input) catch null;
}

pub fn formatScore(kind: u8, value: c_int, extra: c_int) ?[*:0]u8 {
    return allocScore(kind, value, extra) catch null;
}

pub fn toCp(value: c_int, material: c_int) c_int {
    const params = winRateParams(material);
    return @intFromFloat(@round(100.0 * @as(f64, @floatFromInt(value)) / params.a));
}

pub fn wdl(value: c_int, material: c_int) ?[*:0]u8 {
    return allocWdl(value, material) catch null;
}

pub fn formatSquare(file: u8, rank: u8) ?[*:0]u8 {
    const bytes = [_]u8{ @as(u8, 'a') + file, @as(u8, '1') + rank };
    return allocCString(bytes[0..]) catch null;
}

pub fn formatMove(from_file: u8, from_rank: u8, to_file: u8, to_rank: u8, promotion: u8) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const extra: usize = if (promotion == 0) 0 else 1;
    const result = allocator.allocSentinel(u8, 4 + extra, 0) catch return null;
    result[0] = @as(u8, 'a') + from_file;
    result[1] = @as(u8, '1') + from_rank;
    result[2] = @as(u8, 'a') + to_file;
    result[3] = @as(u8, '1') + to_rank;
    if (promotion != 0) {
        result[4] = promotion;
    }
    return result.ptr;
}

pub fn toLower(input: []const u8) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const result = allocator.allocSentinel(u8, input.len, 0) catch return null;
    for (input, 0..) |byte, index| {
        result[index] = asciiLower(byte);
    }
    return result.ptr;
}

pub fn formatInfoNoMoves(depth: c_int, score_text: []const u8) ?[*:0]u8 {
    return allocFormatted("info depth {d} score {s}", .{ depth, score_text }) catch null;
}

pub fn formatInfoFull(
    depth: c_int,
    sel_depth: c_int,
    multi_pv: usize,
    score_text: []const u8,
    bound_text: []const u8,
    wdl_text: []const u8,
    show_wdl: u8,
    nodes: usize,
    nps: usize,
    hashfull: c_int,
    tb_hits: usize,
    time_ms: usize,
    pv: []const u8,
) ?[*:0]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(std.heap.c_allocator);

    builder.appendSlice(std.heap.c_allocator, "info depth ") catch return null;
    appendFormatted(&builder, "{d}", .{depth}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " seldepth ") catch return null;
    appendFormatted(&builder, "{d}", .{sel_depth}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " multipv ") catch return null;
    appendFormatted(&builder, "{d}", .{multi_pv}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " score ") catch return null;
    builder.appendSlice(std.heap.c_allocator, score_text) catch return null;
    if (bound_text.len != 0) {
        builder.append(std.heap.c_allocator, ' ') catch return null;
        builder.appendSlice(std.heap.c_allocator, bound_text) catch return null;
    }
    if (show_wdl != 0) {
        builder.appendSlice(std.heap.c_allocator, " wdl ") catch return null;
        builder.appendSlice(std.heap.c_allocator, wdl_text) catch return null;
    }
    builder.appendSlice(std.heap.c_allocator, " nodes ") catch return null;
    appendFormatted(&builder, "{d}", .{nodes}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " nps ") catch return null;
    appendFormatted(&builder, "{d}", .{nps}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " hashfull ") catch return null;
    appendFormatted(&builder, "{d}", .{hashfull}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " tbhits ") catch return null;
    appendFormatted(&builder, "{d}", .{tb_hits}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " time ") catch return null;
    appendFormatted(&builder, "{d}", .{time_ms}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " pv ") catch return null;
    builder.appendSlice(std.heap.c_allocator, pv) catch return null;

    return allocCString(builder.items) catch null;
}

pub fn formatInfoIter(depth: c_int, currmove: []const u8, currmove_number: c_int) ?[*:0]u8 {
    return allocFormatted(
        "info depth {d} currmove {s} currmovenumber {d}",
        .{ depth, currmove, currmove_number },
    ) catch null;
}

pub fn formatBestmove(bestmove: []const u8, ponder: []const u8) ?[*:0]u8 {
    if (ponder.len == 0) {
        return allocFormatted("bestmove {s}", .{bestmove}) catch null;
    }

    return allocFormatted("bestmove {s} ponder {s}", .{ bestmove, ponder }) catch null;
}

pub fn helpText() ?[*:0]u8 {
    return allocCString(
        "\nStockfish is a powerful chess engine for playing and analyzing.\n" ++ "It is released as free software licensed under the GNU GPLv3 License.\n" ++ "Stockfish is normally used with a graphical user interface (GUI) and implements\n" ++ "the Universal Chess Interface (UCI) protocol to communicate with a GUI, an API, etc.\n" ++ "For any further information, visit https://github.com/official-stockfish/Stockfish#readme\n" ++ "or read the corresponding README.md and Copying.txt files distributed along with this program.\n",
    ) catch null;
}

pub fn formatUnknownCommand(command: []const u8) ?[*:0]u8 {
    return allocFormatted("Unknown command: '{s}'. Type help for more information.", .{command}) catch null;
}

pub fn formatCriticalError(command: []const u8, message: []const u8) ?[*:0]u8 {
    return allocFormatted(
        "info string CRITICAL ERROR: Command `{s}` failed. Reason: {s}\n",
        .{ command, message },
    ) catch null;
}

fn parseLimitsAlloc(input: []const u8) !ParsedLimits {
    var result = ParsedLimits{
        .wtime = 0,
        .btime = 0,
        .winc = 0,
        .binc = 0,
        .movestogo = 0,
        .depth = 0,
        .mate = 0,
        .perft = 0,
        .infinite = 0,
        .movetime = 0,
        .nodes = 0,
        .ponder_mode = 0,
        .searchmoves = null,
    };
    var searchmoves = std.ArrayList(u8).empty;
    defer searchmoves.deinit(std.heap.c_allocator);
    var iter = std.mem.tokenizeAny(u8, input, " \t\r\n");

    while (iter.next()) |token| {
        if (std.mem.eql(u8, token, "searchmoves")) {
            while (iter.next()) |move| {
                if (searchmoves.items.len != 0) {
                    try searchmoves.append(std.heap.c_allocator, '\n');
                }
                const lowered = try lowerAlloc(move);
                defer std.heap.c_allocator.free(lowered);
                try searchmoves.appendSlice(std.heap.c_allocator, lowered);
            }
            break;
        } else if (std.mem.eql(u8, token, "wtime")) {
            result.wtime = parseI64(iter.next()) orelse result.wtime;
        } else if (std.mem.eql(u8, token, "btime")) {
            result.btime = parseI64(iter.next()) orelse result.btime;
        } else if (std.mem.eql(u8, token, "winc")) {
            result.winc = parseI64(iter.next()) orelse result.winc;
        } else if (std.mem.eql(u8, token, "binc")) {
            result.binc = parseI64(iter.next()) orelse result.binc;
        } else if (std.mem.eql(u8, token, "movestogo")) {
            result.movestogo = parseInt(c_int, iter.next()) orelse result.movestogo;
        } else if (std.mem.eql(u8, token, "depth")) {
            result.depth = parseInt(c_int, iter.next()) orelse result.depth;
        } else if (std.mem.eql(u8, token, "nodes")) {
            result.nodes = parseInt(u64, iter.next()) orelse result.nodes;
        } else if (std.mem.eql(u8, token, "movetime")) {
            result.movetime = parseI64(iter.next()) orelse result.movetime;
        } else if (std.mem.eql(u8, token, "mate")) {
            result.mate = parseInt(c_int, iter.next()) orelse result.mate;
        } else if (std.mem.eql(u8, token, "perft")) {
            result.perft = parseInt(c_int, iter.next()) orelse result.perft;
        } else if (std.mem.eql(u8, token, "infinite")) {
            result.infinite = 1;
        } else if (std.mem.eql(u8, token, "ponder")) {
            result.ponder_mode = 1;
        }
    }

    result.searchmoves = try allocCString(searchmoves.items);
    return result;
}

fn parsePositionAlloc(input: []const u8) !ParsedPosition {
    var iter = std.mem.tokenizeAny(u8, input, " \t\r\n");
    const first = iter.next() orelse return .{ .ok = 0, .fen = null, .moves = null };
    var token = first;
    if (std.mem.eql(u8, token, "position")) {
        token = iter.next() orelse return .{ .ok = 0, .fen = null, .moves = null };
    }

    var fen = std.ArrayList(u8).empty;
    defer fen.deinit(std.heap.c_allocator);
    var moves = std.ArrayList(u8).empty;
    defer moves.deinit(std.heap.c_allocator);

    if (std.mem.eql(u8, token, "startpos")) {
        try fen.appendSlice(std.heap.c_allocator, start_fen);
        _ = iter.next();
    } else if (std.mem.eql(u8, token, "fen")) {
        while (iter.next()) |fen_token| {
            if (std.mem.eql(u8, fen_token, "moves")) {
                break;
            }
            if (fen.items.len != 0) {
                try fen.append(std.heap.c_allocator, ' ');
            }
            try fen.appendSlice(std.heap.c_allocator, fen_token);
        }
    } else {
        return .{ .ok = 0, .fen = null, .moves = null };
    }

    while (iter.next()) |move| {
        if (moves.items.len != 0) {
            try moves.append(std.heap.c_allocator, '\n');
        }
        try moves.appendSlice(std.heap.c_allocator, move);
    }

    return .{
        .ok = 1,
        .fen = try allocCString(fen.items),
        .moves = try allocCString(moves.items),
    };
}

fn allocInfoString(input: []const u8) !?[*:0]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(std.heap.c_allocator);
    var line_iter = std.mem.splitScalar(u8, input, '\n');
    while (line_iter.next()) |line| {
        if (trimAsciiWhitespace(line).len == 0) {
            continue;
        }
        if (builder.items.len != 0) {
            try builder.append(std.heap.c_allocator, '\n');
        }
        try builder.appendSlice(std.heap.c_allocator, "info string ");
        try builder.appendSlice(std.heap.c_allocator, line);
    }

    return try allocCString(builder.items);
}

fn allocScore(kind: u8, value: c_int, extra: c_int) !?[*:0]u8 {
    return switch (kind) {
        0 => blk: {
            const mate = @divTrunc(if (value > 0) value + 1 else value, 2);
            break :blk try allocFormatted("mate {d}", .{mate});
        },
        1 => blk: {
            const tb_cp: c_int = 20000;
            const score = (if (extra != 0) tb_cp else -tb_cp) - value;
            break :blk try allocFormatted("cp {d}", .{score});
        },
        else => try allocFormatted("cp {d}", .{value}),
    };
}

fn allocWdl(value: c_int, material: c_int) !?[*:0]u8 {
    const win = winRateModel(value, material);
    const loss = winRateModel(-value, material);
    const draw = 1000 - win - loss;
    return try allocFormatted("{d} {d} {d}", .{ win, draw, loss });
}

fn winRateModel(value: c_int, material: c_int) c_int {
    const params = winRateParams(material);
    return @intFromFloat(0.5 + 1000.0 / (1.0 + std.math.exp((params.a - @as(f64, @floatFromInt(value))) / params.b)));
}

const WinRateParams = struct {
    a: f64,
    b: f64,
};

fn winRateParams(material: c_int) WinRateParams {
    const clamped = std.math.clamp(material, 17, 78);
    const m = @as(f64, @floatFromInt(clamped)) / 58.0;
    const as = [_]f64{ -72.32565836, 185.93832038, -144.58862193, 416.44950446 };
    const bs = [_]f64{ 83.86794042, -136.06112997, 69.98820887, 47.62901433 };
    const a = (((as[0] * m + as[1]) * m + as[2]) * m) + as[3];
    const b = (((bs[0] * m + bs[1]) * m + bs[2]) * m) + bs[3];
    return .{ .a = a, .b = b };
}

fn lowerAlloc(input: []const u8) ![]u8 {
    const allocator = std.heap.c_allocator;
    const result = try allocator.alloc(u8, input.len);
    for (input, 0..) |byte, index| {
        result[index] = asciiLower(byte);
    }
    return result;
}

fn appendFormatted(buffer: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const allocator = std.heap.c_allocator;
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try buffer.appendSlice(allocator, formatted);
}

fn allocFormatted(comptime fmt: []const u8, args: anytype) !?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    return try allocCString(formatted);
}

fn allocCString(value: []const u8) !?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result[0..value.len], value);
    return result.ptr;
}

fn trimAsciiWhitespace(input: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = input.len;
    while (start < end and isSpaceByte(input[start])) : (start += 1) {}
    while (end > start and isSpaceByte(input[end - 1])) {
        end -= 1;
    }
    return input[start..end];
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn isSpaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}

fn parseI64(token: ?[]const u8) ?i64 {
    return parseInt(i64, token);
}

fn parseInt(comptime T: type, token: ?[]const u8) ?T {
    const text = token orelse return null;
    return std.fmt.parseInt(T, text, 10) catch null;
}

const start_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
