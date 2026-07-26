// Build the engine NUMA/thread info strings.
//
// Render the "Available processors" / thread-binding / thread-allocation info lines
// from primitives (a CountPair array, a thread count, a binding string) with pure
// formatters. Split out of engine.zig; they touch only std + the engine_util base leaf
// (allocMessage/CountPair), no engine graph, so no cycle. Keep the
// threadBindingInformation/threadAllocationInformation gatherers that read the live
// ThreadPool + numa context in engine.zig, calling these. engine.zig aliases the three
// (all internal callers).

const std = @import("std");
const engine_util = @import("engine_util");

const allocMessage = engine_util.allocMessage;
const CountPair = engine_util.CountPair;

pub fn formatNumaInfo(gpa: std.mem.Allocator, config: []const u8) ?[]u8 {
    return allocMessage(gpa, "Available processors: {s}", .{config});
}

pub fn formatThreadBinding(gpa: std.mem.Allocator, pairs: []const CountPair) ?[]u8 {
    if (pairs.len == 0)
        return allocMessage(gpa, "", .{});

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(gpa);

    for (pairs, 0..) |pair, index| {
        if (index != 0)
            buffer.append(gpa, ':') catch return null;
        buffer.print(gpa, "{d}/{d}", .{ pair.current, pair.total }) catch return null;
    }

    return buffer.toOwnedSlice(gpa) catch null;
}

pub fn formatThreadAllocation(
    gpa: std.mem.Allocator,
    thread_count: usize,
    binding: []const u8,
) ?[]u8 {
    if (binding.len == 0)
        return allocMessage(
            gpa,
            "Using {d} {s}",
            .{ thread_count, if (thread_count > 1) "threads" else "thread" },
        );

    return allocMessage(
        gpa,
        "Using {d} {s} with NUMA node thread binding: {s}",
        .{ thread_count, if (thread_count > 1) "threads" else "thread", binding },
    );
}

test {
    @import("std").testing.refAllDecls(@This());
}
