//! arch_graph: the graph type, its Lakos metrics, and the SCC pass.
//!
//! Split from arch_report.zig on the 500-line lint. The seam is the file's own: this half
//! knows only about nodes and edges, the other half knows what those nodes MEAN -- which
//! build file declared them, which tripwire they answer. The dependency runs
//! arch_report -> here, one way.

const std = @import("std");

pub const Graph = struct {
    names: [][]const u8,
    adj: []std.ArrayList(usize),

    pub fn idx(self: *const Graph, name: []const u8) ?usize {
        for (self.names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
        return null;
    }
};

pub const Metrics = struct {
    n: usize,
    e: usize,
    ccd: usize,
    acd: f64,
    nccd: f64,
    normalizer: usize,
    sccs: usize,
    in_cycles: usize,
};

/// CCD = sum over components of CD(v), where CD(v) is the number of components
/// reachable from v, including v itself.
// Rewrite a path's separators to '/', in place.
//
// Every key in the file graph -- the walked names, the roots parsed out of the build files,
// the resolved import targets -- is compared with `std.mem.eql`, so all three have to spell a
// separator the same way. `Io.Dir.Walker` appends `std.fs.path.sep`, which is '\\' on Windows,
// while the build files spell every path with '/'. Without this the two never match THERE and
// always match here, so the whole file graph reads empty on the Windows runners while every
// Linux run says it is fine. `arch-report` is in the `parity-portable` aggregate, which is
// exactly what those runners run.
pub fn toPosixSep(path: []u8) []u8 {
    for (path) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return path;
}

fn computeCcd(gpa: std.mem.Allocator, g: *const Graph) !usize {
    var total: usize = 0;
    const seen = try gpa.alloc(bool, g.names.len);
    defer gpa.free(seen);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    for (0..g.names.len) |v| {
        @memset(seen, false);
        seen[v] = true;
        stack.clearRetainingCapacity();
        try stack.append(gpa, v);
        var count: usize = 0;
        while (stack.pop()) |n| {
            count += 1;
            for (g.adj[n].items) |w| if (!seen[w]) {
                seen[w] = true;
                try stack.append(gpa, w);
            };
        }
        total += count;
    }
    return total;
}

/// Compute the NCCD normalizer: CCD of a balanced binary tree of n nodes, computed EXACTLY as
/// the sum of subtree sizes over a heap-shaped tree. NCCD exists to be portable across
/// codebase sizes; approximating it (the tempting `N*log2(N+1)-N+1`) silently destroys
/// that -- it gave 2.41 where the exact normalizer gives 2.35.
fn normalizerOf(gpa: std.mem.Allocator, n: usize) !usize {
    if (n == 0) return 1;
    const size = try gpa.alloc(usize, n + 1);
    defer gpa.free(size);
    @memset(size, 1);
    var i: usize = n;
    while (i >= 1) : (i -= 1) {
        const l = 2 * i;
        const r = 2 * i + 1;
        if (l <= n) size[i] += size[l];
        if (r <= n) size[i] += size[r];
        if (i == 1) break;
    }
    var total: usize = 0;
    for (size[1 .. n + 1]) |s| total += s;
    return total;
}

/// Run Tarjan SCC iteratively (the graph is small but recursion depth is not worth the risk).
fn countSccs(gpa: std.mem.Allocator, g: *const Graph, in_cycles: *usize, list: ?*std.ArrayList(u8)) !usize {
    const n = g.names.len;
    const index = try gpa.alloc(?usize, n);
    defer gpa.free(index);
    const low = try gpa.alloc(usize, n);
    defer gpa.free(low);
    const on = try gpa.alloc(bool, n);
    defer gpa.free(on);
    @memset(index, null);
    @memset(low, 0);
    @memset(on, false);

    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    var work: std.ArrayList([2]usize) = .empty;
    defer work.deinit(gpa);

    var counter: usize = 0;
    var nontrivial: usize = 0;
    in_cycles.* = 0;

    for (0..n) |root| {
        if (index[root] != null) continue;
        try work.append(gpa, .{ root, 0 });
        while (work.items.len > 0) {
            const top = &work.items[work.items.len - 1];
            const v = top[0];
            if (top[1] == 0) {
                index[v] = counter;
                low[v] = counter;
                counter += 1;
                try stack.append(gpa, v);
                on[v] = true;
            }
            var recursed = false;
            while (top[1] < g.adj[v].items.len) {
                const w = g.adj[v].items[top[1]];
                top[1] += 1;
                if (index[w] == null) {
                    try work.append(gpa, .{ w, 0 });
                    recursed = true;
                    break;
                } else if (on[w]) {
                    low[v] = @min(low[v], index[w].?);
                }
            }
            if (recursed) continue;

            if (low[v] == index[v].?) {
                var members: usize = 0;
                var names: std.ArrayList(u8) = .empty;
                defer names.deinit(gpa);
                while (true) {
                    const w = stack.pop().?;
                    on[w] = false;
                    members += 1;
                    if (members > 1) try names.appendSlice(gpa, " <-> ");
                    try names.appendSlice(gpa, g.names[w]);
                    if (w == v) break;
                }
                if (members > 1) {
                    nontrivial += 1;
                    in_cycles.* += members;
                    if (list) |l| {
                        const line = try std.fmt.allocPrint(gpa, "    SCC({d}): {s}\n", .{ members, names.items });
                        defer gpa.free(line);
                        try l.appendSlice(gpa, line);
                    }
                }
            }
            _ = work.pop();
            if (work.items.len > 0) {
                const parent = work.items[work.items.len - 1][0];
                low[parent] = @min(low[parent], low[v]);
            }
        }
    }
    return nontrivial;
}

pub fn measure(gpa: std.mem.Allocator, g: *const Graph, scc_list: ?*std.ArrayList(u8)) !Metrics {
    var e: usize = 0;
    for (g.adj) |a| e += a.items.len;
    var in_cycles: usize = 0;
    const sccs = try countSccs(gpa, g, &in_cycles, scc_list);
    const ccd = try computeCcd(gpa, g);
    const norm = try normalizerOf(gpa, g.names.len);
    return .{
        .n = g.names.len,
        .e = e,
        .ccd = ccd,
        .acd = @as(f64, @floatFromInt(ccd)) / @as(f64, @floatFromInt(g.names.len)),
        .nccd = @as(f64, @floatFromInt(ccd)) / @as(f64, @floatFromInt(norm)),
        .normalizer = norm,
        .sccs = sccs,
        .in_cycles = in_cycles,
    };
}

pub fn printMetrics(label: []const u8, m: Metrics) void {
    std.debug.print(
        "  {s:<26} N={d:<4} E={d:<4} {s:<9} CCD={d:<5} ACD={d:>5.1} NCCD={d:.2} (norm {d})\n",
        .{
            label,
            m.n,
            m.e,
            if (m.sccs == 0) "DAG" else "NOT A DAG",
            m.ccd,
            m.acd,
            m.nccd,
            m.normalizer,
        },
    );
}

/// Free a graph's owned parts. The ArrayLists own their backing buffers, so free the
/// ELEMENTS here and let each list's own deinit release its buffer. Freeing `.items`
/// directly is a size-mismatched free (items is len-sized; the buffer is capacity-sized)
/// AND a double free once deinit runs -- which is exactly the bug that shipped: Linux and
/// Windows tolerated it silently, macOS trapped after the report had already printed OK.
pub fn deinitGraphParts(
    gpa: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
    adj: *std.ArrayList(std.ArrayList(usize)),
) void {
    for (names.items) |n| gpa.free(n);
    names.deinit(gpa);
    for (adj.items) |*a| a.deinit(gpa);
    adj.deinit(gpa);
}
