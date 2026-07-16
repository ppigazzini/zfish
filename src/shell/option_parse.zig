// Parse UCI option strings, split out of option.zig. Provide case-insensitive
// name compare, the setoption/validate/tune parsers (allocating + wrapper
// forms), and their combo/int/whitespace helpers plus the OOM-unwind gates.
// Depend only on std -- no OptionsModel and no global state -- so the
// model/facade side imports this leaf without a cycle.

const std = @import("std");

pub const ParsedSetOption = struct {
    name: ?[*:0]u8,
    value: ?[*:0]u8,
};

pub const AssignmentResult = struct {
    accepted: u8,
    normalized_value: ?[*:0]u8,
};

pub const TuneNextResult = struct {
    token: ?[*:0]u8,
    remaining: ?[*:0]u8,
};

pub fn caseInsensitiveLess(left: []const u8, right: []const u8) bool {
    const limit = @min(left.len, right.len);
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        const lhs = asciiLower(left[index]);
        const rhs = asciiLower(right[index]);
        if (lhs != rhs) {
            return lhs < rhs;
        }
    }

    return left.len < right.len;
}

pub fn parseSetOption(input: []const u8) ParsedSetOption {
    return parseSetOptionAlloc(std.heap.c_allocator, input) catch .{ .name = null, .value = null };
}

pub fn comboEquals(current: []const u8, query: []const u8) bool {
    return !caseInsensitiveLess(current, query) and !caseInsensitiveLess(query, current);
}

pub fn validateAssignment(
    type_name: []const u8,
    value: []const u8,
    min_value: c_int,
    max_value: c_int,
    default_value: []const u8,
) AssignmentResult {
    return validateAssignmentAlloc(std.heap.c_allocator, type_name, value, min_value, max_value, default_value) catch .{
        .accepted = 0,
        .normalized_value = null,
    };
}

pub fn tuneNext(names: []const u8, pop: u8) TuneNextResult {
    return tuneNextAlloc(std.heap.c_allocator, names, pop) catch .{ .token = null, .remaining = null };
}

pub fn tuneShouldMakeOption(min_value: c_int, max_value: c_int) bool {
    return min_value != max_value;
}

fn parseSetOptionAlloc(allocator: std.mem.Allocator, input: []const u8) !ParsedSetOption {
    var token_iter = std.mem.tokenizeAny(u8, input, " \t\r\n");
    _ = token_iter.next();

    var name = std.ArrayList(u8).empty;
    defer name.deinit(allocator);
    var value = std.ArrayList(u8).empty;
    defer value.deinit(allocator);

    var in_value = false;
    while (token_iter.next()) |token| {
        if (!in_value and std.mem.eql(u8, token, "value")) {
            in_value = true;
            continue;
        }

        // Follow the UCI grammar: `setoption name <id…> value <val…>`. The first token ("setoption") was
        // skipped above; skip the leading "name" keyword too, else it is captured as part of the
        // option id and every lookup fails with "No such option: name <id>".
        if (!in_value and name.items.len == 0 and std.mem.eql(u8, token, "name")) {
            continue;
        }

        const target = if (in_value) &value else &name;
        if (target.items.len != 0) {
            try target.append(allocator, ' ');
        }
        try target.appendSlice(allocator, token);
    }

    // Allocate both result strings; if the second fails, the first must be freed
    // (it isn't owned by anything yet) -- else it leaks on OOM.
    const name_c = try allocCString(allocator, name.items);
    errdefer if (name_c) |n| allocator.free(std.mem.span(n));
    const value_c = try allocCString(allocator, value.items);
    return .{ .name = name_c, .value = value_c };
}

