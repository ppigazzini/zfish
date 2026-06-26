const std = @import("std");

// Zig-owned option value store. The C++ OptionsMap still owns option metadata
// (type/min/max/default) and the setoption write path, but the live current
// value of every option is mirrored here, keyed by the Option's registration
// index, and the bridge's Option read operators source their value from this
// store in the default target. This moves option-read authority out of the C++
// object as the first slice of retiring OptionsMap; the legacy oracle keeps
// reading the C++ currentValue, so oracle-parity cross-checks the two.
// Process-global Zig OptionsModel, the live option store for the default build.
// The bridge registers every option here at OptionsMap::add (in lockstep with
// the C++ insert order, so indices match) and reads current values back through
// the index-keyed accessors. The C++ currentValue remains the legacy oracle, so
// oracle-parity cross-checks the two.
var global_model: ?OptionsModel = null;

fn ensureModel() *OptionsModel {
    if (global_model == null) global_model = OptionsModel.init(std.heap.c_allocator);
    return &(global_model.?);
}

pub export fn zfish_optmodel_reset() void {
    if (global_model) |*existing| existing.deinit();
    global_model = OptionsModel.init(std.heap.c_allocator);
}

pub export fn zfish_optmodel_add(
    name_ptr: [*]const u8,
    name_len: usize,
    kind: u8,
    default_ptr: [*]const u8,
    default_len: usize,
    min: c_int,
    max: c_int,
) usize {
    const model = ensureModel();
    const resolved: OptionKind = @enumFromInt(if (kind > 3) @as(u8, 0) else kind);
    const name = name_ptr[0..name_len];
    return model.add(name, resolved, default_ptr[0..default_len], min, max, callbackKindForName(name)) catch
        std.math.maxInt(usize);
}

pub export fn zfish_optmodel_has_index(idx: usize) u8 {
    return @intFromBool(ensureModel().hasIndex(idx));
}

pub export fn zfish_optmodel_int_by_index(idx: usize) c_int {
    return ensureModel().intByIndex(idx);
}

// Read an option's integer value by name (0 if absent). Used by native callers
// that carry an option name (e.g. the search driver's MultiPV / UCI_ShowWDL).
pub export fn zfish_optmodel_int_by_name(name_ptr: [*]const u8, name_len: usize) c_int {
    return ensureModel().getInt(name_ptr[0..name_len]);
}

// Read an option's current string value by name (M-FINAL: the native replacement for the
// OptionsMap[] string reads — NumaPolicy / SyzygyPath / EvalFile). Returns the model's own
// slice (no allocation); writes the length to out_len. Empty/absent → len 0.
pub export fn zfish_optmodel_string_by_name(name_ptr: [*]const u8, name_len: usize, out_len: *usize) [*]const u8 {
    const s = ensureModel().getString(name_ptr[0..name_len]);
    out_len.* = s.len;
    return s.ptr;
}

pub export fn zfish_optmodel_current_len(idx: usize) usize {
    return ensureModel().currentByIndex(idx).len;
}

pub export fn zfish_optmodel_current_ptr(idx: usize) ?[*]const u8 {
    const current = ensureModel().currentByIndex(idx);
    return if (current.len == 0) null else current.ptr;
}

pub const ModelSetResult = extern struct {
    found: u8,
    accepted: u8,
    changed: u8,
    callback_kind: u8,
    kind: u8,
    idx: usize,
};

// Apply a setoption assignment to the model: validate, normalize, and store.
// Reports whether the option exists, whether the value was accepted/changed,
// the change-callback kind, the option kind, and the index, so the bridge can
// fire the on_change callback exactly as the C++ Option operator= would.
pub export fn zfish_optmodel_set_by_name(
    name_ptr: [*]const u8,
    name_len: usize,
    value_ptr: [*]const u8,
    value_len: usize,
    out: *ModelSetResult,
) void {
    out.* = .{ .found = 0, .accepted = 0, .changed = 0, .callback_kind = 0, .kind = 0, .idx = 0 };
    const model = ensureModel();
    const name = name_ptr[0..name_len];
    const idx = model.indexOf(name) orelse return;
    const kind_val: u8 = @intFromEnum(model.entries.items[idx].kind);
    const outcome = model.setValue(name, value_ptr[0..value_len]) catch {
        out.* = .{ .found = 1, .accepted = 0, .changed = 0, .callback_kind = 0, .kind = kind_val, .idx = idx };
        return;
    };
    out.* = .{
        .found = 1,
        .accepted = @intFromBool(outcome.accepted),
        .changed = @intFromBool(outcome.changed),
        .callback_kind = outcome.callback_kind,
        .kind = kind_val,
        .idx = idx,
    };
}

