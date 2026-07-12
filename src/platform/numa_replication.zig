// NumaReplicationContext + NumaReplicatedBase — the NUMA replication
// framework. The context owns the NumaConfig and a registry of replicated objects
// (the engine's `network` is the live one); on a NUMA config change it notifies each
// to re-replicate. NumaReplicatedBase is the registry hook every replicated wrapper
// embeds -- it stores a function pointer (no vtable).
//
// It is the EngineGraph's `numaContext` member, and is also unit-tested here in
// isolation.

const std = @import("std");
const NumaConfig = @import("numa_config").NumaConfig;

/// Registry hook embedded by every replicated wrapper.
pub const NumaReplicatedBase = struct {
    context: ?*NumaReplicationContext = null,
    /// Re-replicate from node 0 after a config change.
    on_config_changed: *const fn (self: *NumaReplicatedBase) void,
};

pub const NumaReplicationContext = struct {
    config: NumaConfig,
    /// Tracked replicated objects. Pointer set;
    /// membership is unique. A small list suffices (the engine tracks one: network).
    tracked: std.ArrayListUnmanaged(*NumaReplicatedBase) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: NumaConfig) NumaReplicationContext {
        return .{ .config = config, .allocator = allocator };
    }

    /// Free the registry. Callers must ensure no replicas outlive the context.
    pub fn deinit(self: *NumaReplicationContext) void {
        self.tracked.deinit(self.allocator);
        self.config.deinit();
        self.* = undefined;
    }

    fn indexOf(self: *const NumaReplicationContext, obj: *NumaReplicatedBase) ?usize {
        for (self.tracked.items, 0..) |o, i| {
            if (o == obj) return i;
        }
        return null;
    }

    pub fn attach(self: *NumaReplicationContext, obj: *NumaReplicatedBase) !void {
        std.debug.assert(self.indexOf(obj) == null); // must not already be tracked
        obj.context = self;
        try self.tracked.append(self.allocator, obj);
    }

    pub fn detach(self: *NumaReplicationContext, obj: *NumaReplicatedBase) void {
        const i = self.indexOf(obj) orelse unreachable; // must be tracked
        _ = self.tracked.swapRemove(i);
    }

    /// Move a registration: oldObj (possibly invalid) → newObj, same registry slot.
    pub fn moveAttached(self: *NumaReplicationContext, old_obj: *NumaReplicatedBase, new_obj: *NumaReplicatedBase) void {
        const i = self.indexOf(old_obj) orelse unreachable;
        std.debug.assert(self.indexOf(new_obj) == null);
        self.tracked.items[i] = new_obj;
        new_obj.context = self;
    }

    /// Replace the config and notify every tracked object to re-replicate.
    pub fn setNumaConfig(self: *NumaReplicationContext, config: NumaConfig) void {
        self.config.deinit();
        self.config = config;
        for (self.tracked.items) |obj| obj.on_config_changed(obj);
    }

    pub fn getNumaConfig(self: *const NumaReplicationContext) *const NumaConfig {
        return &self.config;
    }

    pub fn trackedCount(self: *const NumaReplicationContext) usize {
        return self.tracked.items.len;
    }
};

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

var notify_count: usize = 0;
fn countingOnChange(_: *NumaReplicatedBase) void {
    notify_count += 1;
}

test "attach/detach manage the registry; setNumaConfig notifies each tracked object" {
    var ctx = NumaReplicationContext.init(testing.allocator, try NumaConfig.fromSystem(testing.allocator));
    defer ctx.deinit();
    try testing.expectEqual(@as(usize, 0), ctx.trackedCount());

    var a = NumaReplicatedBase{ .on_config_changed = countingOnChange };
    var b = NumaReplicatedBase{ .on_config_changed = countingOnChange };
    try ctx.attach(&a);
    try ctx.attach(&b);
    try testing.expectEqual(@as(usize, 2), ctx.trackedCount());
    try testing.expectEqual(&ctx, a.context.?);

    // setNumaConfig fires on_config_changed for every tracked object.
    notify_count = 0;
    ctx.setNumaConfig(try NumaConfig.fromSystem(testing.allocator));
    try testing.expectEqual(@as(usize, 2), notify_count);

    ctx.detach(&a);
    try testing.expectEqual(@as(usize, 1), ctx.trackedCount());
}

test "moveAttached swaps an object in place keeping the registry size" {
    var ctx = NumaReplicationContext.init(testing.allocator, try NumaConfig.fromSystem(testing.allocator));
    defer ctx.deinit();
    var old = NumaReplicatedBase{ .on_config_changed = countingOnChange };
    try ctx.attach(&old);
    var new = NumaReplicatedBase{ .on_config_changed = countingOnChange };
    ctx.moveAttached(&old, &new);
    try testing.expectEqual(@as(usize, 1), ctx.trackedCount());
    try testing.expectEqual(&ctx, new.context.?);
    ctx.detach(&new);
}
