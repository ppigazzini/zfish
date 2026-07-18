// Build the engine info strings (ANNEX B.6): the numa/thread-binding/allocation UCI
// info formatters. Construct pure strings over numa + the thread pool; delegate
// the actual layout to engine_infofmt. No engine lifecycle/state here.

const std = @import("std");
const numa = @import("numa");
const engine_infofmt = @import("engine_infofmt");
const engine_util = @import("engine_util");
const engine_object = @import("engine_object");
const worker_layout = @import("worker_layout");

const CountPair = engine_util.CountPair;
const allocMessage = engine_util.allocMessage;
const formatNumaInfo = engine_infofmt.formatNumaInfo;
const formatThreadBinding = engine_infofmt.formatThreadBinding;
const formatThreadAllocation = engine_infofmt.formatThreadAllocation;

fn freeCString(ptr: [*:0]u8) void {
    std.heap.c_allocator.free(std.mem.span(ptr));
}

pub fn threadBindingInformation(
    numa_context: *const numa.NumaReplicationContext,
    threads: *worker_layout.ThreadPool,
) ?[*:0]u8 {
    const bound_count = threads.boundCount();
    if (bound_count == 0)
        return allocMessage("", .{});

    const allocator = std.heap.c_allocator;
    const node_count = numa.contextNodeCount(numa_context);

    const counts = allocator.alloc(usize, node_count) catch return null;
    defer allocator.free(counts);
    @memset(counts, 0);

    var index: usize = 0;
    while (index < bound_count) : (index += 1) {
        const node = threads.boundAt(index);
        if (node < node_count)
            counts[node] += 1;
    }

    const pairs = allocator.alloc(CountPair, node_count) catch return null;
    defer allocator.free(pairs);

    index = 0;
    while (index < node_count) : (index += 1) {
        pairs[index] = .{
            .current = counts[index],
            .total = numa.contextCpusInNode(numa_context, index),
        };
    }

    return formatThreadBinding(pairs.ptr, pairs.len);
}

pub fn threadAllocationInformation(
    numa_context: *const numa.NumaReplicationContext,
    threads: *worker_layout.ThreadPool,
) ?[*:0]u8 {
    const binding_ptr = threadBindingInformation(numa_context, threads) orelse return null;
    defer freeCString(binding_ptr);

    const binding = std.mem.span(binding_ptr);
    return formatThreadAllocation(threads.numThreads(), binding.ptr, binding.len);
}

pub fn numaConfigStringEngine(engine_ptr: *engine_object.EngineObject) ?[*:0]u8 {
    _ = engine_ptr;
    const config_ptr = numa.configString() orelse return null;
    defer freeCString(config_ptr);
    return allocMessage("{s}", .{std.mem.span(config_ptr)});
}

pub fn numaConfigInformationEngine(engine_ptr: *engine_object.EngineObject) ?[*:0]u8 {
    _ = engine_ptr;
    const config_ptr = numa.configString() orelse return null;
    defer freeCString(config_ptr);
    const config = std.mem.span(config_ptr);
    return formatNumaInfo(config.ptr, config.len);
}

pub fn threadBindingInformationEngine(engine_ptr: *engine_object.EngineObject) ?[*:0]u8 {
    return threadBindingInformation(
        engine_ptr.numaContextPtr(),
        engine_ptr.threadsPtr(),
    );
}

pub fn threadAllocationInformationEngine(engine_ptr: *engine_object.EngineObject) ?[*:0]u8 {
    return threadAllocationInformation(
        engine_ptr.numaContextPtr(),
        engine_ptr.threadsPtr(),
    );
}
