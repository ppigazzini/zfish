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
// Copy `value` into an owned slice; injecting the allocator makes the parsers' OOM
// paths reachable by checkAllAllocationFailures.
fn allocCString(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    return try allocator.dupe(u8, value);
}

// ======================================================================== //
// Parser cluster, moved verbatim from uci.zig.                       //
// ======================================================================== //
pub const ParsedSetOption = struct {
    name: ?[]u8,
    value: ?[]u8,
};

pub const ParsedLimits = struct {
    wtime: i64,
    btime: i64,
    winc: i64,
    binc: i64,
    movestogo: i32,
    depth: i32,
    mate: i32,
    perft: i32,
    infinite: i32,
    movetime: i64,
    nodes: u64,
    ponder_mode: u8,
    searchmoves: ?[]u8,
    // Name the keyword whose argument would not parse, mirroring upstream's `is.fail()`
    // check after the token if-chain (uci.cpp:226). Upstream reports the KEYWORD, not the
    // offending value: `go depth abc` -> "Invalid argument for 'depth'". Null means every
    // argument parsed. The caller terminates on it; parsing itself stays total.
    bad_token: ?[]const u8 = null,
    // Carry the "I bounded your clock" lines back to the caller, which owns stdout. Null when
    // every clock was already in range, so the common path allocates nothing. Freed like
    // `searchmoves`. NOT a `bad_token`: an out-of-range clock is bounded and the search runs,
    // where an unparsable one refuses.
    clamp_notice: ?[]u8 = null,
};

// Bound a clock at the point it ENTERS, which is the only place that knows it came from
// outside.
//
// wtime, btime, winc, binc and movetime used to reach timeman's arithmetic as raw i64s off the
// wire, and that arithmetic is asked to hold a number the protocol never had a right to send.
// Confirmed on this tree before the bound, ReleaseSafe:
//
//   go wtime 4000000000000000000 winc 4000000000000000000 btime 1000
//     thread panic: integer overflow, inside the search worker
//
// Illegal behaviour in Zig, so the shipped ReleaseFast build wraps silently into a garbage
// budget instead. Neither is a defect in timeman: `time_left` multiplies a clock by up to 51
// (`inc * (mtg - 1)` and `overhead * (2 + mtg)`), and no formula written in i64 can hold an
// arbitrary i64 times fifty.
//
// The bound is 1e12 ms -- about 31 years, past any real time control, and far enough below the
// top that every product timeman forms stays inside an i64. A negative clock is bounded at 0
// for the same reason: `go wtime -50000000000` underflows the same expression.
pub const max_clock_ms: i64 = 1_000_000_000_000;

pub const ParsedPosition = struct {
    ok: u8,
    fen: ?[]u8,
    moves: ?[]u8,
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
    var notice = std.ArrayList(u8).empty;
    defer notice.deinit(allocator);
    var iter = std.mem.tokenizeAny(u8, input, " \t\r\n");

    // Bound one clock into [0, max_clock_ms] and report it if it moved. See max_clock_ms.
    const clampClock = struct {
        fn f(n: *std.ArrayList(u8), a: std.mem.Allocator, what: []const u8, given: i64) !i64 {
            const bounded = std.math.clamp(given, 0, max_clock_ms);
            if (bounded != given) {
                const line = try std.fmt.allocPrint(
                    a,
                    "{s} {d} is outside [0, {d}]; using {d}\n",
                    .{ what, given, max_clock_ms, bounded },
                );
                defer a.free(line);
                try n.appendSlice(a, line);
            }
            return bounded;
        }
    }.f;

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
            if (parseI64(iter.next())) |v| {
                result.wtime = try clampClock(&notice, allocator, "wtime", v);
            } else {
                result.bad_token = "wtime";
                break;
            }
        } else if (std.mem.eql(u8, token, "btime")) {
            if (parseI64(iter.next())) |v| {
                result.btime = try clampClock(&notice, allocator, "btime", v);
            } else {
                result.bad_token = "btime";
                break;
            }
        } else if (std.mem.eql(u8, token, "winc")) {
            if (parseI64(iter.next())) |v| {
                result.winc = try clampClock(&notice, allocator, "winc", v);
            } else {
                result.bad_token = "winc";
                break;
            }
        } else if (std.mem.eql(u8, token, "binc")) {
            if (parseI64(iter.next())) |v| {
                result.binc = try clampClock(&notice, allocator, "binc", v);
            } else {
                result.bad_token = "binc";
                break;
            }
        } else if (std.mem.eql(u8, token, "movestogo")) {
            if (parseInt(i32, iter.next())) |v| {
                result.movestogo = v;
            } else {
                result.bad_token = "movestogo";
                break;
            }
        } else if (std.mem.eql(u8, token, "depth")) {
            if (parseInt(i32, iter.next())) |v| {
                result.depth = v;
            } else {
                result.bad_token = "depth";
                break;
            }
        } else if (std.mem.eql(u8, token, "nodes")) {
            if (parseU64Wrapping(iter.next())) |v| {
                result.nodes = v;
            } else {
                result.bad_token = "nodes";
                break;
            }
        } else if (std.mem.eql(u8, token, "movetime")) {
            if (parseI64(iter.next())) |v| {
                result.movetime = try clampClock(&notice, allocator, "movetime", v);
            } else {
                result.bad_token = "movetime";
                break;
            }
        } else if (std.mem.eql(u8, token, "mate")) {
            if (parseInt(i32, iter.next())) |v| {
                result.mate = v;
            } else {
                result.bad_token = "mate";
                break;
            }
        } else if (std.mem.eql(u8, token, "perft")) {
            if (parseInt(i32, iter.next())) |v| {
                result.perft = v;
            } else {
                result.bad_token = "perft";
                break;
            }
        } else if (std.mem.eql(u8, token, "infinite")) {
            result.infinite = 1;
        } else if (std.mem.eql(u8, token, "ponder")) {
            result.ponder_mode = 1;
        }
    }

    result.searchmoves = try allocCString(allocator, searchmoves.items);
    if (notice.items.len != 0) result.clamp_notice = try allocCString(allocator, notice.items);
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

