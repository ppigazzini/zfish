// Native engine — the buffer-resident engine object.
//
// The engine buffer (Zig-allocated in main.zig) holds a NativeEngine. It is an
// OWNERSHIP CONTAINER: it owns each engine member as an explicitly-freed heap
// object it points at, so member teardown is explicit and ordered here.
//
// Members:
//   numa_context     static-byte-address handle (single node; never dereferenced)
//   states           native StateList (the fallback root list)
//   threads          value-initialized ThreadPool buffer (native Threads vector)
//   network          native single-node NNUE holder
//   update_context   inline native UpdateContext slot
//   binary_directory owned C string                  (misc getBinaryDirectory)
//   cli              argc/argv
// pos / tt / sharedHists are Zig-side globals (side_pos_storage / side_tt_storage
// here, side_shared_histories) whose accessors ignore the engine pointer, so the
// native engine does not own them.

const std = @import("std");
const graph_layout = @import("graph_layout");
const misc_port = @import("misc");
const state_list_port = @import("state_list"); // native StateList
const network_port = @import("network");
const position_types = @import("position_types");

// ---- the member allocators -------
// numa_context is a never-dereferenced non-null handle -> a module-static byte address
// (no alloc/free). threads is a typed ThreadPool created through the Allocator interface.
// graph_layout.thread_pool_size (48) is the ThreadPool buffer size.
// numa_context is a single-node, never-dereferenced handle -- a distinct non-null pointer
// identity for the C-ABI, not a real allocation. Use the address of a module-static byte
// (TigerBeetle: no alloc, no free) instead of malloc(1)/free.
var numa_ctx_placeholder: u8 = 0;
fn memberNumaContextNew() ?*anyopaque {
    return @ptrCast(&numa_ctx_placeholder);
}
fn memberThreadpoolNew() ?*graph_layout.ThreadPool {
    // A typed, default-initialized ThreadPool via the Allocator interface. @sizeOf ==
    // thread_pool_size (48, asserted in graph_layout). Every field has a default (the
    // `threads`/`bound` slices are non-optional pointers that std.mem.zeroes would reject,
    // so `.{}` -- empty slices + null setup_states -- is the idiomatic init here.
    const tp = std.heap.c_allocator.create(graph_layout.ThreadPool) catch return null;
    tp.* = .{};
    return tp;
}
// Trigger the native NNUE load into the Zig-owned storage. There is no engine
// `network` member -- the worker network resolver / eval / verify read the
// global native FT storage directly.
fn loadNetwork(binary_dir: [*:0]const u8, binary_dir_len: usize) void {
    network_port.load(binary_dir, binary_dir_len, binary_dir, 0);
}
// updateContext + onVerifyNetwork are held INLINE in the native engine (stable address
// for the worker managers / verify emit to bind via accessor) and placement-constructed.

// The UpdateContext slot. The native search emit calls its onUpdateFull/onBestmove
// (set by init_search_update_listeners) and binds this slot via the accessor. 240 is
// a generous upper bound on sizeof(UpdateContext).
pub const update_context_size: usize = 240;
// The onVerifyNetwork slot; 64 is a safe upper bound on its size.
// onVerifyNetwork: set to print_info_string (interactive) or a no-op (quiet) and called
// on a network verify message.
pub const verify_network_fn_size: usize = 64;

/// The buffer-resident native engine. `extern struct` so the field offsets are stable
/// and the member accessors (main.zig) can read them by the documented native offset.
pub const NativeEngine = struct {
    numa_context: ?*anyopaque = null,
    states: ?*state_list_port.StateList = null,
    threads: ?*graph_layout.ThreadPool = null,
    binary_directory: ?[*:0]u8 = null,
    cli_argc: c_int = 0,
    cli_argv: ?[*]const [*:0]u8 = null,
    update_context: [update_context_size]u8 align(8) = [_]u8{0} ** update_context_size,
    on_verify_network: [verify_network_fn_size]u8 align(8) = [_]u8{0} ** verify_network_fn_size,

    /// Native field offsets the member accessors read. @offsetOf keeps these pinned
    /// to the struct.
    pub const off = struct {
        pub const numa_context = @offsetOf(NativeEngine, "numa_context");
        pub const states = @offsetOf(NativeEngine, "states");
        pub const threads = @offsetOf(NativeEngine, "threads");
        pub const cli_argc = @offsetOf(NativeEngine, "cli_argc");
        pub const cli_argv = @offsetOf(NativeEngine, "cli_argv");
        pub const update_context = @offsetOf(NativeEngine, "update_context");
        pub const on_verify_network = @offsetOf(NativeEngine, "on_verify_network");
    };

    pub fn fromBuffer(buf: *anyopaque) *NativeEngine {
        return @ptrCast(@alignCast(buf));
    }
    pub fn fromPtr(p: *anyopaque) *NativeEngine {
        return @ptrCast(@alignCast(p));
    }

    // Member accessors.
    pub fn cliArgc(self: *const NativeEngine) c_int {
        return self.cli_argc;
    }
    pub fn cliArgAt(self: *const NativeEngine, index: c_int) ?[*:0]const u8 {
        if (index < 0 or index >= self.cli_argc) return null;
        const argv = self.cli_argv orelse return null;
        return argv[@intCast(index)];
    }
    pub fn numaContextPtr(self: *NativeEngine) *anyopaque {
        return self.numa_context.?;
    }
    pub fn statesSlotPtr(self: *NativeEngine) *anyopaque {
        return @ptrCast(&self.states);
    }
    pub fn threadsPtr(self: *NativeEngine) *graph_layout.ThreadPool {
        return self.threads.?;
    }
    /// The side Position block (the engine's pos storage); engine-independent.
    pub fn positionPtr(self: *NativeEngine) *position_types.Position {
        _ = self;
        return @ptrCast(@alignCast(&side_pos_storage));
    }
    /// The side TranspositionTable block (the engine's tt storage).
    pub fn ttPtr(self: *NativeEngine) *graph_layout.TranspositionTable {
        _ = self;
        return @ptrCast(@alignCast(&side_tt_storage));
    }
    pub fn updateContextPtr(self: *const NativeEngine) *const anyopaque {
        return @ptrCast(&self.update_context);
    }
};

