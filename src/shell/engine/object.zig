// Hold the buffer-resident engine object.
//
// Hold an EngineObject in the engine buffer (Zig-allocated in main.zig). Serve as an
// OWNERSHIP CONTAINER: own each engine member as an explicitly-freed heap
// object it points at, so member teardown is explicit and ordered here.
//
// Members:
//   numa_context     *NumaReplicationContext (owns the NumaConfig + replica registry)
//   states           StateList (the fallback root list)
//   threads          value-initialized ThreadPool buffer (the thread vector)
//   network          single-node NNUE holder
//   update_context   inline UpdateContext slot
//   binary_directory owned C string                  (misc getBinaryDirectory)
//   cli              argc/argv
// Keep pos / tt / sharedHists as Zig-side globals (side_pos_storage / side_tt_storage
// here, side_shared_histories) whose accessors ignore the engine pointer, so the
// engine object does not own them.

const std = @import("std");
const worker_layout = @import("worker_layout");
const misc_port = @import("misc");
const state_list_port = @import("state_list"); // StateList
const network_port = @import("network");
const position_types = @import("position_types");
const numa = @import("numa");

// ---- the member allocators -------
// Create threads as a typed ThreadPool through the Allocator interface. Take
// worker_layout.thread_pool_size (48) as the ThreadPool buffer size.
//
// numa_context was the address of a module-static byte -- a non-null identity that was
// "never dereferenced". Nothing behind it meant the whole NUMA facade HAD to be stubbed:
// suggestsBindingThreads could only answer a constant, and NumaConfig.fromSystem (built by
// the unused EngineGraph) was orphaned. So `NumaPolicy auto`, the default, could never
// bind on any host, and the topology model was dead code. Own a real
// NumaReplicationContext here instead; the facade now has something to ask.
fn memberNumaContextNew() ?*anyopaque {
    const ctx = std.heap.c_allocator.create(numa.NumaReplicationContext) catch return null;
    const cfg = numa.NumaConfig.fromSystem(std.heap.c_allocator) catch {
        std.heap.c_allocator.destroy(ctx);
        return null;
    };
    ctx.* = numa.NumaReplicationContext.init(std.heap.c_allocator, cfg);
    return @ptrCast(ctx);
}
fn memberThreadpoolNew() ?*worker_layout.ThreadPool {
    // Create a typed, default-initialized ThreadPool via the Allocator interface. @sizeOf ==
    // thread_pool_size (48, asserted in worker_layout). Rely on every field having a default (the
    // `threads`/`bound` slices are non-optional pointers that std.mem.zeroes would reject,
    // so `.{}` -- empty slices + null setup_states -- is the idiomatic init here.
    const tp = std.heap.c_allocator.create(worker_layout.ThreadPool) catch return null;
    tp.* = .{};
    return tp;
}
// Trigger the NNUE load into the Zig-owned storage. There is no engine
// `network` member -- the worker network resolver / eval / verify read the
// global FT storage directly.
fn loadNetwork(binary_dir: [*:0]const u8, binary_dir_len: usize) void {
    network_port.load(binary_dir, binary_dir_len, binary_dir, 0);
}
// Hold updateContext + onVerifyNetwork INLINE in the engine object (stable address
// for the worker managers / verify emit to bind via accessor), placement-constructed.

// Reserve the UpdateContext slot. The search emit calls its onUpdateFull/onBestmove
// (set by init_search_update_listeners) and binds this slot via the accessor. Take 240 as
// a generous upper bound on sizeof(UpdateContext).
pub const update_context_size: usize = 240;
// Reserve the onVerifyNetwork slot; take 64 as a safe upper bound on its size.
// Set onVerifyNetwork to print_info_string (interactive) or a no-op (quiet), called
// on a network verify message.
pub const verify_network_fn_size: usize = 64;

/// Define the buffer-resident engine object: `main` allocates a `@sizeOf(EngineObject)`-byte
/// buffer and reinterprets it as this struct (`fromBuffer`). Keep it a plain Zig struct -- the
/// buffer is written and read as this same type throughout, so Zig owns the layout; there
/// is no C-ABI or cross-language contract that would need `extern`. Reach every access below
/// through a typed member accessor, never a byte offset.
pub const EngineObject = struct {
    numa_context: ?*anyopaque = null,
    states: ?*state_list_port.StateList = null,
    threads: ?*worker_layout.ThreadPool = null,
    binary_directory: ?[*:0]u8 = null,
    cli_argc: i32 = 0,
    cli_argv: ?[*]const [*:0]u8 = null,
    update_context: [update_context_size]u8 align(8) = @splat(0),
    on_verify_network: [verify_network_fn_size]u8 align(8) = @splat(0),

    pub fn fromBuffer(buf: *anyopaque) *EngineObject {
        return @ptrCast(@alignCast(buf));
    }
    pub fn fromPtr(p: *anyopaque) *EngineObject {
        return @ptrCast(@alignCast(p));
    }

    // Access the members.
    pub fn cliArgc(self: *const EngineObject) i32 {
        return self.cli_argc;
    }
    pub fn cliArgAt(self: *const EngineObject, index: i32) ?[*:0]const u8 {
        if (index < 0 or index >= self.cli_argc) return null;
        const argv = self.cli_argv orelse return null;
        return argv[@intCast(index)];
    }
    pub fn numaContextPtr(self: *EngineObject) *anyopaque {
        return self.numa_context.?;
    }
    pub fn statesSlotPtr(self: *EngineObject) *anyopaque {
        return @ptrCast(&self.states);
    }
    pub fn threadsPtr(self: *EngineObject) *worker_layout.ThreadPool {
        return self.threads.?;
    }
    /// Return the side Position block (the engine's pos storage); engine-independent.
    pub fn positionPtr(self: *EngineObject) *position_types.Position {
        _ = self;
        return @ptrCast(@alignCast(&side_pos_storage));
    }
    /// Return the side TranspositionTable block (the engine's tt storage).
    pub fn ttPtr(self: *EngineObject) *worker_layout.TranspositionTable {
        _ = self;
        return @ptrCast(@alignCast(&side_tt_storage));
    }
    pub fn updateContextPtr(self: *const EngineObject) *const anyopaque {
        return @ptrCast(&self.update_context);
    }
};

