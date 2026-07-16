// Assemble the Zig Engine graph: the assembly node.
//
// Bring the object graph together here: a plain struct owning the Zig
// subsystems:
//
//   options        -> OptionsModel        (uci/option.zig)
//   threads        -> ThreadPool          (thread_runtime.zig)
//   tt             -> TranspositionTable   (tt.zig)
//   update_context -> UpdateContext        (search_manager.zig)
//   network        -> NNUE network         (network.zig)
//   position       -> Position             (position.zig)
//
// Reach Position and Network through opaque slots here; everything else is a
// concrete type. Hand each Worker a SharedState bound
// to these members -- the graph does it here, vtable-free and callback-free.

const std = @import("std");

const ThreadPool = @import("thread").thread_runtime.ThreadPool;
const tt_mod = @import("tt");
const TranspositionTable = tt_mod.TranspositionTable;
const sm = @import("search_manager");
const UpdateContext = sm.UpdateContext;
const SearchManager = sm.SearchManager;
// Treat shared_state as the generic SharedStateOf; this scaffolding binds its own referents
// (ThreadPool + TranspositionTable typed, the rest erased here), so it
// instantiates its own view. Use engine.SharedState on the live engine path.
// Bind the three live references the worker needs in the SharedState bundle
// (threads/tt/sharedHistories); options/network are NOT in the bundle (never read).
const SharedState = @import("shared_state").SharedStateOf(ThreadPool, TranspositionTable, anyopaque);
pub const StateList = @import("state_list").StateList;
pub const NumaConfig = @import("numa").NumaConfig;
pub const NumaReplicationContext = @import("numa").NumaReplicationContext;
pub const PositionStorage = @import("position_storage").PositionStorage;

// Map the Engine graph's full member set, in declaration order:
//
//   binary_directory  -> []const u8                 [trivial slot]
//   numa_context      -> *NumaReplicationContext    [config + replica registry]
//   position          -> *PositionStorage           [owns the 1032B Position block]
//   states            -> *StateList                 [the StateInfo list]
//   options           -> *anyopaque (OptionsModel)  [opaque handle]
//   threads           -> *ThreadPool
//   tt                -> TranspositionTable
//   network           -> *anyopaque (NNUE network)  [opaque handle]
//   update_context    -> UpdateContext
//   shared_histories  -> *anyopaque                 [opaque handle]
//
// Reach *anyopaque slots through an opaque handle; concrete-typed
// members own their types directly. Take this as the complete definition of the
// Engine graph.
pub const EngineGraph = struct {
    binary_directory: []const u8,
    numa_context: *NumaReplicationContext, // NUMA context: config + replica registry
    position: *PositionStorage, // owner of the 1032B Position block
    states: *StateList, // the StateInfo list
    options: *anyopaque, // OptionsModel
    threads: *ThreadPool,
    tt: TranspositionTable,
    network: *anyopaque, // NNUE network (opaque handle)
    shared_histories: *anyopaque,
    update_context: UpdateContext,

    // Build the SharedState handed to every Worker, bound to this graph's own
    // subsystems.
    pub fn sharedState(self: *EngineGraph) SharedState {
        return SharedState.init(
            self.threads,
            &self.tt,
            self.shared_histories,
        );
    }

    // Bind this graph's UpdateContext for the main thread's manager; give others a
    // null manager. No vtable, no callback.
    pub fn makeManager(self: *EngineGraph, is_main: bool, id: usize) SearchManager {
        return if (is_main)
            SearchManager.initMain(&self.update_context, id)
        else
            SearchManager.initNull(&self.update_context);
    }

    // Construct the graph's OWNED members (states, numaContext,
    // position storage): default-construct binaryDirectory/numaContext/states + pos.
    // Pass in the other members -- subsystems the graph references, not owns: options (the
    // global OptionsModel), threads (the thread pool), network, shared_histories,
    // update_context; tt starts empty (sized later by resize).
    pub fn init(
        allocator: std.mem.Allocator,
        binary_directory: []const u8,
        options: *anyopaque,
        threads: *ThreadPool,
        network: *anyopaque,
        shared_histories: *anyopaque,
        update_context: UpdateContext,
    ) error{OutOfMemory}!EngineGraph {
        const states = try allocator.create(StateList);
        errdefer allocator.destroy(states);
        states.* = try StateList.init(allocator); // one root StateInfo (deque(1))
        errdefer states.deinit();

        const numa = try allocator.create(NumaReplicationContext);
        errdefer allocator.destroy(numa);
        numa.* = NumaReplicationContext.init(allocator, try NumaConfig.fromSystem(allocator));
        errdefer numa.deinit();

        const position = try allocator.create(PositionStorage);
        errdefer allocator.destroy(position);
        position.* = PositionStorage.zeroed(); // value-initialized Position (pre pos.set)

        return .{
            .binary_directory = binary_directory,
            .numa_context = numa,
            .position = position,
            .states = states,
            .options = options,
            .threads = threads,
            .tt = .{}, // empty TT; the option-driven resize allocates the table
            .network = network,
            .shared_histories = shared_histories,
            .update_context = update_context,
        };
    }

    // Destroy the owned members in reverse construction order (the referenced
    // subsystems are not owned here). Mirror the engine teardown for the owned slots.
    pub fn deinit(self: *EngineGraph, allocator: std.mem.Allocator) void {
        allocator.destroy(self.position);
        self.numa_context.deinit();
        allocator.destroy(self.numa_context);
        self.states.deinit();
        allocator.destroy(self.states);
        self.* = undefined;
    }
};

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn noopNoMoves(_: ?*anyopaque, _: *const sm.InfoShort) void {}
fn noopFull(_: ?*anyopaque, _: *const sm.InfoFull) void {}
fn noopIter(_: ?*anyopaque, _: *const sm.InfoIteration) void {}
fn noopBest(_: ?*anyopaque, _: [*:0]const u8, _: [*:0]const u8) void {}

