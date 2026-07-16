//! hook-class: lifecycle — worker build/destroy/clear and setup-state handoff.
//! Structurally safe: a lifecycle hook cannot become per-query without the design
//! changing shape, so unlike the service hooks it carries no per-node cost risk.

// Runtime hook registry: a fn-pointer table that breaks module import
// cycles between the runtime hooks and their implementations.
//
// The impls live in main.zig because they need position/engine/network/search/... —
// modules that already import their callers (thread/engine/search_thread/
// thread_pool), so the callers can't import back to reach them. main installs
// the pointers at startup (installRuntimeHooks); the callers invoke through here.
// Pure Zig fn pointers -- no C ABI, type-checked.
//
// The fields are NON-OPTIONAL, each defaulting to a named panic stub, so the
// callers invoke them directly (no `.?` null-unwrap at 10+ sites). A hook that was
// never registered fails fast with its own name instead of an opaque null-optional
// panic -- the failure mode (a test that skipped installRuntimeHooks) now
// reports exactly which hook is missing.

const worker_layout = @import("worker_layout");
const position_types = @import("position_types");

fn hookPanic(comptime name: []const u8) noreturn {
    @panic(name ++ ": runtime hook not registered (installRuntimeHooks not run?)");
}

/// failure: loud — hookPanic naming the hook. These 11 are LIFECYCLE (worker build/destroy/clear, setup-state handoff): structurally safe, since they cannot become per-query without the design changing shape.
pub var worker_build: *const fn (ctx: ?*anyopaque, idx: usize, thread: *anyopaque) void =
    struct {
        fn stub(_: ?*anyopaque, _: usize, _: *anyopaque) void {
            hookPanic("worker_build");
        }
    }.stub;
/// failure: loud — hookPanic naming the hook. These 11 are LIFECYCLE (worker build/destroy/clear, setup-state handoff): structurally safe, since they cannot become per-query without the design changing shape.
pub var worker_destroy: *const fn (worker: *anyopaque) void =
    struct {
        fn stub(_: *anyopaque) void {
            hookPanic("worker_destroy");
        }
    }.stub;
/// failure: loud — hookPanic naming the hook. These 11 are LIFECYCLE (worker build/destroy/clear, setup-state handoff): structurally safe, since they cannot become per-query without the design changing shape.
pub var worker_clear: *const fn (worker: *anyopaque) void =
    struct {
        fn stub(_: *anyopaque) void {
            hookPanic("worker_clear");
        }
    }.stub;
/// failure: loud — hookPanic naming the hook. These 11 are LIFECYCLE (worker build/destroy/clear, setup-state handoff): structurally safe, since they cannot become per-query without the design changing shape.
pub var setup_states_adopt_from_slot: *const fn (pool: *worker_layout.ThreadPool, states_slot: *anyopaque) void =
    struct {
        fn stub(_: *worker_layout.ThreadPool, _: *anyopaque) void {
            hookPanic("setup_states_adopt_from_slot");
        }
    }.stub;
/// failure: loud — hookPanic naming the hook. These 11 are LIFECYCLE (worker build/destroy/clear, setup-state handoff): structurally safe, since they cannot become per-query without the design changing shape.
pub var setup_states_adopt_from_storage: *const fn (pool: *worker_layout.ThreadPool, storage: *anyopaque) void =
    struct {
        fn stub(_: *worker_layout.ThreadPool, _: *anyopaque) void {
            hookPanic("setup_states_adopt_from_storage");
        }
    }.stub;
/// failure: loud — hookPanic naming the hook. These 11 are LIFECYCLE (worker build/destroy/clear, setup-state handoff): structurally safe, since they cannot become per-query without the design changing shape.
pub var setup_state_back: *const fn (pool: *const worker_layout.ThreadPool) ?*const position_types.StateInfo =
    struct {
        fn stub(_: *const worker_layout.ThreadPool) ?*const position_types.StateInfo {
            hookPanic("setup_state_back");
        }
    }.stub;
/// failure: loud — hookPanic naming the hook. These 11 are LIFECYCLE (worker build/destroy/clear, setup-state handoff): structurally safe, since they cannot become per-query without the design changing shape.
pub var pending_states_available: *const fn (states_slot: *anyopaque) u8 =
    struct {
        fn stub(_: *anyopaque) u8 {
            hookPanic("pending_states_available");
        }
    }.stub;
/// failure: loud — hookPanic naming the hook. These 11 are LIFECYCLE (worker build/destroy/clear, setup-state handoff): structurally safe, since they cannot become per-query without the design changing shape.
pub var handoff_pending_states: *const fn (pool: *worker_layout.ThreadPool, states_slot: *anyopaque) u8 =
    struct {
        fn stub(_: *worker_layout.ThreadPool, _: *anyopaque) u8 {
            hookPanic("handoff_pending_states");
        }
    }.stub;
/// failure: loud — hookPanic naming the hook. These 11 are LIFECYCLE (worker build/destroy/clear, setup-state handoff): structurally safe, since they cannot become per-query without the design changing shape.
pub var shared_state_clear_histories: *const fn (shared_state: *const anyopaque) void =
    struct {
        fn stub(_: *const anyopaque) void {
            hookPanic("shared_state_clear_histories");
        }
    }.stub;
// Returns error.OutOfMemory: inserting a numa node's shared-history entry allocates
// (the map bucket + the large-page DynStats arrays), so this seam propagates OOM to the
// engine's single reconfigure handling boundary (resizeThreadsEngine) instead of
// panicking deep in the hook.
/// failure: loud — hookPanic naming the hook. These 11 are LIFECYCLE (worker build/destroy/clear, setup-state handoff): structurally safe, since they cannot become per-query without the design changing shape.
pub var shared_state_insert_history: *const fn (shared_state: *const anyopaque, numa_config: *const anyopaque, numa_index: usize, size: usize, do_bind: u8) error{OutOfMemory}!void =
    struct {
        fn stub(_: *const anyopaque, _: *const anyopaque, _: usize, _: usize, _: u8) error{OutOfMemory}!void {
            hookPanic("shared_state_insert_history");
        }
    }.stub;
/// failure: loud — hookPanic naming the hook. These 11 are LIFECYCLE (worker build/destroy/clear, setup-state handoff): structurally safe, since they cannot become per-query without the design changing shape.
pub var verify_thread_graph: *const fn (pool: *const worker_layout.ThreadPool, requested: usize, bound: usize) void =
    struct {
        fn stub(_: *const worker_layout.ThreadPool, _: usize, _: usize) void {
            hookPanic("verify_thread_graph");
        }
    }.stub;

test {
    @import("std").testing.refAllDecls(@This());
}
