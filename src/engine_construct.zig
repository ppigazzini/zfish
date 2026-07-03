// Construction verifier for the Engine graph (harness H6, REPORT-09 big-bang plan).
//
// Stage 6 reconstructs Engine::Engine in Zig: numaContext(NumaConfig::from_system),
// the states deque, the LazyNumaReplicated network wrapper, the embedded
// ThreadPool, then the native init_body. The engine_off member offsets are already
// trusted (native accessors offset into the Engine), so this verifier checks the
// CONSTRUCTED STATE the native ctor must reproduce, not the offsets:
//   - from_system NUMA topology is sane: >= 1 node, and every node has >= 1 CPU
//     (a host-independent invariant -- an empty node means from_system mis-parsed);
//   - the network wrapper resolves instance[0] (prepare_replicate_from ran);
//   - the embedded ThreadPool is populated (>= 1 thread).
//
// Runs at the end of Engine::Engine (default build only), against the live C++
// engine. Read-only; panics on a mismatch. Models worker_construct.zig /
// thread_construct.zig.

const std = @import("std");
const graph_layout = @import("graph_layout.zig");

const eoff = graph_layout.engine_off;

fn readUsize(addr: usize) usize {
    return @as(*const usize, @ptrFromInt(addr)).*;
}

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("engine-graph construction: {s}\n", .{msg});
    @panic("Engine construction model mismatch");
}