fn testUpdateContext() UpdateContext {
    return .{
        .ctx = null,
        .on_update_no_moves = noopNoMoves,
        .on_update_full = noopFull,
        .on_iter = noopIter,
        .on_bestmove = noopBest,
    };
}

test "EngineGraph hands a SharedState bound to its own subsystems" {
    var options: u32 = 0xAA;
    var network: u32 = 0xBB;
    var position = PositionStorage.zeroed();
    var hists: u32 = 0xDD;
    var pool: ThreadPool = undefined;
    var states = try StateList.init(testing.allocator);
    defer states.deinit();
    var numa = NumaReplicationContext.init(testing.allocator, NumaConfig.empty(testing.allocator));
    defer numa.deinit();

    var graph = EngineGraph{
        .binary_directory = "/bin",
        .numa_context = &numa,
        .position = &position,
        .states = &states,
        .options = &options,
        .threads = &pool,
        .tt = .{ .cluster_count = 4096 },
        .network = &network,
        .shared_histories = &hists,
        .update_context = testUpdateContext(),
    };

    const ss = graph.sharedState();
    try testing.expectEqual(&pool, ss.threads); // typed *ThreadPool
    try testing.expectEqual(&graph.tt, ss.tt); // typed *TranspositionTable, the graph's own TT
    // Keep options/network as the graph's own members (opaque handles),
    // no longer bound into the 3-reference SharedState bundle.
    // Treat the states member as the StateList, non-empty at construction
    try testing.expect(graph.states.hasStates());
    try testing.expectEqual(@as(usize, 1), graph.states.len());
}

test "EngineGraph mints main and null managers without a vtable" {
    var pool: ThreadPool = undefined;
    var dummy: u32 = 0;
    var states = try StateList.init(testing.allocator);
    defer states.deinit();
    var numa = NumaReplicationContext.init(testing.allocator, NumaConfig.empty(testing.allocator));
    defer numa.deinit();
    var position = PositionStorage.zeroed();
    var graph = EngineGraph{
        .binary_directory = "",
        .numa_context = &numa,
        .position = &position,
        .states = &states,
        .options = &dummy,
        .threads = &pool,
        .tt = .{},
        .network = &dummy,
        .shared_histories = &dummy,
        .update_context = testUpdateContext(),
    };

    const main_mgr = graph.makeManager(true, 0);
    const null_mgr = graph.makeManager(false, 0);
    try testing.expect(main_mgr.is_main);
    try testing.expect(!null_mgr.is_main);
    try testing.expectEqual(&graph.update_context, main_mgr.updates);
}

test "EngineGraph.init builds+owns states/numa/position; deinit frees them" {
    var pool: ThreadPool = undefined;
    var options: u32 = 0;
    var network: u32 = 0;
    var hists: u32 = 0;

    // Rely on testing.allocator failing the test on any leak, so a clean deinit proves the
    // owned members are all freed.
    var graph = try EngineGraph.init(
        testing.allocator,
        "/usr/bin",
        &options,
        &pool,
        &network,
        &hists,
        testUpdateContext(),
    );
    defer graph.deinit(testing.allocator);

    // Verify the owned members were constructed
    try testing.expect(graph.states.hasStates());
    try testing.expectEqual(@as(usize, 1), graph.states.len()); // deque(1) root
    try testing.expectEqual(@as(usize, 1), graph.numa_context.getNumaConfig().numNodes()); // single node
    try testing.expectEqual(@as(usize, 0), @intFromPtr(graph.position.ptr()) % 8); // aligned
    try testing.expectEqual(@as(usize, 0), graph.tt.cluster_count); // empty until resize
    // Confirm the referenced subsystems are bound, not owned
    try testing.expectEqual(@as(*anyopaque, &options), graph.options);
    try testing.expectEqual(@as(*ThreadPool, &pool), graph.threads);
    try testing.expectEqualStrings("/usr/bin", graph.binary_directory);
}