// Render the UCI option listing (the C++ OptionsMap operator<< output) from the
// Zig model, as a malloc-backed C string the caller frees.
pub export fn zfish_optmodel_render() ?[*:0]u8 {
    const model = ensureModel();
    const listing = model.renderAlloc() catch return null;
    defer std.heap.c_allocator.free(listing);
    const buf = std.heap.c_allocator.allocSentinel(u8, listing.len, 0) catch return null;
    @memcpy(buf[0..listing.len], listing);
    return buf.ptr;
}

// Overwrite the current value at an index without re-validating (the C++ side
// has already validated); used to resync the model after a setoption applies.
pub export fn zfish_optmodel_publish_by_index(idx: usize, value_ptr: [*]const u8, value_len: usize) void {
    const model = ensureModel();
    if (idx >= model.entries.items.len) return;
    const entry = &model.entries.items[idx];
    const buf = std.heap.c_allocator.alloc(u8, value_len) catch return;
    @memcpy(buf, value_ptr[0..value_len]);
    model.allocator.free(entry.current_value);
    entry.current_value = buf;
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

        // UCI grammar: `setoption name <id…> value <val…>`. The first token ("setoption") was
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

    pub fn indexOf(self: *const OptionsModel, name: []const u8) ?usize {
        return self.findIndex(name);
    }

    pub fn kindByIndex(self: *const OptionsModel, idx: usize) ?OptionKind {
        if (idx < self.entries.items.len) return self.entries.items[idx].kind;
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
        if (self.findIndex(name)) |i| return self.intByIndex(i);
        return 0;
    }

    // Index-keyed reads, used by the bridge Option read operators which carry a
    // registration index rather than a name.
    pub fn hasIndex(self: *const OptionsModel, idx: usize) bool {
        return idx < self.entries.items.len;
    }

    pub fn currentByIndex(self: *const OptionsModel, idx: usize) []const u8 {
        if (idx < self.entries.items.len) return self.entries.items[idx].current_value;
        return "";
    }

    pub fn intByIndex(self: *const OptionsModel, idx: usize) c_int {
        if (idx < self.entries.items.len) {
            const entry = self.entries.items[idx];
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

// Change-callback kinds, matching the bridge's kOptionCallback* constants and
// engine.zig's option_callback_* values.
pub const callback_none: u8 = 0;
pub const callback_debug_log_file: u8 = 1;
pub const callback_numa_policy: u8 = 2;
pub const callback_threads: u8 = 3;
pub const callback_hash: u8 = 4;
pub const callback_clear_hash: u8 = 5;
pub const callback_syzygy_path: u8 = 6;
pub const callback_eval_file: u8 = 7;

// The on-change callback kind for an option, keyed by its (canonical) name — the same
// mapping registerStandardOptions uses. The runtime registration path (C++ OptionsMap::add →
// zfish_optmodel_register → zfish_optmodel_add) does not carry the kind, so derive it here;
// otherwise every option registers with callback_none and setoption never fires the engine
// callbacks (resize threads / TT / reload net / numa), i.e. options take no effect.
pub fn callbackKindForName(name: []const u8) u8 {
    if (nameEquals(name, "Debug Log File")) return callback_debug_log_file;
    if (nameEquals(name, "NumaPolicy")) return callback_numa_policy;
    if (nameEquals(name, "Threads")) return callback_threads;
    if (nameEquals(name, "Hash")) return callback_hash;
    if (nameEquals(name, "Clear Hash")) return callback_clear_hash;
    if (nameEquals(name, "SyzygyPath")) return callback_syzygy_path;
    if (nameEquals(name, "EvalFile")) return callback_eval_file;
    return callback_none;
}

pub const StandardOptionParams = struct {
    max_threads: c_int,
    max_hash_mb: c_int,
    skill_lowest_elo: c_int,
    skill_highest_elo: c_int,
    eval_file: []const u8,
};

// Register the standard UCI option set into a fresh model, in the same order
// and with the same defaults, bounds, and callback kinds as engine.zig initBody.
// The machine-dependent Threads/Hash maxima and the eval-file name are supplied
// by the caller, so the Zig engine and the C++ initBody stay in lockstep.
pub fn registerStandardOptions(model: *OptionsModel, params: StandardOptionParams) !void {
    var elo_buf: [16]u8 = undefined;
    const elo_default = std.fmt.bufPrint(&elo_buf, "{d}", .{params.skill_lowest_elo}) catch unreachable;

    _ = try model.add("Debug Log File", .string, "", 0, 0, callback_debug_log_file);
    _ = try model.add("NumaPolicy", .string, "auto", 0, 0, callback_numa_policy);
    _ = try model.add("Threads", .spin, "1", 1, params.max_threads, callback_threads);
    _ = try model.add("Hash", .spin, "16", 1, params.max_hash_mb, callback_hash);
    _ = try model.add("Clear Hash", .button, "", 0, 0, callback_clear_hash);
    _ = try model.add("Ponder", .check, "false", 0, 0, callback_none);
    _ = try model.add("MultiPV", .spin, "1", 1, 256, callback_none);
    _ = try model.add("Skill Level", .spin, "20", 0, 20, callback_none);
    _ = try model.add("Move Overhead", .spin, "10", 0, 5000, callback_none);
    _ = try model.add("nodestime", .spin, "0", 0, 10000, callback_none);
    _ = try model.add("UCI_Chess960", .check, "false", 0, 0, callback_none);
    _ = try model.add("UCI_LimitStrength", .check, "false", 0, 0, callback_none);
    _ = try model.add("UCI_Elo", .spin, elo_default, params.skill_lowest_elo, params.skill_highest_elo, callback_none);
    _ = try model.add("UCI_ShowWDL", .check, "false", 0, 0, callback_none);
    _ = try model.add("SyzygyPath", .string, "", 0, 0, callback_syzygy_path);
    _ = try model.add("SyzygyProbeDepth", .spin, "1", 1, 100, callback_none);
    _ = try model.add("Syzygy50MoveRule", .check, "true", 0, 0, callback_none);
    _ = try model.add("SyzygyProbeLimit", .spin, "7", 0, 7, callback_none);
    _ = try model.add("EvalFile", .string, params.eval_file, 0, 0, callback_eval_file);
}

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

test "standard option set matches engine init" {
    var model = OptionsModel.init(std.testing.allocator);
    defer model.deinit();
    try registerStandardOptions(&model, .{
        .max_threads = 1024,
        .max_hash_mb = 33554432,
        .skill_lowest_elo = 1320,
        .skill_highest_elo = 3190,
        .eval_file = "nn-83a0d6daf7e5.nnue",
    });

    try std.testing.expectEqual(@as(usize, 19), model.count());
    try std.testing.expectEqual(@as(c_int, 1), model.getInt("Threads"));
    try std.testing.expectEqual(@as(c_int, 16), model.getInt("Hash"));
    try std.testing.expectEqual(@as(c_int, 1), model.getInt("MultiPV"));
    try std.testing.expectEqual(@as(c_int, 20), model.getInt("Skill Level"));
    try std.testing.expectEqual(@as(c_int, 1320), model.getInt("UCI_Elo"));
    try std.testing.expectEqual(@as(c_int, 0), model.getInt("Ponder"));
    try std.testing.expectEqual(@as(c_int, 1), model.getInt("Syzygy50MoveRule"));
    try std.testing.expectEqualStrings("nn-83a0d6daf7e5.nnue", model.getString("EvalFile"));
    try std.testing.expectEqualStrings("auto", model.getString("NumaPolicy"));

    // Callback wiring survives registration.
    const threads_change = try model.setValue("Threads", "4");
    try std.testing.expectEqual(callback_threads, threads_change.callback_kind);
    const hash_change = try model.setValue("Hash", "256");
    try std.testing.expectEqual(callback_hash, hash_change.callback_kind);

    // The listing leads with Debug Log File and ends with EvalFile.
    const listing = try model.renderAlloc();
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.startsWith(u8, listing, "\noption name Debug Log File type string default <empty>"));
    try std.testing.expect(std.mem.indexOf(u8, listing, "\noption name Threads type spin default 1 min 1 max 1024") != null);
    try std.testing.expect(std.mem.endsWith(u8, listing, "\noption name EvalFile type string default nn-83a0d6daf7e5.nnue"));
}

test "options model index-keyed reads track current values" {
    var model = OptionsModel.init(std.testing.allocator);
    defer model.deinit();
    const threads_idx = try model.add("Threads", .spin, "1", 1, 1024, 3);
    const eval_idx = try model.add("EvalFile", .string, "nn-x.nnue", 0, 0, 7);

    try std.testing.expect(model.hasIndex(threads_idx));
    try std.testing.expect(model.hasIndex(eval_idx));
    try std.testing.expect(!model.hasIndex(2));

    try std.testing.expectEqual(@as(c_int, 1), model.intByIndex(threads_idx));
    try std.testing.expectEqualStrings("nn-x.nnue", model.currentByIndex(eval_idx));

    _ = try model.setValue("Threads", "12");
    try std.testing.expectEqual(@as(c_int, 12), model.intByIndex(threads_idx));
    try std.testing.expectEqualStrings("12", model.currentByIndex(threads_idx));
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
