// Parse the UCI commands.
//
// Provide the `go` / `position` / `setoption` token parsers and their Parsed* result
// structs, split out of uci.zig. Keep pure over std + the uci_strings base leaf (no
// engine coupling -- the move-view parsing that needs engine_mod.ByteView stays
// in uci.zig's dispatch code). uci.zig re-exports the structs + the two public
// entry points (parseLimits / parsePosition) for its dispatch/runtime code.
//
// The `position` half lives in uci_parse_position.zig, split off on the 500-line lint along
// the seam this file already had: the two commands share no state, and the one helper they
// both wanted moved down into the uci_strings base leaf rather than being owned by either --
// a helper owned by one half would make the pair a file cycle. ParsedPosition / parsePosition
// are re-exported here, so uci.zig keeps importing one module for both commands.

const std = @import("std");
const uci_strings = @import("uci_strings");

const asciiLower = uci_strings.asciiLower;
const allocCString = uci_strings.allocOwned;
const uci_parse_position = @import("uci_parse_position.zig");

pub const ParsedPosition = uci_parse_position.ParsedPosition;
pub const parsePosition = uci_parse_position.parsePosition;

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

    // Bound one COUNT into [0, hi] and report it if it moved. Neither `movestogo` nor `mate`
    // means anything below zero, and both are bounded where they ENTER rather than where they
    // overflow -- the same place, and the same shape, as the clocks above.
    //
    // Read as i64 before clamping, exactly as the clocks are. Parsing straight into i32 accepts
    // every value that fits it, which is the whole hazard: -2147483648 is in range for the type
    // and nonsense for the field.
    const clampCount = struct {
        fn f(n: *std.ArrayList(u8), a: std.mem.Allocator, what: []const u8, given: i64, hi: i64) !i32 {
            const bounded = std.math.clamp(given, 0, hi);
            if (bounded != given) {
                const line = try std.fmt.allocPrint(
                    a,
                    "{s} {d} is outside [0, {d}]; using {d}\n",
                    .{ what, given, hi, bounded },
                );
                defer a.free(line);
                try n.appendSlice(a, line);
            }
            return @intCast(bounded);
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
            if (parseI64(iter.next())) |v| {
                // A negative movestogo does not overflow here -- timeman widens it to i64 --
                // but it carries straight into the time scale: `mtg` goes negative, so
                // `(0.88 + ply / 116.4) / mtg` is negative, the optimum time with it, and the
                // engine answers from a depth-4 search on a full clock.
                result.movestogo = try clampCount(&notice, allocator, "movestogo", v, std.math.maxInt(i32));
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
            if (parseI64(iter.next())) |v| {
                // Halve the ceiling: the stop condition compares against `2 * limits_mate`
                // (search_id_loop.zig), so an i32 at its own maximum wraps that product
                // negative and the condition can never hold -- the search runs on past a mate
                // it has already found. Bounded at maxInt/2, the doubling always fits.
                result.mate = try clampCount(&notice, allocator, "mate", v, @divTrunc(std.math.maxInt(i32), 2));
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

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

const freePosition = uci_parse_position.freePosition;

fn freeLimits(l: ParsedLimits) void {
    if (l.searchmoves) |s| std.heap.c_allocator.free(s);
    if (l.clamp_notice) |n| std.heap.c_allocator.free(n);
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

test "parseLimits bounds movestogo and mate where they enter" {
    // A negative movestogo does not overflow -- timeman widens it to i64 -- it poisons the time
    // SCALE: mtg goes negative, so does `(0.88 + ply / 116.4) / mtg` and the optimum time with
    // it, and the engine answers a full clock from a depth-4 search. Measured before the bound:
    // `go wtime 60000 btime 60000 movestogo -2147483648` reached depth 4 in 2 ms; after it,
    // depth 29 in 5.2 s.
    {
        const l = parseLimits("go wtime 60000 btime 60000 movestogo -2147483648");
        defer freeLimits(l);
        try testing.expectEqual(@as(i32, 0), l.movestogo);
        const notice = l.clamp_notice orelse return error.TestExpectedClampNotice;
        try testing.expect(std.mem.indexOf(u8, notice, "movestogo -2147483648 is outside") != null);
    }

    // `mate` is halved rather than merely floored, because the stop condition compares against
    // `2 * limits_mate`: at i32's own maximum that product wraps negative, the condition can
    // never hold, and the search runs on past a mate it already has.
    {
        const l = parseLimits("mate 2147483647");
        defer freeLimits(l);
        try testing.expectEqual(@divTrunc(@as(i32, std.math.maxInt(i32)), 2), l.mate);
        try testing.expect(l.clamp_notice != null);
        // The bound is what makes the doubling safe; state it as arithmetic, not as a hope.
        try testing.expect(@as(i64, l.mate) * 2 <= std.math.maxInt(i32));
    }

    // Both in range: untouched, and silent.
    {
        const l = parseLimits("movestogo 30 mate 5");
        defer freeLimits(l);
        try testing.expectEqual(@as(?[]u8, null), l.clamp_notice);
        try testing.expectEqual(@as(i32, 30), l.movestogo);
        try testing.expectEqual(@as(i32, 5), l.mate);
    }
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

// refAllDecls the UCI parse surface + the uci_strings C-string base leaf, so every
// pub decl compiles under `zig build test` even if the exe never reaches it.
test "all public decls compile (uci_parse + uci_strings)" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(uci_parse_position);
    std.testing.refAllDecls(uci_strings);
}