// Parse a u64 the way upstream's `is >> uint64_t` (strtoull) does: a leading `-` is not an
// error but a modular negation, so `go nodes -5` yields 2^64 - 5 and searches rather than
// terminating. `parseInt(u64)` rejects the sign, so handle it explicitly.
fn parseU64Wrapping(token: ?[]const u8) ?u64 {
    const text = token orelse return null;
    if (text.len != 0 and text[0] == '-') {
        const mag = std.fmt.parseInt(u64, text[1..], 10) catch return null;
        return 0 -% mag;
    }
    return std.fmt.parseInt(u64, text, 10) catch null;
}

const start_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn freeLimits(l: ParsedLimits) void {
    if (l.searchmoves) |s| std.heap.c_allocator.free(s);
    if (l.clamp_notice) |n| std.heap.c_allocator.free(n);
}
fn freePosition(pp: ParsedPosition) void {
    if (pp.fen) |f| std.heap.c_allocator.free(f);
    if (pp.moves) |m| std.heap.c_allocator.free(m);
}

test "parseLimits reads the go parameters" {
    const l = parseLimits("wtime 1000 btime 2000 winc 10 binc 20 movestogo 30 depth 7 nodes 5000 movetime 500 infinite ponder");
    defer freeLimits(l);
    try testing.expectEqual(@as(i64, 1000), l.wtime);
    try testing.expectEqual(@as(i64, 2000), l.btime);
    try testing.expectEqual(@as(i64, 10), l.winc);
    try testing.expectEqual(@as(i64, 20), l.binc);
    try testing.expectEqual(@as(i32, 30), l.movestogo);
    try testing.expectEqual(@as(i32, 7), l.depth);
    try testing.expectEqual(@as(u64, 5000), l.nodes);
    try testing.expectEqual(@as(i64, 500), l.movetime);
    try testing.expectEqual(@as(u8, 1), l.infinite);
    try testing.expectEqual(@as(u8, 1), l.ponder_mode);
}

// Drive the clocks that reached timeman's arithmetic unbounded, on the PURE parser.
//
// The parser allocates and returns a struct; it starts no search and spawns no thread, so the
// reproducers are safe here. Against the binary they are a panic in ReleaseSafe and a wrapped
// garbage budget in ReleaseFast, which is the defect -- and the assertion that matters is the
// VALUE the search would have been handed, which is exactly what this returns.
test "parseLimits bounds a clock the protocol had no right to send" {
    // The overflow pair, from upstream's own reproducers: timeman multiplies a clock by up to
    // 51, so an arbitrary i64 cannot survive `inc * (mtg - 1)`.
    {
        const l = parseLimits("wtime 4000000000000000000 winc 4000000000000000000 btime 1000");
        defer freeLimits(l);
        try testing.expectEqual(max_clock_ms, l.wtime);
        try testing.expectEqual(max_clock_ms, l.winc);
        try testing.expectEqual(@as(i64, 1000), l.btime); // in range, untouched
        const notice = l.clamp_notice orelse return error.TestExpectedClampNotice;
        try testing.expect(std.mem.indexOf(u8, notice, "wtime 4000000000000000000 is outside") != null);
        try testing.expect(std.mem.indexOf(u8, notice, "winc 4000000000000000000 is outside") != null);
        try testing.expect(std.mem.indexOf(u8, notice, "btime") == null);
    }

    // The same defect facing the other way: a negative clock underflows the same expression.
    {
        const l = parseLimits("wtime -50000000000 btime 1000");
        defer freeLimits(l);
        try testing.expectEqual(@as(i64, 0), l.wtime);
        try testing.expect(l.clamp_notice != null);
    }

    // movetime takes the same bound: it is compared against the same budgets.
    {
        const l = parseLimits("movetime 9000000000000000000");
        defer freeLimits(l);
        try testing.expectEqual(max_clock_ms, l.movetime);
        try testing.expect(l.clamp_notice != null);
    }

    // A real time control must be untouched and must report nothing -- a clamp that fires on a
    // legal `go` is a regression, and the silent path is every game ever played.
    {
        const l = parseLimits("wtime 300000 btime 300000 winc 2000 binc 2000");
        defer freeLimits(l);
        try testing.expectEqual(@as(?[]u8, null), l.clamp_notice);
        try testing.expectEqual(@as(i64, 300000), l.wtime);
        try testing.expectEqual(@as(i64, 2000), l.winc);
    }
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
            if (l.searchmoves) |s| a.free(s);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, T.run, .{});
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

// refAllDecls the UCI parse surface + the uci_strings C-string base leaf, so every
// pub decl compiles under `zig build test` even if the exe never reaches it.
test "all public decls compile (uci_parse + uci_strings)" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(uci_strings);
}
