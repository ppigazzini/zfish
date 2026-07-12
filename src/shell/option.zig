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

// Read an option's integer value by name (0 if absent). Used by callers
// that carry an option name (e.g. the search driver's MultiPV / UCI_ShowWDL).
/// Read an integer option by name from the option model.
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
/// so the existing c.free still pairs), or null on OOM. allocSentinel is the
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
// all owned in Zig. It holds the option metadata and storage; the
// parse/validate/normalize logic lives in this
// file and is reused here. Verified by the tests at the bottom.
// ---------------------------------------------------------------------------

// The option data model (types + OptionsModel store + standard-option fixture)
// lives in the option_model leaf now; re-export its public surface and alias
// back what this facade calls so external + call sites stay unqualified.
const option_model = @import("option_model.zig");
pub const OptionKind = option_model.OptionKind;
pub const optionKindName = option_model.optionKindName;
pub const OptionEntry = option_model.OptionEntry;
pub const SetOutcome = option_model.SetOutcome;
pub const OptionsModel = option_model.OptionsModel;
pub const StandardOptionParams = option_model.StandardOptionParams;
pub const registerStandardOptions = option_model.registerStandardOptions;
pub const callbackKindForName = option_model.callbackKindForName;
pub const callback_none = option_model.callback_none;
pub const callback_debug_log_file = option_model.callback_debug_log_file;
pub const callback_numa_policy = option_model.callback_numa_policy;
pub const callback_threads = option_model.callback_threads;
pub const callback_hash = option_model.callback_hash;
pub const callback_clear_hash = option_model.callback_clear_hash;
pub const callback_syzygy_path = option_model.callback_syzygy_path;
pub const callback_eval_file = option_model.callback_eval_file;
