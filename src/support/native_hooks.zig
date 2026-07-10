// Native runtime hook registry (M16.9): a fn-pointer table that breaks the module
// import cycles the retired C++ oracle used C-ABI `extern fn zfish_*` symbols for.
//
// The impls live in main.zig because they need position/engine/network/search/... —
// modules that already import their callers (thread/engine/native_thread/
// native_threadpool), so the callers can't import back to reach them. main installs
// the pointers at startup (installNativeHooks); the callers invoke through here
// instead of the old C-ABI exports. Pure Zig fn pointers -- no C ABI, type-checked.
//
// M17.9: the fields are NON-OPTIONAL, each defaulting to a named panic stub, so the
// callers invoke them directly (no `.?` null-unwrap at 10+ sites). A hook that was
// never registered fails fast with its own name instead of an opaque null-optional
// panic -- the M17.5e failure mode (a test that skipped installNativeHooks) now
// reports exactly which hook is missing.

const graph_layout = @import("graph_layout");

fn hookPanic(comptime name: []const u8) noreturn {
    @panic(name ++ ": native hook not registered (installNativeHooks not run?)");
}

pub var native_worker_build: *const fn (ctx: ?*anyopaque, idx: usize, thread: *anyopaque) void =
    struct {
        fn stub(_: ?*anyopaque, _: usize, _: *anyopaque) void {
            hookPanic("native_worker_build");
        }
    }.stub;
pub var native_worker_destroy: *const fn (worker: *anyopaque) void =
    struct {
        fn stub(_: *anyopaque) void {
            hookPanic("native_worker_destroy");
        }
    }.stub;
pub var worker_clear: *const fn (worker: *anyopaque) void =
    struct {
        fn stub(_: *anyopaque) void {
            hookPanic("worker_clear");
        }
    }.stub;
pub var setup_states_adopt_from_slot: *const fn (pool: *graph_layout.ThreadPool, states_slot: *anyopaque) void =
    struct {
        fn stub(_: *graph_layout.ThreadPool, _: *anyopaque) void {
            hookPanic("setup_states_adopt_from_slot");
        }
    }.stub;
pub var setup_states_adopt_from_storage: *const fn (pool: *graph_layout.ThreadPool, storage: *anyopaque) void =
    struct {
        fn stub(_: *graph_layout.ThreadPool, _: *anyopaque) void {
            hookPanic("setup_states_adopt_from_storage");
        }
    }.stub;
pub var setup_state_back: *const fn (pool: *const graph_layout.ThreadPool) ?*const anyopaque =
    struct {
        fn stub(_: *const graph_layout.ThreadPool) ?*const anyopaque {
            hookPanic("setup_state_back");
        }
    }.stub;
pub var pending_states_available: *const fn (states_slot: *anyopaque) u8 =
    struct {
        fn stub(_: *anyopaque) u8 {
            hookPanic("pending_states_available");
        }
    }.stub;
pub var handoff_pending_states: *const fn (pool: *graph_layout.ThreadPool, states_slot: *anyopaque) u8 =
    struct {
        fn stub(_: *graph_layout.ThreadPool, _: *anyopaque) u8 {
            hookPanic("handoff_pending_states");
        }
    }.stub;
pub var shared_state_clear_histories: *const fn (shared_state: *const anyopaque) void =
    struct {
        fn stub(_: *const anyopaque) void {
            hookPanic("shared_state_clear_histories");
        }
    }.stub;
pub var shared_state_insert_history: *const fn (shared_state: *const anyopaque, numa_config: *const anyopaque, numa_index: usize, size: usize, do_bind: u8) void =
    struct {
        fn stub(_: *const anyopaque, _: *const anyopaque, _: usize, _: usize, _: u8) void {
            hookPanic("shared_state_insert_history");
        }
    }.stub;
pub var verify_thread_graph: *const fn (pool: *const graph_layout.ThreadPool, requested: usize, bound: usize) void =
    struct {
        fn stub(_: *const graph_layout.ThreadPool, _: usize, _: usize) void {
            hookPanic("verify_thread_graph");
        }
    }.stub;