fn validateAssignmentAlloc(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    value: []const u8,
    min_value: c_int,
    max_value: c_int,
    default_value: []const u8,
) !AssignmentResult {
    if (!std.mem.eql(u8, type_name, "button") and !std.mem.eql(u8, type_name, "string") and value.len == 0) {
        return .{ .accepted = 0, .normalized_value = null };
    }

    if (std.mem.eql(u8, type_name, "check")) {
        if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) {
            return .{ .accepted = 0, .normalized_value = null };
        }
    } else if (std.mem.eql(u8, type_name, "spin")) {
        const parsed = parseSignedInt(value) orelse return .{ .accepted = 0, .normalized_value = null };
        if (parsed < min_value or parsed > max_value) {
            return .{ .accepted = 0, .normalized_value = null };
        }
    } else if (std.mem.eql(u8, type_name, "combo")) {
        if (std.mem.eql(u8, value, "var") or !comboContains(default_value, value)) {
            return .{ .accepted = 0, .normalized_value = null };
        }
    }

    if (std.mem.eql(u8, type_name, "button")) {
        return .{ .accepted = 1, .normalized_value = null };
    }

    const normalized = if (std.mem.eql(u8, type_name, "string") and std.mem.eql(u8, value, "<empty>"))
        ""
    else
        value;

    return .{
        .accepted = 1,
        .normalized_value = try allocCString(allocator, normalized),
    };
}

fn tuneNextAlloc(allocator: std.mem.Allocator, names: []const u8, pop: u8) !TuneNextResult {
    var remaining = names;
    var token = std.ArrayList(u8).empty;
    defer token.deinit(allocator);

    while (true) {
        const comma_index = std.mem.indexOfScalar(u8, remaining, ',') orelse remaining.len;
        const segment = trimAsciiWhitespace(remaining[0..comma_index]);
        try token.appendSlice(allocator, segment);

        if (countChar(token.items, '(') == countChar(token.items, ')')) {
            break;
        }

        if (comma_index == remaining.len) {
            break;
        }

        remaining = remaining[comma_index + 1 ..];
    }

    const next_remaining = if (pop != 0) blk: {
        const comma_index = std.mem.indexOfScalar(u8, names, ',') orelse names.len;
        if (comma_index == names.len) {
            break :blk "";
        }

        var balance_names = names;
        var local_token = std.ArrayList(u8).empty;
        defer local_token.deinit(allocator);
        while (true) {
            const index = std.mem.indexOfScalar(u8, balance_names, ',') orelse balance_names.len;
            const segment = trimAsciiWhitespace(balance_names[0..index]);
            try local_token.appendSlice(allocator, segment);
            if (countChar(local_token.items, '(') == countChar(local_token.items, ')') or index == balance_names.len) {
                break :blk if (index == balance_names.len) "" else balance_names[index + 1 ..];
            }
            balance_names = balance_names[index + 1 ..];
        }
    } else names;

    // As in parseSetOptionAlloc: free the first result if the second alloc fails.
    const token_c = try allocCString(allocator, token.items);
    errdefer if (token_c) |t| allocator.free(std.mem.span(t));
    const remaining_c = try allocCString(allocator, next_remaining);
    return .{ .token = token_c, .remaining = remaining_c };
}

fn comboContains(options: []const u8, value: []const u8) bool {
    var token_iter = std.mem.tokenizeAny(u8, options, " \t\r\n");
    while (token_iter.next()) |token| {
        if (comboEquals(token, value)) {
            return true;
        }
    }
    return false;
}

pub fn parseSignedInt(input: []const u8) ?c_int {
    const trimmed = trimAsciiWhitespace(input);
    return std.fmt.parseInt(c_int, trimmed, 10) catch null;
}

