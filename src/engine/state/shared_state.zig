// Bundle the references the Engine hands every Worker at construction (thread pool,
// transposition table, per-NUMA shared histories), as typed pointers into the
// Zig-owned subsystems.
//
// Expose only the *generic* `SharedStateOf(comptime …)` and stay a pure std-only
// leaf: never import ThreadPool / TranspositionTable / SharedHistoriesMap.
// Instantiate the concrete `SharedState = SharedStateOf(…)` once at the root that
// sees all the referent types — support/engine.zig — which also owns the live static +
// create/destroy.

const std = @import("std");

/// Build the SharedState bundle, generic over its three referent types: three typed
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

        // Bind the three live references the worker actually uses; options
        // and network are read elsewhere (the global OptionsModel + the FT
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

        /// Return a typed view over the *anyopaque worker-build boundary that main.zig's
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

    // Round-trip the bundle address back to the typed view via fromPtr.
    const view = SS.fromPtr(@ptrCast(&ss));
    try testing.expectEqual(&tt, view.tt);
}
