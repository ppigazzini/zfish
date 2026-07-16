// Parse the UCI commands.
//
// Provide the `go` / `position` / `setoption` token parsers and their Parsed* result
// structs, split out of uci.zig. Keep pure over std + the uci_strings base leaf (no
// engine coupling -- the move-view parsing that needs engine_mod.ByteView stays
// in uci.zig's dispatch code). uci.zig re-exports the structs + the two public
// entry points (parseLimits / parsePosition) for its dispatch/runtime code.

const std = @import("std");
const uci_strings = @import("uci_strings");

const asciiLower = uci_strings.asciiLower;

// Provide a local allocator-taking allocCString (uci_strings.allocCString hardcodes
// std.heap.c_allocator and has ~25 callers, so it is left alone); injecting the
// allocator here makes the parsers' OOM paths reachable by checkAllAllocationFailures.
fn allocCString(allocator: std.mem.Allocator, value: []const u8) !?[*:0]u8 {
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result[0..value.len], value);
    return result.ptr;
}

// ======================================================================== //
// Parser cluster, moved verbatim from uci.zig.                       //
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
    return parseLimitsAlloc(std.heap.c_allocator, input) catch .{
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
    return parsePositionAlloc(std.heap.c_allocator, input) catch .{ .ok = 0, .fen = null, .moves = null };
}

