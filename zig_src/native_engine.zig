// Native engine — the buffer-resident, post-src/ replacement for the C++
// UCIEngine/Engine placement-construct (NATIVE_ENGINE_CUTOVER.md).
//
// The engine buffer (Zig-allocated in main.zig) holds a NativeEngine instead of a
// C++ UCIEngine. NativeEngine is an OWNERSHIP CONTAINER: it owns each engine member
// as an explicitly-freed heap object it points at, so NO C++ ~Engine/~UCIEngine ever
// runs and the ~Engine/~ThreadPool coupling that made the cut look atomic is gone.
//
// Member ownership at the flip (see the cutover doc):
//   numa_context   heap C++ NumaReplicationContext   (zfish_member_numa_context_*)
//   states         heap C++ deque<StateInfo>(1)      (zfish_member_states_*)
//   options        heap C++ OptionsMap               (zfish_member_options_*)
//   threads        heap C++ ThreadPool               (zfish_member_threadpool_*)
//   network        heap C++ LazyNumaReplicated<Net>  (zfish_member_network_*)
//   update_context inline native placeholder         (dead in the default build)
//   binary_directory owned C string                  (misc getBinaryDirectory)
//   cli            argc/argv                          (UCIEngine::cli accessors)
// pos / tt / sharedHists are ALREADY Zig-side globals (side_pos_storage /
// side_tt_storage / side_shared_histories in main.zig) whose accessors ignore the
// engine pointer, so the native engine does not own them.
//
// Each interim-C++ heap member ports to a native type one-at-a-time, incrementally
// green, after the flip — until uci_bridge.cpp + src delete (TU=0).

const std = @import("std");
const graph_layout = @import("graph_layout.zig");
const misc_port = @import("misc");

// ---- the interim-C++ member heap allocators (uci_bridge.cpp, default build) -------
extern fn zfish_member_numa_context_new() ?*anyopaque;
extern fn zfish_member_numa_context_delete(p: ?*anyopaque) void;
extern fn zfish_member_threadpool_new() ?*anyopaque;
extern fn zfish_member_threadpool_delete(p: ?*anyopaque) void;
extern fn zfish_member_options_new() ?*anyopaque;
extern fn zfish_member_options_delete(p: ?*anyopaque) void;
extern fn zfish_member_states_new() ?*anyopaque;
extern fn zfish_member_states_delete(p: ?*anyopaque) void;
extern fn zfish_member_network_new(numa_context: ?*anyopaque, binary_dir: [*]const u8, binary_dir_len: usize) ?*anyopaque;
extern fn zfish_member_network_delete(p: ?*anyopaque) void;

// sizeof(Search::SearchManager::UpdateContext): 4 std::function (32B each) + a void*
// ctx, padded. Dead in the default build (every read of it is legacy-#ifdef-only; the
// native emit is the authority), so the native engine holds a zeroed block of the
// right footprint purely so the bound pointer is valid + the layout total is sane.
pub const update_context_size: usize = 240;

/// The buffer-resident native engine. `extern struct` so the field offsets are stable
/// and the member accessors (main.zig) can read them by the documented native offset.
pub const NativeEngine = extern struct {
    numa_context: ?*anyopaque = null,
    states: ?*anyopaque = null,
    options: ?*anyopaque = null,
    threads: ?*anyopaque = null,
    network: ?*anyopaque = null,
    binary_directory: ?[*:0]u8 = null,
    cli_argc: c_int = 0,
    cli_argv: ?[*]const [*:0]u8 = null,
    update_context: [update_context_size]u8 align(8) = [_]u8{0} ** update_context_size,

    /// Native field offsets the member accessors read (replacing graph_layout.engine_off
    /// inline-into-C++-Engine offsets). @offsetOf keeps these pinned to the struct.
    pub const off = struct {
        pub const numa_context = @offsetOf(NativeEngine, "numa_context");
        pub const states = @offsetOf(NativeEngine, "states");
        pub const options = @offsetOf(NativeEngine, "options");
        pub const threads = @offsetOf(NativeEngine, "threads");
        pub const network = @offsetOf(NativeEngine, "network");
        pub const cli_argc = @offsetOf(NativeEngine, "cli_argc");
        pub const cli_argv = @offsetOf(NativeEngine, "cli_argv");
        pub const update_context = @offsetOf(NativeEngine, "update_context");
    };

    pub fn fromBuffer(buf: *anyopaque) *NativeEngine {
        return @ptrCast(@alignCast(buf));
    }
};

/// Allocate + assemble the engine's heap members into the buffer. Mirrors the member-
/// init list of the C++ Engine ctor (binaryDirectory, numaContext, states, options,
/// threads, network), in dependency order: numaContext before network (network
/// captures it), binaryDirectory before network (get_default_network reads it). The
/// post-member work (option registration, start position, thread/worker sizing) runs
/// after this, in init_body, exactly as the C++ ctor body did.
///
/// Returns false on any allocation failure (caller aborts loudly — startup only).
pub fn constructMembers(buf: *anyopaque, argv0: [*:0]const u8) bool {
    const e = NativeEngine.fromBuffer(buf);
    e.* = .{};

    // binaryDirectory (owned C string) — get_default_network loads the .nnue from it.
    const argv0_slice = std.mem.span(argv0);
    e.binary_directory = misc_port.getBinaryDirectory(argv0_slice);

    e.numa_context = zfish_member_numa_context_new() orelse return false;
    e.states = zfish_member_states_new() orelse return false;
    e.options = zfish_member_options_new() orelse return false;
    e.threads = zfish_member_threadpool_new() orelse return false;

    const bdir: [*:0]const u8 = e.binary_directory orelse "";
    e.network = zfish_member_network_new(e.numa_context, bdir, std.mem.span(bdir).len) orelse return false;

    return true;
}

/// Store the CLI argc/argv (the UCIEngine::cli sub-object the native engine subsumes).
pub fn setCli(buf: *anyopaque, argc: c_int, argv: [*]const [*:0]u8) void {
    const e = NativeEngine.fromBuffer(buf);
    e.cli_argc = argc;
    e.cli_argv = argv;
}

/// Free the engine's heap members in reverse construction / dependency order, bypassing
/// every C++ dtor (~Engine/~ThreadPool/~UCIEngine). The caller (main.zig destruct_at)
/// runs the thread teardown first: zfish_native_threadpool_clear nulls the pool's native
/// Threads vector, and zfish_engine_release_pending_state_slot frees `states` if it was
/// never moved into pool.setupStates. After that:
///   - delete network  (frees the replicated Network instances; references numa, so first)
///   - delete threads   (~ThreadPool frees setupStates if states was handed off to it)
///   - delete options
///   - delete numa_context
///   - free  binary_directory
/// states is freed by EXACTLY ONE of {release_pending_state_slot, ~ThreadPool} — never
/// both — matching the std::move handoff lifecycle.
pub fn destructMembers(buf: *anyopaque) void {
    const e = NativeEngine.fromBuffer(buf);

    zfish_member_network_delete(e.network);
    e.network = null;
    zfish_member_threadpool_delete(e.threads);
    e.threads = null;
    zfish_member_options_delete(e.options);
    e.options = null;
    zfish_member_numa_context_delete(e.numa_context);
    e.numa_context = null;
    if (e.binary_directory) |bd| std.c.free(bd);
    e.binary_directory = null;
}

/// sizeof the buffer the native engine needs (replaces sizeof(UCIEngine)=1696).
pub fn sizeofEngine() usize {
    return @sizeOf(NativeEngine);
}
pub fn alignofEngine() usize {
    return @alignOf(NativeEngine);
}
