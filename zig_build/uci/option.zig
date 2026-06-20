const std = @import("std");

// Zig-owned option value store. The C++ OptionsMap still owns option metadata
// (type/min/max/default) and the setoption write path, but the live current
// value of every option is mirrored here, keyed by the Option's registration
// index, and the bridge's Option read operators source their value from this
// store in the default target. This moves option-read authority out of the C++
// object as the first slice of retiring OptionsMap; the legacy oracle keeps
// reading the C++ currentValue, so oracle-parity cross-checks the two.
const max_options = 128;
var opt_values: [max_options]?[:0]u8 = .{null} ** max_options;

pub export fn zfish_optstore_reset() void {
    const allocator = std.heap.c_allocator;
    for (&opt_values) |*slot| {
        if (slot.*) |owned| allocator.free(owned);
        slot.* = null;
    }
}

pub export fn zfish_optstore_set(idx: usize, value_ptr: [*]const u8, value_len: usize) void {
    if (idx >= max_options) return;
    const allocator = std.heap.c_allocator;
    const buf = allocator.allocSentinel(u8, value_len, 0) catch {
        if (opt_values[idx]) |owned| allocator.free(owned);
        opt_values[idx] = null;
        return;
    };
    @memcpy(buf[0..value_len], value_ptr[0..value_len]);
    if (opt_values[idx]) |owned| allocator.free(owned);
    opt_values[idx] = buf;
}

pub export fn zfish_optstore_has(idx: usize) u8 {
    return if (idx < max_options and opt_values[idx] != null) 1 else 0;
}

pub export fn zfish_optstore_len(idx: usize) usize {
    if (idx < max_options) {
        if (opt_values[idx]) |owned| return owned.len;
    }
    return 0;
}

pub export fn zfish_optstore_ptr(idx: usize) ?[*]const u8 {
    if (idx < max_options) {
        if (opt_values[idx]) |owned| return owned.ptr;
    }
    return null;
}

pub const ParsedSetOption = extern struct {
    name: ?[*:0]u8,
    value: ?[*:0]u8,
};

pub const AssignmentResult = extern struct {
    accepted: u8,
    normalized_value: ?[*:0]u8,
};

pub const TuneNextResult = extern struct {
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
    return parseSetOptionAlloc(input) catch .{ .name = null, .value = null };
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
    return validateAssignmentAlloc(type_name, value, min_value, max_value, default_value) catch .{
        .accepted = 0,
        .normalized_value = null,
    };
}

pub fn tuneNext(names: []const u8, pop: u8) TuneNextResult {
    return tuneNextAlloc(names, pop) catch .{ .token = null, .remaining = null };
}

pub fn tuneShouldMakeOption(min_value: c_int, max_value: c_int) bool {
    return min_value != max_value;
}

fn parseSetOptionAlloc(input: []const u8) !ParsedSetOption {
    const allocator = std.heap.c_allocator;
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

        const target = if (in_value) &value else &name;
        if (target.items.len != 0) {
            try target.append(allocator, ' ');
        }
        try target.appendSlice(allocator, token);
    }

    return .{
        .name = try allocCString(name.items),
        .value = try allocCString(value.items),
    };
}


fn validateAssignmentAlloc(
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
        .normalized_value = try allocCString(normalized),
    };
}

fn tuneNextAlloc(names: []const u8, pop: u8) !TuneNextResult {
    const allocator = std.heap.c_allocator;
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

    return .{
        .token = try allocCString(token.items),
        .remaining = try allocCString(next_remaining),
    };
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

fn parseSignedInt(input: []const u8) ?c_int {
    const trimmed = trimAsciiWhitespace(input);
    return std.fmt.parseInt(c_int, trimmed, 10) catch null;
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
