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
const builtin = @import("builtin");

const Node = std.ArrayList(usize); // hold ascending, unique CPU indices

pub const NumaConfig = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node),
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
    /// set stays ascending+unique, and missing lower nodes are created. Port upstream's
    /// `add_cpu_to_node` (numa.h): return false when the CPU is ALREADY ASSIGNED — to any
    /// node, the same one included — which `fromString` treats as fatal. Accepting a
    /// same-node repeat would make "0,0" a one-CPU node here where upstream rejects the
    /// whole policy string.
    pub fn addCpuToNode(self: *NumaConfig, node: usize, cpu: usize) error{OutOfMemory}!bool {
        if (self.isCpuAssigned(cpu)) return false;
        while (self.nodes.items.len <= node) {
            try self.nodes.append(self.allocator, .empty);
        }
        try insertSorted(&self.nodes.items[node], self.allocator, cpu);
        try self.node_by_cpu.put(self.allocator, cpu, node);
        return true;
    }

    /// Render the topology the way the "NumaPolicy" string that would produce it is
    /// written: nodes joined by ':', each an ascending comma list whose runs of
    /// consecutive CPUs collapse to `first-last`. Port upstream's `NumaConfig::to_string`
    /// (numa.h) -- it is what the engine reports as "Available processors", so a
    /// divergence here is a divergence in the UCI transcript. Hand the caller an owned
    /// slice.
    pub fn toString(self: *const NumaConfig, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(gpa);

        for (self.nodes.items, 0..) |cpus, node_index| {
            if (node_index != 0) try out.append(gpa, ':');

            var i: usize = 0;
            var first_set = true;
            while (i < cpus.items.len) {
                // Extend the run while the next CPU is exactly one higher.
                var last = i;
                while (last + 1 < cpus.items.len and
                    cpus.items[last + 1] == cpus.items[last] + 1) : (last += 1)
                {}

                if (!first_set) try out.append(gpa, ',');
                first_set = false;

                if (last != i) {
                    try out.print(gpa, "{d}-{d}", .{ cpus.items[i], cpus.items[last] });
                } else {
                    try out.print(gpa, "{d}", .{cpus.items[i]});
                }
                i = last + 1;
            }
        }

        return out.toOwnedSlice(gpa);
    }

    /// Build the topology from the system: one node holding every CPU the process may run
    /// on, not custom-affinity. Take the CPU INDICES from the affinity mask rather than
    /// counting them and numbering 0..n-1 — upstream's `from_system_numa` respects the
    /// process affinity, so a process pinned to `4-7` is a node of {4,5,6,7}, and
    /// numbering from zero would report a topology the engine is not running on. Fall
    /// back to 0..n-1 where there is no mask to read: off Linux, and on Linux when the
    /// syscall is refused (a seccomp sandbox or a filtered container). Leave a multi-node
    /// /sys read + BundledL3 split unimplemented (it only matters on real multi-socket
    /// hosts, and the WSL2/CI gate target exposes no NUMA nodes).
    pub fn fromSystem(allocator: std.mem.Allocator) error{OutOfMemory}!NumaConfig {
        var cfg = NumaConfig.empty(allocator);
        errdefer cfg.deinit();

        if (builtin.os.tag == .linux) {
            const linux = std.os.linux;
            var set: linux.cpu_set_t = undefined;
            @memset(std.mem.asBytes(&set), 0);
            // Check the return: on failure the mask stays all-zero and the bit walk below
            // would report an EMPTY cpu set as if the process were bound to nothing.
            const rc = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set);
            if (linux.errno(rc) == .SUCCESS) {
                const bits = @bitSizeOf(usize);
                const total = set.len * bits;
                var found = false;
                var i: usize = 0;
                while (i < total) : (i += 1) {
                    if ((set[i / bits] >> @as(u6, @intCast(i % bits))) & 1 == 0) continue;
                    if (!try cfg.addCpuToNode(0, i)) unreachable;
                    found = true;
                }
                if (found) return cfg;
            }
        }

        const count = @max(std.Thread.getCpuCount() catch 1, 1);
        var c: usize = 0;
        while (c < count) : (c += 1) {
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
    // in particular empty ones. Mirror upstream numa.h:756-794 exactly.
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

/// Match C's `isspace` for the default locale, which is what `strtoull` skips and what
/// upstream's accept test calls.
/// Port upstream's `str_to_size_t` (misc.cpp) exactly, including the parts that read as
/// accidents but are load-bearing:
///
///   * an empty string, or one whose FIRST byte is '-', is rejected up front;
///   * otherwise apply `strtoull`'s rule -- skip leading whitespace, take an optional
///     sign, consume base-10 digits -- and accept only when the first UNCONSUMED byte is
///     the terminator or whitespace (this is the trailing-whitespace allowance upstream
///     added in b4ea9205 so a sysfs read ending in '\n' still parses);
///   * on NO conversion `strtoull` leaves endptr at the ORIGINAL start, so the accept test
///     reads byte 0 rather than the position the whitespace skip reached. " x" is
///     therefore accepted as 0, and "x" is rejected. Reproduce that, or the two engines
///     answer differently on the same policy string;
///   * a sign that survives the byte-0 guard (" -5") wraps, as unsigned negation does.
///
/// Overflow is ERANGE, i.e. a reject. `usize` is 64-bit here, so upstream's separate
/// `value > numeric_limits<usize>::max()` test cannot fire and has no counterpart.

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "addCpuToNode keeps nodes ascending/unique and one node per cpu" {
    var cfg = NumaConfig.empty(testing.allocator);
    defer cfg.deinit();

    try testing.expect(try cfg.addCpuToNode(0, 5));
    try testing.expect(try cfg.addCpuToNode(0, 1));
    // Reject a repeat even onto the SAME node, as upstream's is_cpu_assigned test does.
    try testing.expect(!(try cfg.addCpuToNode(0, 5)));
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

test "toString collapses consecutive runs and joins nodes with ':'" {
    // Build each shape by hand rather than through the policy parser: this file owns the
    // renderer, and policy.zig imports it, so a fixture that parsed would put the two in
    // a cycle. Each case pairs the node layout with the string it must render as.
    const Case = struct { nodes: []const []const usize, want: []const u8 };
    const cases = [_]Case{
        .{ .nodes = &.{&.{ 0, 1, 2, 3 }}, .want = "0-3" }, // one run
        .{ .nodes = &.{&.{ 0, 2, 4, 6 }}, .want = "0,2,4,6" }, // all singletons
        .{ .nodes = &.{&.{ 5, 7, 9 }}, .want = "5,7,9" },
        .{ .nodes = &.{&.{7}}, .want = "7" }, // a lone cpu is not a range
        .{ .nodes = &.{ &.{ 0, 1 }, &.{ 2, 3 } }, .want = "0-1:2-3" }, // two nodes
        .{ .nodes = &.{ &.{ 0, 1, 2, 3, 8 }, &.{ 4, 5, 6, 7 } }, .want = "0-3,8:4-7" }, // run + gap
    };
    for (cases) |case_entry| {
        var cfg = NumaConfig.empty(testing.allocator);
        defer cfg.deinit();
        for (case_entry.nodes, 0..) |cpus, node| {
            for (cpus) |cpu| try testing.expect(try cfg.addCpuToNode(node, cpu));
        }
        const rendered = try cfg.toString(testing.allocator);
        defer testing.allocator.free(rendered);
        try testing.expectEqualStrings(case_entry.want, rendered);
    }

    // Render an empty config as the empty string, as upstream's loop does.
    var none = NumaConfig.empty(testing.allocator);
    defer none.deinit();
    const empty_str = try none.toString(testing.allocator);
    defer testing.allocator.free(empty_str);
    try testing.expectEqualStrings("", empty_str);
}

test "fromSystem names the CPUs the process may run on, not 0..n-1" {
    var cfg = try NumaConfig.fromSystem(testing.allocator);
    defer cfg.deinit();

    // One node, non-empty, and every index it holds is one this process can be scheduled
    // on -- the property that makes the reported topology the one actually in use.
    try testing.expectEqual(@as(usize, 1), cfg.numNodes());
    try testing.expect(cfg.numCpus() >= 1);
    try testing.expect(!cfg.custom_affinity);
    try testing.expectEqual(cfg.numCpus(), cfg.numCpusInNode(0));

    // Hold the node ascending and unique, which toString's run-collapsing relies on.
    const cpus = cfg.nodes.items[0].items;
    var prev: ?usize = null;
    for (cpus) |cpu| {
        if (prev) |p| try testing.expect(cpu > p);
        prev = cpu;
    }
}

test "suggestsBindingThreads: custom affinity binds; a single node never does" {
    // bind always for user-set affinity
    var custom = NumaConfig.empty(testing.allocator);
    defer custom.deinit();
    for (0..4) |c| try testing.expect(try custom.addCpuToNode(0, c));
    custom.custom_affinity = true;
    try testing.expect(custom.suggestsBindingThreads(1)); // let custom affinity override the <=1 rule

    // build a system-style single node of 4 cpus
    var sys = NumaConfig.empty(testing.allocator);
    defer sys.deinit();
    for (0..4) |c| _ = try sys.addCpuToNode(0, c);
    try testing.expect(!sys.suggestsBindingThreads(1)); // never bind a single thread
    try testing.expect(!sys.suggestsBindingThreads(4));
    // Upstream ends the rule with `&& nodes.size() > 1` (numa.h:793): with ONE node there
    // is nothing to distribute across, so binding is never suggested at any thread count.
    try testing.expect(!sys.suggestsBindingThreads(5));
    try testing.expect(!sys.suggestsBindingThreads(64));
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

test "NumaConfig.distributeThreads unwinds leak-free on every allocation failure" {
    const T = struct {
        fn run(a: std.mem.Allocator) !void {
            // Force the alloc path with two nodes.
            var cfg = NumaConfig.empty(a);
            defer cfg.deinit();
            for (0..2) |c| _ = try cfg.addCpuToNode(0, c);
            for (2..6) |c| _ = try cfg.addCpuToNode(1, c);
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