// Hold the side Position/TT storage the engine object uses. File-scope it here so the
// accessors own them.
var side_pos_storage: [1032]u8 align(64) = @splat(0);
var side_tt_storage: [64]u8 align(64) = @splat(0);

/// Return the side TT storage as a raw pointer (for main.zig's construction-time direct access).
pub fn sideTtPtr() *anyopaque {
    return @ptrCast(&side_tt_storage);
}
pub fn sideTtReset() void {
    @memset(&side_tt_storage, 0);
}

/// Allocate + assemble the engine's heap members into the buffer (binaryDirectory,
/// numaContext, states, options, threads, network), in dependency order: numaContext
/// before network (network captures it), binaryDirectory before network
/// (get_default_network reads it). Run the post-member work (option registration, start
/// position, thread/worker sizing) after this, in init_body.
///
/// Return false on any allocation failure (caller aborts loudly — startup only).
pub fn constructMembers(buf: *anyopaque, argv0: [*:0]const u8) bool {
    const e = EngineObject.fromBuffer(buf);
    e.* = .{};

    // Set binaryDirectory (owned C string) — get_default_network loads the .nnue from it.
    const argv0_slice = std.mem.span(argv0);
    e.binary_directory = misc_port.getBinaryDirectory(argv0_slice);

    e.numa_context = memberNumaContextNew() orelse return false;
    // Build the states slot: a StateList (the fallback root list).
    const states_list = std.heap.c_allocator.create(state_list_port.StateList) catch return false;
    states_list.* = state_list_port.StateList.init(std.heap.c_allocator) catch {
        std.heap.c_allocator.destroy(states_list);
        return false;
    };
    e.states = states_list;
    e.threads = memberThreadpoolNew() orelse return false;

    const bdir: [*:0]const u8 = e.binary_directory orelse "";
    loadNetwork(bdir, std.mem.span(bdir).len);

    // Rely on the field initializers above to zero the update_context / on_verify_network
    // slots. The search binds engine_graph's UpdateContext and the verify
    // emitter reads the empty slot, so no further construction is needed.

    return true;
}

/// Store the CLI argc/argv (the cli sub-object the engine object subsumes).
pub fn setCli(buf: *anyopaque, argc: i32, argv: [*]const [*:0]u8) void {
    const e = EngineObject.fromBuffer(buf);
    e.cli_argc = argc;
    e.cli_argv = argv;
}

/// Free the engine's heap members in reverse construction / dependency order. The caller
/// (main.zig destruct_at) runs the thread teardown first: clear nulls the pool's
/// threads vector, and releasePendingStateSlot frees `states` if it was
/// never moved into pool.setupStates. Then:
///   - free network  (the single-node NNUE holder handle; references numa, so first)
///   - free threads   (setupStates is freed by the block below, not by a dtor)
///   - free options
///   - free numa_context
///   - free  binary_directory
/// Free states by EXACTLY ONE of {release_pending_state_slot, the setupStates block
/// below} — never both — matching the move handoff lifecycle.
pub fn destructMembers(buf: *anyopaque) void {
    const e = EngineObject.fromBuffer(buf);

    // Leave update_context / on_verify_network as plain zeroed buffers — no dtor needed.

    // Crack the states apart: free the pool's setupStates StateList @8 + the engine `states`
    // slot's StateList, and NULL setupStates@8, before freeing the ThreadPool buffer, so the
    // StateList is destroyed here rather than left dangling.
    // Own each list by exactly one of {slot, setupStates} (adopt MOVEs + nulls source),
    // and rely on release_pending_state_slot having already freed the side-table storage, so this
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

    // Free threads through the same interface -- it was allocator.create'd.
    if (e.threads) |t| std.heap.c_allocator.destroy(t);
    e.threads = null;
    if (e.numa_context) |raw| {
        const ctx: *numa.NumaReplicationContext = @ptrCast(@alignCast(raw));
        ctx.deinit(); // frees the NumaConfig + the replica registry
        std.heap.c_allocator.destroy(ctx);
    }
    e.numa_context = null;
    if (e.binary_directory) |bd| std.heap.c_allocator.free(std.mem.span(bd));
    e.binary_directory = null;
}

/// Report the sizeof the buffer the engine object needs.
pub fn sizeofEngine() usize {
    return @sizeOf(EngineObject);
}
pub fn alignofEngine() usize {
    return @alignOf(EngineObject);
}

test {
    @import("std").testing.refAllDecls(@This());
}
