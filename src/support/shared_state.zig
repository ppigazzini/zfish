// Native Zig SharedState.
//
// Part of the post-src/ object graph: the bundle of references the Engine hands
// to every Worker at construction (options, thread pool, transposition table,
// the per-NUMA shared histories, and the network). In C++ these are five
// references; natively they are five pointers into the Zig-owned subsystems
// (OptionsModel, ThreadPool, TranspositionTable, shared histories, network).
// Matches the locked 40-byte SharedState footprint.

const std = @import("std");

pub const SharedState = struct {
    options: *anyopaque, // OptionsModel   @0
    threads: *anyopaque, // ThreadPool     @8
    tt: *anyopaque, // TranspositionTable  @16
    shared_histories: *anyopaque, // per-NUMA SharedHistories @24
    network: *anyopaque, //                @32

    pub fn init(
        options: *anyopaque,
        threads: *anyopaque,
        tt: *anyopaque,
        shared_histories: *anyopaque,
        network: *anyopaque,
    ) SharedState {
        return .{
            .options = options,
            .threads = threads,
            .tt = tt,
            .shared_histories = shared_histories,
            .network = network,
        };
    }
};

comptime {
    // Native struct (M16.8 de-mirror). The worker-build path (main.zig
    // nativeWorkerBuild / sharedStateClearHistories / sharedStateInsertHistory)
    // reads this bundle by raw offset across the *anyopaque worker-build boundary,
    // so guard the pointer layout: five equal-alignment pointers keep source order,
    // and this asserts it loudly rather than corrupting silently if that changes.
    std.debug.assert(@sizeOf(SharedState) == 40);
    std.debug.assert(@offsetOf(SharedState, "options") == 0);
    std.debug.assert(@offsetOf(SharedState, "threads") == 8);
    std.debug.assert(@offsetOf(SharedState, "tt") == 16);
    std.debug.assert(@offsetOf(SharedState, "shared_histories") == 24);
    std.debug.assert(@offsetOf(SharedState, "network") == 32);
}

// The LIVE SharedState handed to the workers is this native 40-byte struct,
// byte-identical to the 5-reference C++ Search::SharedState it replaced (5
// references, no methods). The workers bind it by reference and read the same 5
// pointers. This makes the SharedState a type-AGNOSTIC pointer bundle, so its
// member subsystems can become native types pointed-to (the dependency unblock).
// One engine, one search at a time (sequential go commands; the workers only READ
// the SharedState during a search), so a single static instance reproduces the
// new/delete lifetime without an allocator (keeps shared_state.zig libc-free for
// the test-graph artifact). The SharedState is rebuilt per search and never aliased.
var live_shared_state: SharedState = undefined;

// Build the live SharedState from the five referents and return it (M16.7: engine.zig
// calls this directly instead of the former main.zig C-ABI wrapper). Rebuilt per search.
pub fn create(
    options: *anyopaque,
    threads: *anyopaque,
    tt: *anyopaque,
    shared_histories: *anyopaque,
    network: *anyopaque,
) ?*anyopaque {
    live_shared_state = SharedState.init(options, threads, tt, shared_histories, network);
    return @ptrCast(&live_shared_state);
}

pub fn destroy(ss: ?*anyopaque) void {
    _ = ss; // static storage — nothing to free (lifetime is the static itself)
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "SharedState reproduces the C++ footprint and binds references" {
    try testing.expectEqual(@as(usize, 40), @sizeOf(SharedState));

    var options: u32 = 1;
    var threads: u32 = 2;
    var tt: u32 = 3;
    var hists: u32 = 4;
    var network: u32 = 5;

    const ss = SharedState.init(&options, &threads, &tt, &hists, &network);
    try testing.expectEqual(@as(*anyopaque, &options), ss.options);
    try testing.expectEqual(@as(*anyopaque, &network), ss.network);
    try testing.expectEqual(@as(u32, 3), @as(*const u32, @ptrCast(@alignCast(ss.tt))).*);
}
