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

pub fn threadBindingInformation(
    gpa: std.mem.Allocator,
    numa_context: *const numa.NumaReplicationContext,
    threads: *worker_layout.ThreadPool,
) ?[]u8 {
    const bound_count = threads.boundCount();
    if (bound_count == 0)
        return allocMessage(gpa, "", .{});

    const allocator = gpa;
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

    return formatThreadBinding(gpa, pairs);
}

pub fn threadAllocationInformation(
    gpa: std.mem.Allocator,
    numa_context: *const numa.NumaReplicationContext,
    threads: *worker_layout.ThreadPool,
) ?[]u8 {
    const binding = threadBindingInformation(gpa, numa_context, threads) orelse return null;
    defer gpa.free(binding);

    return formatThreadAllocation(gpa, threads.numThreads(), binding);
}

// The four *Engine entries are what the UCI layer calls; each renders with the process
// allocator and hands the caller an owned slice to free.
const engine_gpa = std.heap.c_allocator;

pub fn numaConfigStringEngine(engine_ptr: *engine_object.EngineObject) ?[]u8 {
    return numa.contextConfigString(engine_ptr.numaContextPtr(), engine_gpa);
}

pub fn numaConfigInformationEngine(engine_ptr: *engine_object.EngineObject) ?[]u8 {
    const config = numaConfigStringEngine(engine_ptr) orelse return null;
    defer engine_gpa.free(config);
    return formatNumaInfo(engine_gpa, config);
}

pub fn threadBindingInformationEngine(engine_ptr: *engine_object.EngineObject) ?[]u8 {
    return threadBindingInformation(
        engine_gpa,
        engine_ptr.numaContextPtr(),
        engine_ptr.threadsPtr(),
    );
}

pub fn threadAllocationInformationEngine(engine_ptr: *engine_object.EngineObject) ?[]u8 {
    return threadAllocationInformation(
        engine_gpa,
        engine_ptr.numaContextPtr(),
        engine_ptr.threadsPtr(),
    );
}
