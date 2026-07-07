// UCI command parsers (M17.3w).
//
// The `go` / `position` / `setoption` token parsers and their Parsed* result
// structs, split out of uci.zig. Pure over std + the uci_strings base leaf (no
// engine coupling -- the move-view parsing that needs engine_mod.ByteView stays
// in uci.zig's dispatch code). uci.zig re-exports the structs + the two public
// entry points (parseLimits / parsePosition) for its dispatch/runtime code.

const std = @import("std");
const uci_strings = @import("uci_strings");

const allocCString = uci_strings.allocCString;
const asciiLower = uci_strings.asciiLower;

// ======================================================================== //
// Parser cluster, moved verbatim from uci.zig (M17.3w).                       //
// ======================================================================== //
pub const ParsedSetOption = struct {
    name: ?[*:0]u8,
    value: ?[*:0]u8,
};

pub const ParsedLimits = struct {
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

pub const ParsedPosition = struct {
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

fn lowerAlloc(input: []const u8) ![]u8 {
    const allocator = std.heap.c_allocator;
    const result = try allocator.alloc(u8, input.len);
    for (input, 0..) |byte, index| {
        result[index] = asciiLower(byte);
    }
    return result;
}

fn parseI64(token: ?[]const u8) ?i64 {
    return parseInt(i64, token);
}

fn parseInt(comptime T: type, token: ?[]const u8) ?T {
    const text = token orelse return null;
    return std.fmt.parseInt(T, text, 10) catch null;
}

const start_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
