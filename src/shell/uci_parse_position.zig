// Parse the UCI `position` command.
//
// Split from uci_parse.zig on the 500-line lint, along the seam that file already had: the
// `go` and `position` parsers share no state, and the one helper both wanted lives in the
// uci_strings base leaf, so the dependency runs uci_parse -> here -> uci_strings with no cycle.
// uci_parse.zig re-exports this file's two public names, so uci.zig still imports one module
// for both commands.

const std = @import("std");
const uci_strings = @import("uci_strings");

const allocCString = uci_strings.allocOwned;

const start_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

pub const ParsedPosition = struct {
    ok: u8,
    fen: ?[]u8,
    moves: ?[]u8,
};

pub fn parsePosition(input: []const u8) ParsedPosition {
    return parsePositionAlloc(std.heap.c_allocator, input) catch .{ .ok = 0, .fen = null, .moves = null };
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
        // Append a TRAILING space after every token, as upstream's `fen += token + " "`
        // does (uci.cpp), rather than joining with separators. The two agree on a complete
        // FEN and disagree on a truncated one: `position fen rnbq` hands the parser
        // "rnbq " here and "rnbq" with a separator join, so the placement loop ends on
        // whitespace in one case and on end-of-input in the other -- two different
        // diagnostics for the same input.
        while (iter.next()) |fen_token| {
            if (std.mem.eql(u8, fen_token, "moves")) {
                break;
            }
            try fen.appendSlice(allocator, fen_token);
            try fen.append(allocator, ' ');
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
    errdefer if (fen_c) |f| allocator.free(f);
    const moves_c = try allocCString(allocator, moves.items);
    return .{ .ok = 1, .fen = fen_c, .moves = moves_c };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

// Shared with uci_parse.zig's fuzz test, which drives both parsers.
pub fn freePosition(pp: ParsedPosition) void {
    if (pp.fen) |f| std.heap.c_allocator.free(f);
    if (pp.moves) |m| std.heap.c_allocator.free(m);
}

test "parsePosition handles startpos and fen with moves" {
    const sp = parsePosition("position startpos moves e2e4 e7e5");
    defer freePosition(sp);
    try testing.expectEqual(@as(u8, 1), sp.ok);
    try testing.expectEqualStrings(start_fen, sp.fen.?);
    try testing.expectEqualStrings("e2e4\ne7e5", sp.moves.?);

    const fp = parsePosition("position fen 4k3/8/8/8/8/8/8/4K3 w - - 0 1 moves e1e2");
    defer freePosition(fp);
    try testing.expectEqual(@as(u8, 1), fp.ok);
    // Note the TRAILING space: upstream builds the FEN with `fen += token + " "`, and the
    // difference is load-bearing on a truncated FEN -- see the comment at the assembly.
    try testing.expectEqualStrings("4k3/8/8/8/8/8/8/4K3 w - - 0 1 ", fp.fen.?);
    try testing.expectEqualStrings("e1e2", fp.moves.?);

    // A truncated placement field must end at the trailing space, not at end-of-input, so
    // the parser reports upstream's "cursor not at end" rather than "end of stream".
    const trunc = parsePosition("position fen rnbq");
    defer freePosition(trunc);
    try testing.expectEqualStrings("rnbq ", trunc.fen.?);
}

test "parsePositionAlloc unwinds leak-free on every allocation failure" {
    const T = struct {
        fn run(a: std.mem.Allocator) !void {
            const pp = try parsePositionAlloc(a, "position startpos moves e2e4 e7e5 g1f3 b8c6");
            if (pp.fen) |f| a.free(f);
            if (pp.moves) |m| a.free(m);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, T.run, .{});
}

test "all public decls compile (uci_parse_position)" {
    std.testing.refAllDecls(@This());
}