fn allocCString(allocator: std.mem.Allocator, value: []const u8) !?[*:0]u8 {
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

fn countChar(input: []const u8, needle: u8) usize {
    var count: usize = 0;
    for (input) |byte| {
        if (byte == needle) {
            count += 1;
        }
    }
    return count;
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn isSpaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}

pub fn nameEquals(left: []const u8, right: []const u8) bool {
    return !caseInsensitiveLess(left, right) and !caseInsensitiveLess(right, left);
}

// Note the pure UCI parsers now take an injected allocator (was a hardcoded
// std.heap.c_allocator), so their OOM paths are testable. Each builds ArrayList
// scratch (freed via defer) then allocCStrings the result -- gate every allocation
// failure and free the result with the same allocator.
test "parseSetOptionAlloc unwinds leak-free on every allocation failure" {
    const T = struct {
        fn run(a: std.mem.Allocator) !void {
            const parsed = try parseSetOptionAlloc(a, "name Threads value 8");
            if (parsed.name) |n| a.free(std.mem.span(n));
            if (parsed.value) |v| a.free(std.mem.span(v));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, T.run, .{});
}

test "validateAssignmentAlloc unwinds leak-free on every allocation failure" {
    const T = struct {
        fn run(a: std.mem.Allocator) !void {
            const res = try validateAssignmentAlloc(a, "spin", "8", 1, 1024, "1");
            if (res.normalized_value) |v| a.free(std.mem.span(v));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, T.run, .{});
}

test "tuneNextAlloc unwinds leak-free on every allocation failure" {
    const T = struct {
        fn run(a: std.mem.Allocator) !void {
            const res = try tuneNextAlloc(a, "a(1),b(2),c(3)", 1);
            if (res.token) |t| a.free(std.mem.span(t));
            if (res.remaining) |r| a.free(std.mem.span(r));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, T.run, .{});
}

test {
    @import("std").testing.refAllDecls(@This());
}

// ---- property fuzz--------------------------------------------------
// Treat the pure UCI parsers as the most fuzz-appropriate surface in the engine (a
// tokenizer bolted to a validator). Until coverage-guided `-ffuzz` is wired,
// hammer them with these PRNG property tests on random + adversarial input
// and assert the only universal invariant: no crash / no UB, and results freed.

const testing = std.testing;

fn freeCStr(p: ?[*:0]u8) void {
    if (p) |ptr| std.heap.c_allocator.free(std.mem.span(ptr));
}

test "fuzz: parseSetOption survives random and adversarial input" {
    var prng = std.Random.DefaultPrng.init(0xF00D_CAFE);
    const rand = prng.random();
    var buf: [160]u8 = undefined;
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        const len = rand.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*b| b.* = rand.int(u8);
        const parsed = parseSetOption(buf[0..len]);
        freeCStr(parsed.name);
        freeCStr(parsed.value);
    }
    const cases = [_][]const u8{
        "",                                                      "setoption",
        "setoption name",                                        "setoption name  value ",
        "setoption value x name y",                              "setoption name value",
        "\x00\xff\x00",                                          "   \t\r\n  ",
        "setoption name Hash value 999999999999999999999999999", "setoption name " ++ @as([300]u8, @splat('A')) ++ " value " ++ @as([300]u8, @splat('B')),
    };
    for (cases) |case| {
        const parsed = parseSetOption(case);
        freeCStr(parsed.name);
        freeCStr(parsed.value);
    }
}

test "fuzz: caseInsensitiveLess is a strict weak ordering" {
    var prng = std.Random.DefaultPrng.init(0x1234_5678);
    const rand = prng.random();
    var a: [24]u8 = undefined;
    var b: [24]u8 = undefined;
    var i: usize = 0;
    while (i < 50000) : (i += 1) {
        const la = rand.uintLessThan(usize, a.len + 1);
        const lb = rand.uintLessThan(usize, b.len + 1);
        for (a[0..la]) |*x| x.* = rand.int(u8);
        for (b[0..lb]) |*x| x.* = rand.int(u8);
        const sa = a[0..la];
        const sb = b[0..lb];
        // Assert irreflexivity: never a < a
        try testing.expect(!caseInsensitiveLess(sa, sa));
        // Assert asymmetry: not both a < b and b < a
        try testing.expect(!(caseInsensitiveLess(sa, sb) and caseInsensitiveLess(sb, sa)));
    }
}

test "fuzz: validateAssignment / tuneNext never crash" {
    var prng = std.Random.DefaultPrng.init(0x9E37_79B9);
    const rand = prng.random();
    const types = [_][]const u8{ "spin", "check", "string", "combo", "button", "junk" };
    var vbuf: [40]u8 = undefined;
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        const ty = types[rand.uintLessThan(usize, types.len)];
        const vlen = rand.uintLessThan(usize, vbuf.len + 1);
        for (vbuf[0..vlen]) |*x| x.* = rand.int(u8);
        const val = vbuf[0..vlen];
        const mn = rand.int(c_int);
        const mx = rand.int(c_int);
        const res = validateAssignment(ty, val, mn, mx, val);
        freeCStr(res.normalized_value);
        const tn = tuneNext(val, rand.int(u8));
        freeCStr(tn.token);
        freeCStr(tn.remaining);
    }
}
