const std = @import("std");

pub const CountPair = extern struct {
    current: usize,
    total: usize,
};

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
