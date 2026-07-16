// Model the NUMA topology the engine's numaContext holds: a
// list of NUMA nodes, each an ascending, unique set of CPU indices, plus a
// cpu->node index and the customAffinity flag.
//
// Cover the data structure, the queries, fromString (user "NumaPolicy a-b:c-d"
// parsing), fromSystem, distributeThreads, and suggestsBindingThreads (the
// bind/no-bind decision). Note fromSystem builds a single node holding every online CPU
// -- the single-node target the engine runs on -- so suggestsBinding is false there;
// leave a multi-node /sys topology read + BundledL3 split unimplemented.

const std = @import("std");

const Node = std.ArrayListUnmanaged(usize); // hold ascending, unique CPU indices

pub const NumaConfig = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node),
    node_by_cpu: std.AutoHashMapUnmanaged(usize, usize),
    /// Flag that the topology came from a user "NumaPolicy" string rather than the
    /// system; force thread binding.
    custom_affinity: bool,

    pub fn empty(allocator: std.mem.Allocator) NumaConfig {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .node_by_cpu = .empty,
            .custom_affinity = false,
        };
    }

    pub fn deinit(self: *NumaConfig) void {
        for (self.nodes.items) |*node| node.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.node_by_cpu.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn numNodes(self: *const NumaConfig) usize {
        return self.nodes.items.len;
    }

    pub fn numCpusInNode(self: *const NumaConfig, node: usize) usize {
        return self.nodes.items[node].items.len;
    }

    pub fn numCpus(self: *const NumaConfig) usize {
        return self.node_by_cpu.count();
    }

    pub fn isCpuAssigned(self: *const NumaConfig, cpu: usize) bool {
        return self.node_by_cpu.contains(cpu);
    }

    /// Add `cpu` to NUMA node `node`: a CPU belongs to at most one node, the node's
    /// set stays ascending+unique, and missing lower nodes are created. Return false
    /// if `cpu` is already assigned elsewhere (the caller treats that as fatal).
    pub fn addCpuToNode(self: *NumaConfig, node: usize, cpu: usize) error{OutOfMemory}!bool {
        if (self.node_by_cpu.get(cpu)) |existing| return existing == node;
        while (self.nodes.items.len <= node) {
            try self.nodes.append(self.allocator, .empty);
        }
        try insertSorted(&self.nodes.items[node], self.allocator, cpu);
        try self.node_by_cpu.put(self.allocator, cpu, node);
        return true;
    }

    /// Parse a "NumaPolicy" string: nodes separated by ':', each a comma list of
    /// CPU indices or ranges, e.g. "0-3,8:4-7" -> node0 {0,1,2,3,8}, node1 {4,5,6,7}.
    /// Skip empty node strings (do not advance the node index).
    pub fn fromString(allocator: std.mem.Allocator, s: []const u8) error{ OutOfMemory, BadNuma }!NumaConfig {
        var cfg = NumaConfig.empty(allocator);
        errdefer cfg.deinit();

        var node: usize = 0;
        var node_it = std.mem.splitScalar(u8, s, ':');
        while (node_it.next()) |node_str| {
            var any = false;
            var range_it = std.mem.splitScalar(u8, node_str, ',');
            while (range_it.next()) |range| {
                if (range.len == 0) continue;
                const lo, const hi = parseRange(range) catch return error.BadNuma;
                var cpu = lo;
                while (cpu <= hi) : (cpu += 1) {
                    if (!try cfg.addCpuToNode(node, cpu)) return error.BadNuma;
                    any = true;
                }
            }
            if (any) node += 1;
        }
        cfg.custom_affinity = true;
        return cfg;
    }

    /// Build the topology from the system. Fall back to a single node (the only path the
    /// WSL2/CI gate target takes — its /sys exposes no NUMA nodes): one node holding
    /// every online CPU, not custom-affinity. Leave a multi-node /sys read + BundledL3
    /// split unimplemented (it only matters on real multi-socket hosts).
    pub fn fromSystem(allocator: std.mem.Allocator) error{OutOfMemory}!NumaConfig {
        var cfg = NumaConfig.empty(allocator);
        errdefer cfg.deinit();
        const count = std.Thread.getCpuCount() catch 1;
        var c: usize = 0;
        while (c < @max(count, 1)) : (c += 1) {
            if (!try cfg.addCpuToNode(0, c)) unreachable;
        }
        return cfg;
    }

    /// Assign each of `num_threads` threads to a NUMA node, balancing by fill ratio:
    /// single node -> all node 0; otherwise greedily place each thread on the node
    /// with the lowest (occupation+1)/size. Let the caller own the returned slice.
    pub fn distributeThreads(self: *const NumaConfig, allocator: std.mem.Allocator, num_threads: usize) error{OutOfMemory}![]usize {
        const ns = try allocator.alloc(usize, num_threads);
        errdefer allocator.free(ns);
        if (self.nodes.items.len <= 1) {
            @memset(ns, 0);
            return ns;
        }
        const occupation = try allocator.alloc(usize, self.nodes.items.len);
        defer allocator.free(occupation);
        @memset(occupation, 0);
        for (ns) |*slot| {
            var best: usize = 0;
            var best_fill: f32 = std.math.floatMax(f32);
            for (self.nodes.items, 0..) |node, n| {
                const fill = @as(f32, @floatFromInt(occupation[n] + 1)) /
                    @as(f32, @floatFromInt(node.items.len));
                if (fill < best_fill) {
                    best = n;
                    best_fill = fill;
                }
            }
            slot.* = best;
            occupation[best] += 1;
        }
        return ns;
    }

    /// Decide whether to bind threads to NUMA nodes: bind if the affinity is user-set;
    /// never bind a single thread; otherwise bind only if the threads cannot fit
    /// the largest node.
    // Advise binding when the threads cannot reasonably be contained by the OS within the
    // first NUMA node: unbound threads can only use replicated objects from node 0, so we
    // lose performance once the OS schedules elsewhere. Also advise it when there are
    // enough threads to spread across nodes with minimal disparity. Ignore small nodes,
    // in particular empty ones. Mirror upstream numa.h:756-794 exactly; the previous
    // `num_threads > largest` was a different (and far stricter) rule -- it never fired on
    // a 2-node host until the thread count exceeded a WHOLE node, so binding was
    // effectively unreachable.
    pub fn suggestsBindingThreads(self: *const NumaConfig, num_threads: usize) bool {
        // A mismatch between the user's affinity and the OS's means binding is required
        // to keep threads on the correct processors.
        if (self.custom_affinity) return true;

        // A single thread cannot be distributed, so never bind it.
        if (num_threads <= 1) return false;

        var largest_node_size: usize = 0;
        for (self.nodes.items) |node| {
            if (node.items.len > largest_node_size) largest_node_size = node.items.len;
        }

        // Treat a node holding <= 60% of the largest node's CPUs as small.
        const small_node_threshold: f64 = 0.6;
        var num_not_small_nodes: usize = 0;
        for (self.nodes.items) |node| {
            const ratio = @as(f64, @floatFromInt(node.items.len)) /
                @as(f64, @floatFromInt(largest_node_size));
            if (!(ratio <= small_node_threshold)) num_not_small_nodes += 1;
        }

        return (num_threads > largest_node_size / 2 or
            num_threads >= num_not_small_nodes * 4) and
            self.nodes.items.len > 1;
    }
};

