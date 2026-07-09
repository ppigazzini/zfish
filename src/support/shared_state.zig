// Native Zig SharedState — the bundle of references the Engine hands every Worker at
// construction (options, thread pool, transposition table, per-NUMA shared histories,
// network). In C++ these are five references; natively they are five typed pointers
// into the Zig-owned subsystems.
//
// M18.5 — CALL-SITE TYPE INJECTION (idiomatic Zig DI). This module exposes only the
// *generic* `SharedStateOf(comptime …)` and stays a **pure std-only leaf**: it never
// imports OptionsModel / ThreadPool / TranspositionTable / SharedHistoriesMap /
// Network, so it cannot sit in a module cycle (the referent modules reach graph_layout,
// which used to reach back here). The concrete `SharedState = SharedStateOf(…)` is
// instantiated once at the root that sees all five types — support/engine.zig — which
// also owns the live static + create/destroy. See REPORT-17 Annex A. This mirrors the
// tree's existing `shared_histories_map.SharedHistoriesMapOf(comptime Entry)` pattern.

const std = @import("std");

/// The 40-byte SharedState bundle, generic over its five referent types. Five
/// pointers in source order → byte-identical to the old 5×*anyopaque struct (the
/// engine asserts @sizeOf == 40 at the instantiation), so the worker-build reinterpret
/// is unchanged.
pub fn SharedStateOf(
    comptime Options: type,
    comptime Threads: type,
    comptime TranspositionTable: type,
    comptime Histories: type,
    comptime Network: type,
) type {
    return struct {
        options: *Options, // @0
        threads: *Threads, // @8
        tt: *TranspositionTable, // @16
        shared_histories: *Histories, // @24
        network: *Network, // @32

        const Self = @This();

        pub fn init(
            options: *Options,
            threads: *Threads,
            tt: *TranspositionTable,
            shared_histories: *Histories,
            network: *Network,
        ) Self {
            return .{
                .options = options,
                .threads = threads,
                .tt = tt,
                .shared_histories = shared_histories,
                .network = network,
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

test "SharedStateOf reproduces the 40-byte footprint and binds typed references" {
    // Instantiate with a mock referent type; the layout is five pointers regardless.
    const Mock = u32;
    const SS = SharedStateOf(Mock, Mock, Mock, Mock, Mock);
    try testing.expectEqual(@as(usize, 40), @sizeOf(SS));
    try testing.expectEqual(@as(usize, 0), @offsetOf(SS, "options"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(SS, "threads"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(SS, "tt"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(SS, "shared_histories"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(SS, "network"));

    var options: Mock = 1;
    var threads: Mock = 2;
    var tt: Mock = 3;
    var hists: Mock = 4;
    var network: Mock = 5;

    const ss = SS.init(&options, &threads, &tt, &hists, &network);
    try testing.expectEqual(&options, ss.options);
    try testing.expectEqual(&network, ss.network);
    try testing.expectEqual(@as(u32, 3), ss.tt.*);

    // fromPtr round-trips the bundle address back to the typed view.
    const view = SS.fromPtr(@ptrCast(&ss));
    try testing.expectEqual(&tt, view.tt);
}
