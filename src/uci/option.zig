const std = @import("std");

// Process-global Zig OptionsModel: the live option store. Owns every option's
// metadata (type/min/max/default) and current value, keyed by the option's
// registration index, and serves both name- and index-keyed reads.
var global_model: ?OptionsModel = null;

fn ensureModel() *OptionsModel {
    if (global_model == null) global_model = OptionsModel.init(std.heap.c_allocator);
    return &(global_model.?);
}

pub fn addOption(name: []const u8, kind: u8, default: []const u8, min: c_int, max: c_int) usize {
    const model = ensureModel();
    const resolved: OptionKind = @enumFromInt(if (kind > 3) @as(u8, 0) else kind);
    return model.add(name, resolved, default, min, max, callbackKindForName(name)) catch
        std.math.maxInt(usize);
}

pub fn intByIndex(idx: usize) c_int {
    return ensureModel().intByIndex(idx);
}

// Read an option's integer value by name (0 if absent). Used by native callers
// that carry an option name (e.g. the search driver's MultiPV / UCI_ShowWDL).
/// Read an integer option by name from the native option model (M16.7).
pub fn intByName(name: []const u8) c_int {
    return ensureModel().getInt(name);
}
pub fn syzygyProbeDepth() c_int {
    return intByName("SyzygyProbeDepth");
}
pub fn syzygyProbeLimit() c_int {
    return intByName("SyzygyProbeLimit");
}
pub fn syzygy50MoveRule() bool {
    return intByName("Syzygy50MoveRule") != 0;
}
pub fn strByName(name: []const u8) []const u8 {
    return ensureModel().getString(name);
}
pub fn optionHash() usize {
    return @intCast(intByName("Hash"));
}
pub fn optionThreads() usize {
    return @intCast(intByName("Threads"));
}
pub fn uciChess960() bool {
    return intByName("UCI_Chess960") != 0;
}
/// A NUL-terminated copy of a string option (caller frees; c_allocator is libc-backed
/// so the existing c.free still pairs), or null on OOM. M19.0: allocSentinel is the
/// idiomatic NUL-terminated allocation -- it sizes len+1 and writes the sentinel.
pub fn dupCString(name: []const u8) ?[*:0]u8 {
    const s = strByName(name);
    const buf = std.heap.c_allocator.allocSentinel(u8, s.len, 0) catch return null;
    @memcpy(buf[0..s.len], s);
    return buf.ptr;
}
pub fn dupEvalFile() ?[*:0]u8 {
    return dupCString("EvalFile");
}
pub fn dupSyzygyPath() ?[*:0]u8 {
    return dupCString("SyzygyPath");
}
pub fn numaPolicyMode() u8 {
    const policy = strByName("NumaPolicy");
    if (std.mem.eql(u8, policy, "none")) return 0;
    if (std.mem.eql(u8, policy, "auto")) return 1;
    return 2;
}

pub fn currentLen(idx: usize) usize {
    return ensureModel().currentByIndex(idx).len;
}

pub fn currentPtr(idx: usize) ?[*]const u8 {
    const current = ensureModel().currentByIndex(idx);
    return if (current.len == 0) null else current.ptr;
}

pub const ModelSetResult = struct {
    found: u8,
    accepted: u8,
    changed: u8,
    callback_kind: u8,
    kind: u8,
    idx: usize,
};

// Apply a setoption assignment to the model: validate, normalize, and store.
// Reports whether the option exists, whether the value was accepted/changed,
// the change-callback kind, the option kind, and the index, so the caller can
// fire the on_change callback for the changed option.
pub fn setByName(name: []const u8, value: []const u8, out: *ModelSetResult) void {
    out.* = .{ .found = 0, .accepted = 0, .changed = 0, .callback_kind = 0, .kind = 0, .idx = 0 };
    const model = ensureModel();
    const idx = model.indexOf(name) orelse return;
    const kind_val: u8 = @intFromEnum(model.entries.items[idx].kind);
    const outcome = model.setValue(name, value) catch {
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

// Render the UCI option listing from the Zig model, as a malloc-backed C string
// the caller frees.
pub fn renderOptions() ?[*:0]u8 {
    const model = ensureModel();
    const listing = model.renderAlloc() catch return null;
    defer std.heap.c_allocator.free(listing);
    const buf = std.heap.c_allocator.allocSentinel(u8, listing.len, 0) catch return null;
    @memcpy(buf[0..listing.len], listing);
    return buf.ptr;
}

// UCI option-string parsing lives in the option_parse leaf now; re-export the
// public entry points + result types and alias back the helpers the model and
// facade below reuse, so every call site stays unqualified.
const option_parse = @import("option_parse.zig");
pub const ParsedSetOption = option_parse.ParsedSetOption;
pub const AssignmentResult = option_parse.AssignmentResult;
pub const TuneNextResult = option_parse.TuneNextResult;
pub const parseSetOption = option_parse.parseSetOption;
pub const validateAssignment = option_parse.validateAssignment;
pub const tuneNext = option_parse.tuneNext;
pub const comboEquals = option_parse.comboEquals;
pub const tuneShouldMakeOption = option_parse.tuneShouldMakeOption;
const caseInsensitiveLess = option_parse.caseInsensitiveLess;
const parseSignedInt = option_parse.parseSignedInt;
const nameEquals = option_parse.nameEquals;

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

// ---- property fuzz (M17.0d) --------------------------------------------------
// The pure UCI parsers are the most fuzz-appropriate surface in the engine (a
// tokenizer bolted to a validator). Until coverage-guided `-ffuzz` is wired
// (M17.5), these PRNG property tests hammer them with random + adversarial input
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
        "setoption name Hash value 999999999999999999999999999", "setoption name " ++ "A" ** 300 ++ " value " ++ "B" ** 300,
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
        // irreflexive: never a < a
        try testing.expect(!caseInsensitiveLess(sa, sa));
        // asymmetric: not both a < b and b < a
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