fn insertSorted(node: *Node, allocator: std.mem.Allocator, cpu: usize) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i < node.items.len and node.items[i] < cpu) : (i += 1) {}
    if (i < node.items.len and node.items[i] == cpu) return; // keep unique
    try node.insert(allocator, i, cpu);
}

fn parseRange(range: []const u8) error{BadNuma}!struct { usize, usize } {
    if (std.mem.indexOfScalar(u8, range, '-')) |dash| {
        const lo = std.fmt.parseInt(usize, range[0..dash], 10) catch return error.BadNuma;
        const hi = std.fmt.parseInt(usize, range[dash + 1 ..], 10) catch return error.BadNuma;
        if (hi < lo) return error.BadNuma;
        return .{ lo, hi };
    }
    const v = std.fmt.parseInt(usize, range, 10) catch return error.BadNuma;
    return .{ v, v };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "addCpuToNode keeps nodes ascending/unique and one node per cpu" {
    var cfg = NumaConfig.empty(testing.allocator);
    defer cfg.deinit();

    try testing.expect(try cfg.addCpuToNode(0, 5));
    try testing.expect(try cfg.addCpuToNode(0, 1));
    try testing.expect(try cfg.addCpuToNode(0, 5)); // accept duplicate on same node: no-op
    try testing.expect(try cfg.addCpuToNode(1, 9));

    try testing.expectEqual(@as(usize, 2), cfg.numNodes());
    try testing.expectEqual(@as(usize, 2), cfg.numCpusInNode(0));
    try testing.expectEqualSlices(usize, &.{ 1, 5 }, cfg.nodes.items[0].items);
    try testing.expectEqual(@as(usize, 3), cfg.numCpus());
    try testing.expect(cfg.isCpuAssigned(9));
    try testing.expect(!cfg.isCpuAssigned(2));

    // reject re-adding cpu 5 to a different node
    try testing.expect(!(try cfg.addCpuToNode(1, 5)));
}

test "fromString parses ranges and lists into ordered nodes" {
    var cfg = try NumaConfig.fromString(testing.allocator, "0-3,8:4-7");
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 2), cfg.numNodes());
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 8 }, cfg.nodes.items[0].items);
    try testing.expectEqualSlices(usize, &.{ 4, 5, 6, 7 }, cfg.nodes.items[1].items);
    try testing.expectEqual(@as(usize, 9), cfg.numCpus());
    try testing.expect(cfg.custom_affinity);
}

