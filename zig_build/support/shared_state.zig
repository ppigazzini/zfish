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

// REPORT-10 M-HUB: the LIVE SharedState handed to the workers is now this native
// 40-byte struct, not the C++ Search::SharedState (which was just 5 references, no
// methods — byte-identical, proven by zfish_verify_shared_state_native). The bridge's
// zfish_search_shared_state_create routes here; the workers bind it by reference and
// read the same 5 pointers. This makes the SharedState a type-AGNOSTIC pointer bundle,
// so its member subsystems can become native types pointed-to (the dependency unblock).
// One engine, one search at a time (sequential go commands; the workers only READ the
// SharedState during a search), so a single static instance reproduces the C++
// new/delete lifetime without an allocator (keeps shared_state.zig libc-free for the
// test-graph artifact). The SharedState is rebuilt per search and never aliased.
var live_shared_state: SharedState = undefined;

export fn zfish_shared_state_native_create(
    options: *anyopaque,
    threads: *anyopaque,
    tt: *anyopaque,
    shared_histories: *anyopaque,
    network: *anyopaque,
) ?*anyopaque {
    live_shared_state = SharedState.init(options, threads, tt, shared_histories, network);
    return @ptrCast(&live_shared_state);
}

export fn zfish_shared_state_native_destroy(ss: ?*anyopaque) void {
    _ = ss; // static storage — nothing to free (lifetime is the static itself)
}

// Self-check: build a native SharedState from the same five referents the C++
// SharedState was constructed with and assert all 40 bytes match. Proves the
// native field order/layout reproduces the C++ SharedState the bridge constructs.
export fn zfish_verify_shared_state_native(
    cpp: ?*const anyopaque,
    options: ?*anyopaque,
    threads: ?*anyopaque,
    tt: ?*anyopaque,
    shared_histories: ?*anyopaque,
    network: ?*anyopaque,
) void {
    const cpp_bytes: [*]const u8 = @ptrCast(cpp orelse return);
    const ss = SharedState.init(
        options orelse return,
        threads orelse return,
        tt orelse return,
        shared_histories orelse return,
        network orelse return,
    );
    const native_bytes = std.mem.asBytes(&ss);
    for (native_bytes, 0..) |b, i| {
        if (b != cpp_bytes[i]) @panic("native SharedState does not match the C++ SharedState");
    }
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
