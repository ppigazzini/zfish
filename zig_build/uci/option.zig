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

fn nameEquals(left: []const u8, right: []const u8) bool {
    return !caseInsensitiveLess(left, right) and !caseInsensitiveLess(right, left);
}

// ---------------------------------------------------------------------------
// Zig-owned option model (engine-graph reimplementation).
//
// The complete data model behind a UCI OptionsMap: name, type, default,
// current value, spin bounds, registration order, and the change-callback kind,
// all owned in Zig. This replaces the C++ Option metadata fields and the
// std::map storage; the parse/validate/normalize logic already lives in this
// file and is reused here. Verified by the tests at the bottom.
// ---------------------------------------------------------------------------
pub const OptionKind = enum(u8) { string = 0, check = 1, spin = 2, button = 3 };

pub fn optionKindName(kind: OptionKind) []const u8 {
    return switch (kind) {
        .string => "string",
        .check => "check",
        .spin => "spin",
        .button => "button",
    };
}

pub const OptionEntry = struct {
    name: []u8,
    kind: OptionKind,
    default_value: []u8,
    current_value: []u8,
    min: c_int,
    max: c_int,
    callback_kind: u8,
};

pub const SetOutcome = struct {
    found: bool,
    accepted: bool,
    changed: bool,
    callback_kind: u8,
};

pub const OptionsModel = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(OptionEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) OptionsModel {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OptionsModel) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.default_value);
            self.allocator.free(entry.current_value);
        }
        self.entries.deinit(self.allocator);
    }

    fn dup(self: *OptionsModel, source: []const u8) ![]u8 {
        const buf = try self.allocator.alloc(u8, source.len);
        @memcpy(buf, source);
        return buf;
    }

    pub fn add(
        self: *OptionsModel,
        name: []const u8,
        kind: OptionKind,
        default_value: []const u8,
        min: c_int,
        max: c_int,
        callback_kind: u8,
    ) !usize {
        const idx = self.entries.items.len;
        const name_copy = try self.dup(name);
        errdefer self.allocator.free(name_copy);
        const default_copy = try self.dup(default_value);
        errdefer self.allocator.free(default_copy);
        const current_copy = try self.dup(default_value);
        errdefer self.allocator.free(current_copy);
        try self.entries.append(self.allocator, .{
            .name = name_copy,
            .kind = kind,
            .default_value = default_copy,
            .current_value = current_copy,
            .min = min,
            .max = max,
            .callback_kind = callback_kind,
        });
        return idx;
    }

    fn findIndex(self: *const OptionsModel, name: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (nameEquals(entry.name, name)) return i;
        }
        return null;
    }

    pub fn count(self: *const OptionsModel) usize {
        return self.entries.items.len;
    }

    pub fn has(self: *const OptionsModel, name: []const u8) bool {
        return self.findIndex(name) != null;
    }

    pub fn getString(self: *const OptionsModel, name: []const u8) []const u8 {
        if (self.findIndex(name)) |i| return self.entries.items[i].current_value;
        return "";
    }

    pub fn getInt(self: *const OptionsModel, name: []const u8) c_int {
        if (self.findIndex(name)) |i| {
            const entry = self.entries.items[i];
            if (entry.kind == .spin) return parseSignedInt(entry.current_value) orelse 0;
            if (entry.kind == .check) return if (std.mem.eql(u8, entry.current_value, "true")) 1 else 0;
        }
        return 0;
    }

    // Normalize a candidate value for an option, mirroring validateAssignment.
    // Returns an allocator-owned normalized string, or null if rejected.
    fn normalize(self: *OptionsModel, entry: OptionEntry, value: []const u8) !?[]u8 {
        const is_button = entry.kind == .button;
        const is_string = entry.kind == .string;
        if (!is_button and !is_string and value.len == 0) return null;

        switch (entry.kind) {
            .check => {
                if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) return null;
            },
            .spin => {
                const parsed = parseSignedInt(value) orelse return null;
                if (parsed < entry.min or parsed > entry.max) return null;
            },
            else => {},
        }

        if (is_button) return try self.dup("");
        const normalized = if (is_string and std.mem.eql(u8, value, "<empty>")) "" else value;
        return try self.dup(normalized);
    }

    pub fn setValue(self: *OptionsModel, name: []const u8, value: []const u8) !SetOutcome {
        const idx = self.findIndex(name) orelse
            return .{ .found = false, .accepted = false, .changed = false, .callback_kind = 0 };
        const entry = &self.entries.items[idx];

        const normalized = (try self.normalize(entry.*, value)) orelse
            return .{ .found = true, .accepted = false, .changed = false, .callback_kind = 0 };

        if (entry.kind == .button) {
            self.allocator.free(normalized);
            return .{ .found = true, .accepted = true, .changed = false, .callback_kind = entry.callback_kind };
        }

        const changed = !std.mem.eql(u8, entry.current_value, normalized);
        self.allocator.free(entry.current_value);
        entry.current_value = normalized;
        return .{ .found = true, .accepted = true, .changed = changed, .callback_kind = entry.callback_kind };
    }

    // Render the UCI option listing in registration order, matching the C++
    // OptionsMap operator<<.
    pub fn renderAlloc(self: *OptionsModel) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        for (self.entries.items) |entry| {
            const head = try std.fmt.allocPrint(self.allocator, "\noption name {s} type {s}", .{
                entry.name, optionKindName(entry.kind),
            });
            defer self.allocator.free(head);
            try out.appendSlice(self.allocator, head);

            const tail: ?[]u8 = switch (entry.kind) {
                .check => try std.fmt.allocPrint(self.allocator, " default {s}", .{entry.default_value}),
                .string => try std.fmt.allocPrint(self.allocator, " default {s}", .{
                    if (entry.default_value.len == 0) "<empty>" else entry.default_value,
                }),
                .spin => try std.fmt.allocPrint(self.allocator, " default {d} min {d} max {d}", .{
                    parseSignedInt(entry.default_value) orelse 0, entry.min, entry.max,
                }),
                .button => null,
            };
            if (tail) |t| {
                defer self.allocator.free(t);
                try out.appendSlice(self.allocator, t);
            }
        }
        return out.toOwnedSlice(self.allocator);
    }
};

