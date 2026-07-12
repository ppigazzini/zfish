// The Zig-owned UCI option data model, split out of option.zig: the option
// kind/entry/outcome types, the OptionsModel store (add/setValue/getInt/render),
// the name->callback-kind mapping, and the standard-option reference fixture.
// Pure over std + the option_parse leaf (parseSignedInt / nameEquals); no global
// state and no dependency on the facade, so option.zig imports it acyclically.

const std = @import("std");
const testing = std.testing;
const option_parse = @import("option_parse.zig");
const parseSignedInt = option_parse.parseSignedInt;
const nameEquals = option_parse.nameEquals;

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

    // Index-keyed reads, for callers that carry a registration index rather than
    // a name.
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

    // Render the UCI option listing in registration order.
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

// Change-callback kinds, matching engine.zig's option_callback_* values.
pub const callback_none: u8 = 0;
pub const callback_debug_log_file: u8 = 1;
pub const callback_numa_policy: u8 = 2;
pub const callback_threads: u8 = 3;
pub const callback_hash: u8 = 4;
pub const callback_clear_hash: u8 = 5;
pub const callback_syzygy_path: u8 = 6;
pub const callback_eval_file: u8 = 7;

// The on-change callback kind for an option, keyed by its (canonical) name — the same
// mapping registerStandardOptions uses. The runtime registration path (addOption) does not
// carry the kind, so derive it here;
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
// by the caller, so this set stays in lockstep with engine.zig initBody.
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
    // Name lookup is case-insensitive.
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
        .eval_file = "nn-af1339a6dea3.nnue",
    });

    try std.testing.expectEqual(@as(usize, 19), model.count());
    try std.testing.expectEqual(@as(c_int, 1), model.getInt("Threads"));
    try std.testing.expectEqual(@as(c_int, 16), model.getInt("Hash"));
    try std.testing.expectEqual(@as(c_int, 1), model.getInt("MultiPV"));
    try std.testing.expectEqual(@as(c_int, 20), model.getInt("Skill Level"));
    try std.testing.expectEqual(@as(c_int, 1320), model.getInt("UCI_Elo"));
    try std.testing.expectEqual(@as(c_int, 0), model.getInt("Ponder"));
    try std.testing.expectEqual(@as(c_int, 1), model.getInt("Syzygy50MoveRule"));
    try std.testing.expectEqualStrings("nn-af1339a6dea3.nnue", model.getString("EvalFile"));
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
    try std.testing.expect(std.mem.endsWith(u8, listing, "\noption name EvalFile type string default nn-af1339a6dea3.nnue"));
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

test "OptionsModel add/setValue/renderAlloc unwind leak-free on every allocation failure" {
    // M19: OptionsModel.add dups three strings then appends to the entries vector --
    // the same create-then-append shape that leaked in state_list. checkAllAllocation
    // Failures fails each allocation in turn (the three dups, the vector growth,
    // setValue's re-dup, renderAlloc's buffer + per-entry allocPrints) and asserts every
    // unwind returns error.OutOfMemory while leaking nothing, exercising the errdefer
    // chains in add/normalize/renderAlloc on the high-traffic UCI options core.
    const Roundtrip = struct {
        fn run(a: std.mem.Allocator) !void {
            var model = OptionsModel.init(a);
            defer model.deinit();
            _ = try model.add("Threads", .spin, "1", 1, 1024, callback_threads);
            _ = try model.add("EvalFile", .string, "nn-x.nnue", 0, 0, callback_eval_file);
            _ = try model.add("Ponder", .check, "false", 0, 0, callback_none);
            _ = try model.setValue("Threads", "8");
            const listing = try model.renderAlloc();
            a.free(listing);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Roundtrip.run, .{});
}