test "fromString skips empty node segments without advancing the node index" {
    var cfg = try NumaConfig.fromString(testing.allocator, "0-1::2-3");
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 2), cfg.numNodes());
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, cfg.nodes.items[0].items);
    try testing.expectEqualSlices(usize, &.{ 2, 3 }, cfg.nodes.items[1].items);
}

test "suggestsBindingThreads: custom affinity binds; a single node never does" {
    // bind always for user-set affinity
    var custom = try NumaConfig.fromString(testing.allocator, "0-3");
    defer custom.deinit();
    try testing.expect(custom.suggestsBindingThreads(1)); // let custom affinity override the <=1 rule

    // build a system-style single node of 4 cpus
    var sys = NumaConfig.empty(testing.allocator);
    defer sys.deinit();
    for (0..4) |c| _ = try sys.addCpuToNode(0, c);
    try testing.expect(!sys.suggestsBindingThreads(1)); // never bind a single thread
    try testing.expect(!sys.suggestsBindingThreads(4));
    // Upstream ends the rule with `&& nodes.size() > 1` (numa.h:793): with ONE node there
    // is nothing to distribute across, so binding is never suggested at any thread count.
    // This case asserted `true` here, pinning the old `num_threads > largest` rule --
    // the test encoded the divergence it should have caught.
    try testing.expect(!sys.suggestsBindingThreads(5));
    try testing.expect(!sys.suggestsBindingThreads(64));
}

test "fromString rejects malformed input" {
    try testing.expectError(error.BadNuma, NumaConfig.fromString(testing.allocator, "3-1")); // reject hi<lo
    try testing.expectError(error.BadNuma, NumaConfig.fromString(testing.allocator, "x"));
}

test "fromSystem yields a single non-empty node, not custom affinity" {
    var cfg = try NumaConfig.fromSystem(testing.allocator);
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 1), cfg.numNodes());
    try testing.expect(cfg.numCpusInNode(0) >= 1);
    try testing.expect(!cfg.custom_affinity);
    try testing.expect(!cfg.suggestsBindingThreads(1)); // cover single node, single thread
}

