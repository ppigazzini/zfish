// Native runtime hook registry (M16.9): a fn-pointer table that breaks the module
// import cycles the retired C++ oracle used C-ABI `extern fn zfish_*` symbols for.
//
// The impls live in main.zig because they need position/engine/network/search/... —
// modules that already import their callers (thread/engine/native_thread/
// native_threadpool), so the callers can't import back to reach them. main installs
// the pointers at startup (installNativeHooks); the callers invoke through here
// instead of the old C-ABI exports. Pure Zig fn pointers -- no C ABI, type-checked.

pub var native_worker_build: ?*const fn (ctx: ?*anyopaque, idx: usize, thread: *anyopaque) void = null;
pub var native_worker_destroy: ?*const fn (worker: *anyopaque) void = null;
pub var worker_clear: ?*const fn (worker: *anyopaque) void = null;
pub var setup_states_adopt_from_slot: ?*const fn (pool: *anyopaque, states_slot: *anyopaque) void = null;
pub var setup_states_adopt_from_storage: ?*const fn (pool: *anyopaque, storage: *anyopaque) void = null;
pub var setup_state_back: ?*const fn (pool: *const anyopaque) ?*const anyopaque = null;
pub var pending_states_available: ?*const fn (states_slot: *anyopaque) u8 = null;
pub var handoff_pending_states: ?*const fn (pool: *anyopaque, states_slot: *anyopaque) u8 = null;
pub var shared_state_clear_histories: ?*const fn (shared_state: *const anyopaque) void = null;
pub var shared_state_insert_history: ?*const fn (shared_state: *const anyopaque, numa_config: *const anyopaque, numa_index: usize, size: usize, do_bind: u8) void = null;
pub var verify_thread_graph: ?*const fn (pool: *const anyopaque, requested: usize, bound: usize) void = null;
pub var load_network_owner: ?*const fn (engine_ptr: *anyopaque, file_ptr: [*]const u8, file_len: usize) void = null;
pub var save_network_owner: ?*const fn (engine_ptr: *anyopaque, has_filename: u8, filename_ptr: [*]const u8, filename_len: usize) void = null;
