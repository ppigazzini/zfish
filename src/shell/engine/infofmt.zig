// Engine NUMA/thread info string builders.
//
// The pure formatters that render the "Available processors" / thread-binding /
// thread-allocation info lines from primitives (a CountPair array, a thread count,
// a binding string). Split out of engine.zig; they touch only std + the
// engine_util base leaf (allocMessage/CountPair), no engine graph, so no cycle.
// The threadBindingInformation/threadAllocationInformation gatherers that read the
// live ThreadPool + numa context stay in engine.zig and call these. engine.zig
// aliases the three (all internal callers).

const std = @import("std");
const engine_util = @import("engine_util");

const allocMessage = engine_util.allocMessage;
const CountPair = engine_util.CountPair;

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

test {
    @import("std").testing.refAllDecls(@This());
}
