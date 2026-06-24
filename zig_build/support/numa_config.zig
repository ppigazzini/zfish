// Native NumaConfig — the post-src/ replacement for the C++ NumaConfig
// (std::vector<std::set<CpuIndex>> nodes + nodeByCpu map). Models the NUMA topology
// the engine's numaContext holds: a list of NUMA nodes, each an ascending, unique
// set of CPU indices, plus a cpu->node index and the customAffinity flag.
//
// This iteration covers the data structure + the queries + from_string (user
// "NumaPolicy a-b:c-d" parsing) + suggests_binding_threads (the bind/no-bind
// decision). DEFERRED to the flip (and only ever exercised when do_bind is true,
// which the single-node WSL2 target never hits): from_system (the /sys topology
// read + BundledL3 splitting) and distribute_threads / execute_on_numa_node (the
// NUMA binding syscalls). On the gate target from_system yields a single node, so
// the engine builds one node holding every online CPU; suggests_binding is false.
//
// Native-graph cut, iteration 3 (REPORT-9 Annex B, ITERATION-157). Ready-to-wire:
// the live runtime still uses the C++ NumaConfig until the atomic flip.

const std = @import("std");

const Node = std.ArrayListUnmanaged(usize); // ascending, unique CPU indices

pub const NumaConfig = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node),
    node_by_cpu: std.AutoHashMapUnmanaged(usize, usize),
    /// Set when the topology came from a user "NumaPolicy" string rather than the
    /// system; forces thread binding (matches the C++ flag).
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

    /// Add `cpu` to NUMA node `node`, mirroring C++ add_cpu_to_node: a CPU belongs
    /// to at most one node, the node's set stays ascending+unique, and missing
    /// lower nodes are created. Returns false if `cpu` is already assigned
    /// elsewhere (the C++ caller treats that as fatal).
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
    /// Empty node strings are skipped (do not advance the node index), matching C++.
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

    /// Whether to bind threads to NUMA nodes (C++ suggests_binding_threads, the
    /// part the gates reach): bind if the affinity is user-set; never bind a single
    /// thread; otherwise bind only if the threads cannot fit the largest node.
    pub fn suggestsBindingThreads(self: *const NumaConfig, num_threads: usize) bool {
        if (self.custom_affinity) return true;
        if (num_threads <= 1) return false;
        var largest: usize = 0;
        for (self.nodes.items) |node| {
            if (node.items.len > largest) largest = node.items.len;
        }
        // Threads fit the largest node with headroom -> no need to bind.
        return num_threads > largest;
    }
};

fn insertSorted(node: *Node, allocator: std.mem.Allocator, cpu: usize) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i < node.items.len and node.items[i] < cpu) : (i += 1) {}
    if (i < node.items.len and node.items[i] == cpu) return; // unique
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
    try testing.expect(try cfg.addCpuToNode(0, 5)); // duplicate same node: ok, no-op
    try testing.expect(try cfg.addCpuToNode(1, 9));

    try testing.expectEqual(@as(usize, 2), cfg.numNodes());
    try testing.expectEqual(@as(usize, 2), cfg.numCpusInNode(0));
    try testing.expectEqualSlices(usize, &.{ 1, 5 }, cfg.nodes.items[0].items);
    try testing.expectEqual(@as(usize, 3), cfg.numCpus());
    try testing.expect(cfg.isCpuAssigned(9));
    try testing.expect(!cfg.isCpuAssigned(2));

    // re-adding cpu 5 to a different node is rejected
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

test "suggestsBindingThreads: custom affinity binds; single node sized by threads" {
    // user-set affinity always binds
    var custom = try NumaConfig.fromString(testing.allocator, "0-3");
    defer custom.deinit();
    try testing.expect(custom.suggestsBindingThreads(1)); // custom overrides the <=1 rule

    // system-style single node of 4 cpus
    var sys = NumaConfig.empty(testing.allocator);
    defer sys.deinit();
    for (0..4) |c| _ = try sys.addCpuToNode(0, c);
    try testing.expect(!sys.suggestsBindingThreads(1)); // never bind a single thread
    try testing.expect(!sys.suggestsBindingThreads(4)); // fits the node -> no bind
    try testing.expect(sys.suggestsBindingThreads(5)); // exceeds the node -> bind
}

test "fromString rejects malformed input" {
    try testing.expectError(error.BadNuma, NumaConfig.fromString(testing.allocator, "3-1")); // hi<lo
    try testing.expectError(error.BadNuma, NumaConfig.fromString(testing.allocator, "x"));
}