test "distributeThreads: single node -> all node 0" {
    var cfg = try NumaConfig.fromSystem(testing.allocator);
    defer cfg.deinit();
    const ns = try cfg.distributeThreads(testing.allocator, 5);
    defer testing.allocator.free(ns);
    try testing.expectEqualSlices(usize, &.{ 0, 0, 0, 0, 0 }, ns);
}

test "distributeThreads: multi-node places every thread and favors the larger node" {
    var cfg = NumaConfig.empty(testing.allocator);
    defer cfg.deinit();
    for (0..2) |c| _ = try cfg.addCpuToNode(0, c); // build node0: 2 cpus
    for (2..6) |c| _ = try cfg.addCpuToNode(1, c); // build node1: 4 cpus

    const ns = try cfg.distributeThreads(testing.allocator, 6);
    defer testing.allocator.free(ns);
    try testing.expectEqual(@as(usize, 6), ns.len);
    var n0: usize = 0;
    var n1: usize = 0;
    for (ns) |n| {
        try testing.expect(n < 2);
        if (n == 0) n0 += 1 else n1 += 1;
    }
    try testing.expectEqual(@as(usize, 6), n0 + n1);
    try testing.expect(n1 > n0); // expect the larger node to take more threads
}

// Gate allocation failures: checkAllAllocationFailures fails each successive
// allocation and asserts every unwind returns error.OutOfMemory leak-free -- covering
// the ArrayList/HashMap growth inside addCpuToNode (reached via fromString) and the
// two-slice distributeThreads, whose errdefer/deinit chains must hold on any partial
// failure. Confirm the container-owned allocations here need no per-item errdefer
// (the state_list gate found a real leak this way).
test "NumaConfig.fromString unwinds leak-free on every allocation failure" {
    const T = struct {
        fn run(a: std.mem.Allocator) !void {
            var cfg = try NumaConfig.fromString(a, "0-3,8:4-7");
            cfg.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, T.run, .{});
}

test "NumaConfig.distributeThreads unwinds leak-free on every allocation failure" {
    const T = struct {
        fn run(a: std.mem.Allocator) !void {
            var cfg = try NumaConfig.fromString(a, "0-1:2-5"); // force the alloc path with 2 nodes
            defer cfg.deinit();
            const ns = try cfg.distributeThreads(a, 4);
            a.free(ns);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, T.run, .{});
}

test "numa: suggestsBindingThreads matches upstream's rule" {
    const a = std.testing.allocator;
    var cfg = NumaConfig.empty(a);
    defer cfg.deinit();

    // Two equal 8-CPU nodes: largest=8, not-small=2.
    // Upstream: (n > 8/2 || n >= 2*4) && nodes>1  ->  binds from n=5.
    // The old `n > largest` rule needed n=9: a whole node's worth, so `auto` never bound.
    var node: usize = 0;
    while (node < 2) : (node += 1) {
        var cpu: usize = 0;
        while (cpu < 8) : (cpu += 1) _ = try cfg.addCpuToNode(node, node * 8 + cpu);
    }
    try std.testing.expectEqual(true, cfg.nodes.items.len == 2);

    try std.testing.expectEqual(false, cfg.suggestsBindingThreads(1)); // never bind one
    try std.testing.expectEqual(false, cfg.suggestsBindingThreads(4)); // 4 > 4 is false
    try std.testing.expectEqual(true, cfg.suggestsBindingThreads(5)); // 5 > 4  -> bind
    try std.testing.expectEqual(true, cfg.suggestsBindingThreads(8)); // 8 >= 2*4 -> bind
}

test "numa: a single node never suggests binding" {
    const a = std.testing.allocator;
    var cfg = NumaConfig.empty(a);
    defer cfg.deinit();
    var cpu: usize = 0;
    while (cpu < 16) : (cpu += 1) _ = try cfg.addCpuToNode(0, cpu);
    // `&& nodes.size() > 1` -- the guard the old rule lacked entirely.
    try std.testing.expectEqual(false, cfg.suggestsBindingThreads(16));
}