// The side Position/TT storage the native engine uses. File-scoped here so the
// accessors own them.
var side_pos_storage: [1032]u8 align(64) = [_]u8{0} ** 1032;
var side_tt_storage: [64]u8 align(64) = [_]u8{0} ** 64;

/// The side TT storage as a raw pointer (for main.zig's construction-time direct access).
pub fn sideTtPtr() *anyopaque {
    return @ptrCast(&side_tt_storage);
}
pub fn sideTtReset() void {
    @memset(&side_tt_storage, 0);
}

/// Allocate + assemble the engine's heap members into the buffer (binaryDirectory,
/// numaContext, states, options, threads, network), in dependency order: numaContext
/// before network (network captures it), binaryDirectory before network
/// (get_default_network reads it). The post-member work (option registration, start
/// position, thread/worker sizing) runs after this, in init_body.
///
/// Returns false on any allocation failure (caller aborts loudly — startup only).
pub fn constructMembers(buf: *anyopaque, argv0: [*:0]const u8) bool {
    const e = NativeEngine.fromBuffer(buf);
    e.* = .{};

    // binaryDirectory (owned C string) — get_default_network loads the .nnue from it.
    const argv0_slice = std.mem.span(argv0);
    e.binary_directory = misc_port.getBinaryDirectory(argv0_slice);

    e.numa_context = memberNumaContextNew() orelse return false;
    // states slot: a native StateList (the fallback root list).
    const states_list = std.heap.c_allocator.create(state_list_port.StateList) catch return false;
    states_list.* = state_list_port.StateList.init(std.heap.c_allocator) catch {
        std.heap.c_allocator.destroy(states_list);
        return false;
    };
    e.states = states_list;
    e.threads = memberThreadpoolNew() orelse return false;

    const bdir: [*:0]const u8 = e.binary_directory orelse "";
    loadNetwork(bdir, std.mem.span(bdir).len);

    // The update_context / on_verify_network slots are zeroed by the field initializers
    // above. The native search binds engine_graph's native UpdateContext and the verify
    // emitter reads the empty slot, so no further construction is needed.

    return true;
}

/// Store the CLI argc/argv (the UCIEngine::cli sub-object the native engine subsumes).
pub fn setCli(buf: *anyopaque, argc: c_int, argv: [*]const [*:0]u8) void {
    const e = NativeEngine.fromBuffer(buf);
    e.cli_argc = argc;
    e.cli_argv = argv;
}

/// Free the engine's heap members in reverse construction / dependency order. The caller
/// (main.zig destruct_at) runs the thread teardown first: clear nulls the pool's native
/// Threads vector, and releasePendingStateSlot frees `states` if it was
/// never moved into pool.setupStates. After that:
///   - free network  (the single-node NNUE holder handle; references numa, so first)
///   - free threads   (setupStates is freed by the block below, not by a dtor)
///   - free options
///   - free numa_context
///   - free  binary_directory
/// states is freed by EXACTLY ONE of {release_pending_state_slot, the setupStates block
/// below} — never both — matching the move handoff lifecycle.
pub fn destructMembers(buf: *anyopaque) void {
    const e = NativeEngine.fromBuffer(buf);

    // update_context / on_verify_network are plain zeroed buffers — no dtor needed.

    // states crack: free the pool's setupStates StateList @8 + the engine `states` slot's
    // StateList, and NULL setupStates@8, before freeing the ThreadPool buffer, so the
    // native StateList is destroyed here rather than left dangling.
    // Each list is owned by exactly one of {slot, setupStates} (adopt MOVEs + nulls source),
    // and the side-table storage was already freed by release_pending_state_slot, so this
    // frees each surviving list exactly once.
    if (e.threads) |pool| {
        const setup: *?*state_list_port.StateList = &pool.setup_states;
        if (setup.*) |list| {
            state_list_port.destroyStateList(std.heap.c_allocator, list);
            setup.* = null;
        }
    }
    if (e.states) |s| {
        state_list_port.destroyStateList(std.heap.c_allocator, s);
        e.states = null;
    }

    // threads was allocator.create'd -- free it through the same interface.
    if (e.threads) |t| std.heap.c_allocator.destroy(t);
    e.threads = null;
    e.numa_context = null; // static placeholder -- nothing to free
    if (e.binary_directory) |bd| std.heap.c_allocator.free(std.mem.span(bd));
    e.binary_directory = null;
}

/// sizeof the buffer the native engine needs (replaces sizeof(UCIEngine)=1696).
pub fn sizeofEngine() usize {
    return @sizeOf(NativeEngine);
}
pub fn alignofEngine() usize {
    return @alignOf(NativeEngine);
}

test {
    @import("std").testing.refAllDecls(@This());
}
