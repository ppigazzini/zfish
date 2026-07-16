// Register engine options with these helpers.
//
// Wrap the add{String,Check,Spin,Button}Option wrappers + the engineAddOption core that
// register the UCI options into the OptionsModel. Call these only from
// engine.zig's initBody; they touch only std + the option module, so they extract
// to a leaf with no cycle. engine.zig aliases the four add*Option helpers for
// initBody. (The option_callback_* constants stay in engine.zig -- its
// optionOnChange dispatch owns them; the callback_kind is passed in as a byte.)

const std = @import("std");
const option_port = @import("option");

const option_kind_string: u8 = 0;
const option_kind_check: u8 = 1;
const option_kind_spin: u8 = 2;
const option_kind_button: u8 = 3;
const option_callback_none: u8 = 0;

fn engineAddOption(
    name_ptr: [*]const u8,
    name_len: usize,
    option_kind: u8,
    default_ptr: [*]const u8,
    default_len: usize,
    default_value: c_int,
    min_value: c_int,
    max_value: c_int,
    callback_kind: u8,
) void {
    _ = callback_kind;
    var buf: [16]u8 = undefined;
    const default_slice: []const u8 = switch (option_kind) {
        1 => if (default_value != 0) "true" else "false", // check
        2 => std.fmt.bufPrint(&buf, "{d}", .{default_value}) catch unreachable, // spin
        3 => "", // button
        0 => default_ptr[0..default_len], // string
        else => @panic("engineAddOption: bad option kind"),
    };
    _ = option_port.addOption(name_ptr[0..name_len], option_kind, default_slice, min_value, max_value);
}

pub fn addStringOption(name: []const u8, default_value: []const u8, callback_kind: u8) void {
    engineAddOption(
        name.ptr,
        name.len,
        option_kind_string,
        default_value.ptr,
        default_value.len,
        0,
        0,
        0,
        callback_kind,
    );
}

pub fn addCheckOption(name: []const u8, default_value: u8) void {
    engineAddOption(
        name.ptr,
        name.len,
        option_kind_check,
        "".ptr,
        0,
        default_value,
        0,
        0,
        option_callback_none,
    );
}

pub fn addSpinOption(
    name: []const u8,
    default_value: c_int,
    min_value: c_int,
    max_value: c_int,
    callback_kind: u8,
) void {
    engineAddOption(
        name.ptr,
        name.len,
        option_kind_spin,
        "".ptr,
        0,
        default_value,
        min_value,
        max_value,
        callback_kind,
    );
}

pub fn addButtonOption(name: []const u8, callback_kind: u8) void {
    engineAddOption(
        name.ptr,
        name.len,
        option_kind_button,
        "".ptr,
        0,
        0,
        0,
        0,
        callback_kind,
    );
}

test {
    @import("std").testing.refAllDecls(@This());
}
