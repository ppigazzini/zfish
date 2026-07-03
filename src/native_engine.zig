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
const state_list_port = @import("state_list"); // native StateList (states crack)

// ---- the interim-C++ member heap allocators (uci_bridge.cpp, default build) -------
// M-FINAL cutover: the trivial raw-heap members (numa_context + options are 1-byte handles never
// dereferenced; threads is a value-initialized ThreadPool buffer whose threads vector is native-
// managed and whose ~ThreadPool is a no-op after native teardown) are allocated natively here —
// std.c.malloc/calloc is the SAME libc allocator the C++ std::malloc used, so the alloc/free
// pairing is preserved (valgrind-clean) and the C++ member_{numa_context,threadpool,options}_*
// fns + the sizeof(ThreadPool) drop out of the default build. graph_layout.thread_pool_size (64)
// replaces sizeof(Stockfish::ThreadPool). Verified by teardown (H5) + valgrind (H3).
fn memberNumaContextNew() ?*anyopaque {
    return std.c.malloc(1);
}
fn memberOptionsNew() ?*anyopaque {
    return std.c.malloc(1);
}
fn memberThreadpoolNew() ?*anyopaque {
    return std.c.calloc(1, graph_layout.thread_pool_size);
}
fn memberHandleFree(p: ?*anyopaque) void {
    std.c.free(p);
}
// network: native single-node holder. malloc(1) handle (never dereferenced — the worker network
// resolver / eval / verify read native storage; nothing indexes network[token]) + trigger the
// native NNUE load into the Zig-owned storage, exactly as the old C++ net->load() did. numa_context
// is unused (single node). (states_new/delete dropped: states is a native StateList — state_list.zig
// — and member_states_* had no caller.)
extern fn zfish_network_load(network: *anyopaque, dir_ptr: [*]const u8, dir_len: usize, name_ptr: [*]const u8, name_len: usize) void;
fn memberNetworkNew(binary_dir: [*:0]const u8, binary_dir_len: usize) ?*anyopaque {
    const holder = std.c.malloc(1) orelse return null;
    zfish_network_load(holder, binary_dir, binary_dir_len, binary_dir, 0);
    return holder;
}
// updateContext + onVerifyNetwork are held INLINE in the native engine (stable address
// for the worker managers / verify emit to bind via accessor) and placement-constructed.

// sizeof(Search::SearchManager::UpdateContext): 4 std::function (libc++ 48B each) + a
// void* ctx, padded. LIVE: the native search emit calls its onUpdateFull/onBestmove
// (set by init_search_update_listeners) — so this slot is placement-constructed as a
// real C++ UpdateContext and bound by the worker managers via the accessor. 240 is a
// generous upper bound on sizeof(UpdateContext).
pub const update_context_size: usize = 240;
// sizeof(std::function<void(std::string_view)>) — libc++ is 48B; 64 is a safe bound.
// onVerifyNetwork: set to print_info_string (interactive) or a no-op (quiet) and called
// by zfish_engine_emit_verify_message on a network verify message.
pub const verify_network_fn_size: usize = 64;

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
    on_verify_network: [verify_network_fn_size]u8 align(8) = [_]u8{0} ** verify_network_fn_size,

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
        pub const on_verify_network = @offsetOf(NativeEngine, "on_verify_network");
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

    e.numa_context = memberNumaContextNew() orelse return false;
    // states slot: a native StateList (the fallback root list); replaces the C++ deque(1).
    const states_list = std.heap.c_allocator.create(state_list_port.StateList) catch return false;
    states_list.* = state_list_port.StateList.init(std.heap.c_allocator) catch {
        std.heap.c_allocator.destroy(states_list);
        return false;
    };
    e.states = states_list;
    e.options = memberOptionsNew() orelse return false;
    e.threads = memberThreadpoolNew() orelse return false;

    const bdir: [*:0]const u8 = e.binary_directory orelse "";
    e.network = memberNetworkNew(bdir, std.mem.span(bdir).len) orelse return false;

    // REPORT-12 TU=0 std::function cluster: the update_context / on_verify_network slots are zeroed
    // by the field initializers above, which is byte-equivalent to a default-constructed empty
    // std::function/UpdateContext. The native search binds engine_graph's native UpdateContext and the
    // verify emitter reads the empty slot, so no C++ placement-construct is needed (it was a no-op).

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

    // Destruct the inline live C++ sub-objects (the std::functions they hold) first.
    // (update_context / on_verify_network are plain zeroed buffers in default — no C++ dtor needed)

    // states crack: free the pool's setupStates StateList @8 + the engine `states` slot's
    // StateList, and NULL setupStates@8, BEFORE deleting the C++ ThreadPool — else
    // ~ThreadPool would delete setupStates as a deque* and corrupt the native StateList.
    // Each list is owned by exactly one of {slot, setupStates} (adopt MOVEs + nulls source),
    // and the side-table storage was already freed by release_pending_state_slot, so this
    // frees each surviving list exactly once.
    if (e.threads) |pool| {
        const setup: *?*state_list_port.StateList =
            @ptrCast(@alignCast(&graph_layout.ThreadPool.fromPtr(pool).setup_states));
        if (setup.*) |list| {
            state_list_port.destroyStateList(std.heap.c_allocator, list);
            setup.* = null;
        }
    }
    if (e.states) |s| {
        state_list_port.destroyStateList(std.heap.c_allocator, @ptrCast(@alignCast(s)));
        e.states = null;
    }

    memberHandleFree(e.network);
    e.network = null;
    memberHandleFree(e.threads);
    e.threads = null;
    memberHandleFree(e.options);
    e.options = null;
    memberHandleFree(e.numa_context);
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