test "options model stores defaults and reads typed values" {
    var model = OptionsModel.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.add("Threads", .spin, "1", 1, 1024, 3);
    _ = try model.add("Ponder", .check, "false", 0, 0, 0);
    _ = try model.add("EvalFile", .string, "nn-x.nnue", 0, 0, 7);

    try std.testing.expectEqual(@as(c_int, 1), model.getInt("Threads"));
    try std.testing.expectEqual(@as(c_int, 0), model.getInt("Ponder"));
    try std.testing.expectEqualStrings("nn-x.nnue", model.getString("EvalFile"));
    // Name lookup is case-insensitive, as in the C++ OptionsMap.
    try std.testing.expectEqual(@as(c_int, 1), model.getInt("threads"));
}

test "options model validates and applies setValue" {
    var model = OptionsModel.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.add("Threads", .spin, "1", 1, 1024, 3);
    _ = try model.add("Ponder", .check, "false", 0, 0, 0);

    const ok = try model.setValue("Threads", "8");
    try std.testing.expect(ok.found and ok.accepted and ok.changed);
    try std.testing.expectEqual(@as(u8, 3), ok.callback_kind);
    try std.testing.expectEqual(@as(c_int, 8), model.getInt("Threads"));

    // Out-of-range spin is rejected and leaves the value untouched.
    const low = try model.setValue("Threads", "0");
    try std.testing.expect(low.found and !low.accepted);
    try std.testing.expectEqual(@as(c_int, 8), model.getInt("Threads"));

    // Non-boolean check is rejected.
    const bad = try model.setValue("Ponder", "maybe");
    try std.testing.expect(bad.found and !bad.accepted);
    const good = try model.setValue("Ponder", "true");
    try std.testing.expect(good.accepted and good.changed);
    try std.testing.expectEqual(@as(c_int, 1), model.getInt("Ponder"));

    // Unknown option.
    const missing = try model.setValue("Nope", "1");
    try std.testing.expect(!missing.found);
}

test "options model renders the UCI listing in order" {
    var model = OptionsModel.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.add("Threads", .spin, "1", 1, 512, 3);
    _ = try model.add("Ponder", .check, "false", 0, 0, 0);
    _ = try model.add("SyzygyPath", .string, "", 0, 0, 6);
    _ = try model.add("Clear Hash", .button, "", 0, 0, 5);

    const listing = try model.renderAlloc();
    defer std.testing.allocator.free(listing);
    try std.testing.expectEqualStrings(
        "\noption name Threads type spin default 1 min 1 max 512" ++
            "\noption name Ponder type check default false" ++
            "\noption name SyzygyPath type string default <empty>" ++
            "\noption name Clear Hash type button",
        listing,
    );
}
