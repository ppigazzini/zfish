// Native Zig SharedState.
//
// Part of the post-src/ object graph: the bundle of references the Engine hands
// to every Worker at construction (options, thread pool, transposition table,
// the per-NUMA shared histories, and the network). In C++ these are five
// references; natively they are five pointers into the Zig-owned subsystems
// (OptionsModel, ThreadPool, TranspositionTable, shared histories, network).
// Matches the locked 40-byte SharedState footprint.

const std = @import("std");

pub const SharedState = extern struct {
    options: *anyopaque, // OptionsModel
    threads: *anyopaque, // ThreadPool
    tt: *anyopaque, // TranspositionTable
    shared_histories: *anyopaque, // per-NUMA SharedHistories
    network: *anyopaque,

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
    std.debug.assert(@sizeOf(SharedState) == 40);
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
