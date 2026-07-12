// Native Zig SharedState — the bundle of references the Engine hands every Worker at
// construction (thread pool, transposition table, per-NUMA shared histories), as typed
// pointers into the Zig-owned subsystems.
//
// This module exposes only the *generic* `SharedStateOf(comptime …)` and stays a pure
// std-only leaf: it never imports ThreadPool / TranspositionTable / SharedHistoriesMap.
// The concrete `SharedState = SharedStateOf(…)` is instantiated once at the root that
// sees all the referent types — support/engine.zig — which also owns the live static +
// create/destroy.

const std = @import("std");

/// The SharedState bundle, generic over its three referent types: three typed
/// pointers in source order.
pub fn SharedStateOf(
    comptime Threads: type,
    comptime TranspositionTable: type,
    comptime Histories: type,
) type {
    return struct {
        threads: *Threads, // @0
        tt: *TranspositionTable, // @8
        shared_histories: *Histories, // @16

        const Self = @This();

        // The bundle is the three live references the worker actually binds; options
        // and network are read elsewhere (the global OptionsModel + the native FT
        // storage), not through SharedState.
        pub fn init(
            threads: *Threads,
            tt: *TranspositionTable,
            shared_histories: *Histories,
        ) Self {
            return .{
                .threads = threads,
                .tt = tt,
                .shared_histories = shared_histories,
            };
        }

        /// Typed view over the *anyopaque worker-build boundary that main.zig's native
        /// hook impls cross to read the referents. The engine's concrete instantiation
        /// is the single definition, so the view and the owner cannot drift.
        pub inline fn fromPtr(p: *const anyopaque) *Self {
            return @ptrCast(@alignCast(@constCast(p)));
        }
    };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "SharedStateOf reproduces the 24-byte footprint and binds typed references" {
    // Instantiate with a mock referent type; the layout is three pointers regardless.
    const Mock = u32;
    const SS = SharedStateOf(Mock, Mock, Mock);
    try testing.expectEqual(@as(usize, 24), @sizeOf(SS));
    try testing.expectEqual(@as(usize, 0), @offsetOf(SS, "threads"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(SS, "tt"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(SS, "shared_histories"));

    var threads: Mock = 2;
    var tt: Mock = 3;
    var hists: Mock = 4;

    const ss = SS.init(&threads, &tt, &hists);
    try testing.expectEqual(&threads, ss.threads);
    try testing.expectEqual(&hists, ss.shared_histories);
    try testing.expectEqual(@as(u32, 3), ss.tt.*);

    // fromPtr round-trips the bundle address back to the typed view.
    const view = SS.fromPtr(@ptrCast(&ss));
    try testing.expectEqual(&tt, view.tt);
}
