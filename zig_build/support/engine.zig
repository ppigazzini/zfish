const std = @import("std");

pub const CountPair = extern struct {
    current: usize,
    total: usize,
};

pub const ByteView = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

extern fn zfish_engine_states_reset(states: *anyopaque) *anyopaque;
extern fn zfish_engine_states_push(states: *anyopaque) *anyopaque;
extern fn zfish_engine_position_set(
    pos: *anyopaque,
    fen_ptr: [*]const u8,
    fen_len: usize,
    chess960_enabled: u8,
    state: *anyopaque,
) ?[*:0]u8;
extern fn zfish_engine_position_do_move(pos: *anyopaque, move_raw: u16, state: *anyopaque) void;
extern fn zfish_uci_to_move_raw(pos: *const anyopaque, text_ptr: [*]const u8, text_len: usize) u16;
extern fn zfish_move_none_raw() u16;
extern fn zfish_engine_threads_set_stop(threads: *anyopaque) void;
extern fn zfish_engine_threads_wait_finished(threads: *anyopaque) void;
extern fn zfish_engine_tt_clear(tt: *anyopaque, threads: *anyopaque) void;
extern fn zfish_engine_threads_clear(threads: *anyopaque) void;
extern fn zfish_engine_tablebases_init(path_ptr: [*]const u8, path_len: usize) void;

pub fn setPosition(
    pos: *anyopaque,
    states: *anyopaque,
    chess960_enabled: u8,
    fen_ptr: [*]const u8,
    fen_len: usize,
    moves_ptr: ?[*]const ByteView,
    move_count: usize,
) ?[*:0]u8 {
    const root_state = zfish_engine_states_reset(states);

    if (zfish_engine_position_set(pos, fen_ptr, fen_len, chess960_enabled, root_state)) |err| {
        return err;
    }

    const move_views = if (moves_ptr) |ptr| ptr[0..move_count] else &[_]ByteView{};
    const none_raw = zfish_move_none_raw();

    for (move_views) |view| {
        const move_text = if (view.ptr) |ptr| ptr[0..view.len] else "";
        const move_raw = if (view.ptr) |ptr| zfish_uci_to_move_raw(pos, ptr, view.len) else none_raw;

        if (move_raw == none_raw) {
            return allocMessage("Illegal move: {s}", .{move_text});
        }

        const next_state = zfish_engine_states_push(states);
        zfish_engine_position_do_move(pos, move_raw, next_state);
    }

    return null;
}

pub fn stop(threads: *anyopaque) void {
    zfish_engine_threads_set_stop(threads);
}

pub fn searchClear(threads: *anyopaque, tt: *anyopaque, syzygy_path: []const u8) void {
    zfish_engine_threads_wait_finished(threads);
    zfish_engine_tt_clear(tt, threads);
    zfish_engine_threads_clear(threads);
    zfish_engine_tablebases_init(syzygy_path.ptr, syzygy_path.len);
}

pub fn formatNumaInfo(config_ptr: [*]const u8, config_len: usize) ?[*:0]u8 {
    return allocMessage("Available processors: {s}", .{config_ptr[0..config_len]});
}

pub fn formatThreadBinding(pairs_ptr: [*]const CountPair, pair_count: usize) ?[*:0]u8 {
    if (pair_count == 0)
        return allocMessage("", .{});

    const allocator = std.heap.c_allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var index: usize = 0;
    while (index < pair_count) : (index += 1) {
        if (index != 0)
            buffer.append(allocator, ':') catch return null;
        const segment = std.fmt.allocPrint(
            allocator,
            "{d}/{d}",
            .{ pairs_ptr[index].current, pairs_ptr[index].total },
        ) catch return null;
        defer allocator.free(segment);
        buffer.appendSlice(allocator, segment) catch return null;
    }

    const owned = allocator.allocSentinel(u8, buffer.items.len, 0) catch return null;
    @memcpy(owned[0..buffer.items.len], buffer.items);
    return owned.ptr;
}

pub fn formatThreadAllocation(
    thread_count: usize,
    binding_ptr: [*]const u8,
    binding_len: usize,
) ?[*:0]u8 {
    const binding = binding_ptr[0..binding_len];
    if (binding.len == 0)
        return allocMessage(
            "Using {d} {s}",
            .{ thread_count, if (thread_count > 1) "threads" else "thread" },
        );

    return allocMessage(
        "Using {d} {s} with NUMA node thread binding: {s}",
        .{ thread_count, if (thread_count > 1) "threads" else "thread", binding },
    );
}

pub fn formatNetworkStatus(
    replica_index: usize,
    status: u8,
    error_ptr: [*]const u8,
    error_len: usize,
) ?[*:0]u8 {
    const error_text = error_ptr[0..error_len];
    const status_text = switch (status) {
        0 => "No allocation.",
        1 => "Local memory.",
        2 => "Shared memory.",
        else => "Unknown status.",
    };

    if (error_text.len == 0)
        return allocMessage("Network replica {d}: {s}", .{ replica_index, status_text });

    return allocMessage("Network replica {d}: {s} {s}", .{ replica_index, status_text, error_text });
}

fn allocMessage(comptime fmt: []const u8, args: anytype) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const rendered = std.fmt.allocPrint(allocator, fmt, args) catch return null;
    defer allocator.free(rendered);
    const owned = allocator.allocSentinel(u8, rendered.len, 0) catch return null;
    @memcpy(owned[0..rendered.len], rendered);
    return owned.ptr;
}