fn parseLimitsAlloc(allocator: std.mem.Allocator, input: []const u8) !ParsedLimits {
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
    defer searchmoves.deinit(allocator);
    var iter = std.mem.tokenizeAny(u8, input, " \t\r\n");

    while (iter.next()) |token| {
        if (std.mem.eql(u8, token, "searchmoves")) {
            while (iter.next()) |move| {
                if (searchmoves.items.len != 0) {
                    try searchmoves.append(allocator, '\n');
                }
                const lowered = try lowerAlloc(allocator, move);
                defer allocator.free(lowered);
                try searchmoves.appendSlice(allocator, lowered);
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

    result.searchmoves = try allocCString(allocator, searchmoves.items);
    return result;
}

fn parsePositionAlloc(allocator: std.mem.Allocator, input: []const u8) !ParsedPosition {
    var iter = std.mem.tokenizeAny(u8, input, " \t\r\n");
    const first = iter.next() orelse return .{ .ok = 0, .fen = null, .moves = null };
    var token = first;
    if (std.mem.eql(u8, token, "position")) {
        token = iter.next() orelse return .{ .ok = 0, .fen = null, .moves = null };
    }

    var fen = std.ArrayList(u8).empty;
    defer fen.deinit(allocator);
    var moves = std.ArrayList(u8).empty;
    defer moves.deinit(allocator);

    if (std.mem.eql(u8, token, "startpos")) {
        try fen.appendSlice(allocator, start_fen);
        _ = iter.next();
    } else if (std.mem.eql(u8, token, "fen")) {
        while (iter.next()) |fen_token| {
            if (std.mem.eql(u8, fen_token, "moves")) {
                break;
            }
            if (fen.items.len != 0) {
                try fen.append(allocator, ' ');
            }
            try fen.appendSlice(allocator, fen_token);
        }
    } else {
        return .{ .ok = 0, .fen = null, .moves = null };
    }

    while (iter.next()) |move| {
        if (moves.items.len != 0) {
            try moves.append(allocator, '\n');
        }
        try moves.appendSlice(allocator, move);
    }

    // Free the first result if the second alloc fails (else it leaks on OOM).
    const fen_c = try allocCString(allocator, fen.items);
    errdefer if (fen_c) |f| allocator.free(std.mem.span(f));
    const moves_c = try allocCString(allocator, moves.items);
    return .{ .ok = 1, .fen = fen_c, .moves = moves_c };
}

fn lowerAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
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

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn freeLimits(l: ParsedLimits) void {
    if (l.searchmoves) |s| std.heap.c_allocator.free(std.mem.span(s));
}
fn freePosition(pp: ParsedPosition) void {
    if (pp.fen) |f| std.heap.c_allocator.free(std.mem.span(f));
    if (pp.moves) |m| std.heap.c_allocator.free(std.mem.span(m));
}

test "parseLimits reads the go parameters" {
    const l = parseLimits("wtime 1000 btime 2000 winc 10 binc 20 movestogo 30 depth 7 nodes 5000 movetime 500 infinite ponder");
    defer freeLimits(l);
    try testing.expectEqual(@as(i64, 1000), l.wtime);
    try testing.expectEqual(@as(i64, 2000), l.btime);
    try testing.expectEqual(@as(i64, 10), l.winc);
    try testing.expectEqual(@as(i64, 20), l.binc);
    try testing.expectEqual(@as(c_int, 30), l.movestogo);
    try testing.expectEqual(@as(c_int, 7), l.depth);
    try testing.expectEqual(@as(u64, 5000), l.nodes);
    try testing.expectEqual(@as(i64, 500), l.movetime);
    try testing.expectEqual(@as(u8, 1), l.infinite);
    try testing.expectEqual(@as(u8, 1), l.ponder_mode);
}

test "parsePosition handles startpos and fen with moves" {
    const sp = parsePosition("position startpos moves e2e4 e7e5");
    defer freePosition(sp);
    try testing.expectEqual(@as(u8, 1), sp.ok);
    try testing.expectEqualStrings(start_fen, std.mem.span(sp.fen.?));
    try testing.expectEqualStrings("e2e4\ne7e5", std.mem.span(sp.moves.?));

    const fp = parsePosition("position fen 4k3/8/8/8/8/8/8/4K3 w - - 0 1 moves e1e2");
    defer freePosition(fp);
    try testing.expectEqual(@as(u8, 1), fp.ok);
    try testing.expectEqualStrings("4k3/8/8/8/8/8/8/4K3 w - - 0 1", std.mem.span(fp.fen.?));
    try testing.expectEqualStrings("e1e2", std.mem.span(fp.moves.?));
}

// Fuzz to prove neither parser crashes / OOBs on arbitrary input -- it returns a struct
// (parseLimits) or an ok/not-ok result (parsePosition). Use a deterministic PRNG so it
// is reproducible in `zig build test`.
const uci_alphabet = "go position startpos fen moves wtime btime depth nodes infinite ponder 0123456789 /-KQkqabcdefgh ";

test "fuzz: the UCI parsers tolerate arbitrary input" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 30_000) : (iter += 1) {
        var buf: [128]u8 = undefined;
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..len]) |*b| b.* = uci_alphabet[rand.uintLessThan(usize, uci_alphabet.len)];
        freeLimits(parseLimits(buf[0..len]));
        freePosition(parsePosition(buf[0..len]));
    }
}

// Gate the OOM unwinds. The parsers now take an injected allocator, so
// checkAllAllocationFailures can fail each allocation (ArrayList growth, lowerAlloc,
// the result allocCStrings) and assert every unwind is leak-free -- this is what caught
// the parsePositionAlloc double-result leak.
test "parseLimitsAlloc unwinds leak-free on every allocation failure" {
    const T = struct {
        fn run(a: std.mem.Allocator) !void {
            const l = try parseLimitsAlloc(a, "searchmoves e2e4 d2d4 g1f3 wtime 1000 depth 7");
            if (l.searchmoves) |s| a.free(std.mem.span(s));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, T.run, .{});
}

test "parsePositionAlloc unwinds leak-free on every allocation failure" {
    const T = struct {
        fn run(a: std.mem.Allocator) !void {
            const pp = try parsePositionAlloc(a, "position startpos moves e2e4 e7e5 g1f3 b8c6");
            if (pp.fen) |f| a.free(std.mem.span(f));
            if (pp.moves) |m| a.free(std.mem.span(m));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, T.run, .{});
}

// refAllDecls the UCI parse surface + the uci_strings C-string base leaf, so every
// pub decl compiles under `zig build test` even if the exe never reaches it.
test "all public decls compile (uci_parse + uci_strings)" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(uci_strings);
}
