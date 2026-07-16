//! arch_report: the coupling report + the two tripwires the compiler will not give (G1 / D.2).
//!
//! Reports Lakos CCD/ACD/NCCD over zfish's import graphs, at BOTH granularities,
//! because zfish has two and they disagree: the module graph is a DAG, the file graph
//! is not (search_main <-> search_back, the alpha-beta mutual recursion). Always state
//! which graph a number came from.
//!
//! REPORT, never gate, on the numbers. Lakos's NCCD ~1.0 is calibrated for C++ builds
//! where a cycle costs compile time; zfish compiles as one LLVM module, so a cycle
//! would cost no compile time, no binary size, no test isolation. Importing the
//! threshold would be cargo cult. The gateable properties here are BINARY:
//!
//!   DAG           the module graph is acyclic. Zig does NOT enforce this -- modules
//!                 A<->B via mutual addImport compile, LINK and RUN (verified by
//!                 spike). The DAG is a design decision, so it needs a tripwire.
//!   UNUSED EDGES  a module wired via addImport but never @import'ed by the target's
//!                 source. Zig does not catch this either: an unused import compiles,
//!                 links and runs. `zig build test-graph` proves a module has AT LEAST
//!                 its declared deps; nothing proved AT MOST. 14 are live today, all
//!                 on main.zig's exe root.
//!
//! THE TABLE IS NOT THE GRAPH. `module_edges` is data; `addImport` is the wiring. The
//! build also wires misc->build_options and main.zig -- the shipped entry point, which
//! is not in the table at all and is the composition root the whole architecture rests
//! on. Parse the table alone and you report a graph that excludes the program's entry
//! point. This tool parses the addImport call sites, and reports the table-only
//! subgraph separately and clearly labelled.

const std = @import("std");
const Io = std.Io;

const Graph = struct {
    names: [][]const u8,
    adj: []std.ArrayList(usize),

    fn idx(self: *const Graph, name: []const u8) ?usize {
        for (self.names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
        return null;
    }
};

const Metrics = struct {
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

/// The NCCD normalizer: CCD of a balanced binary tree of n nodes, computed EXACTLY as
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

/// Tarjan SCC, iterative (the graph is small but recursion depth is not worth the risk).
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

fn measure(gpa: std.mem.Allocator, g: *const Graph, scc_list: ?*std.ArrayList(u8)) !Metrics {
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

fn printMetrics(label: []const u8, m: Metrics) void {
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
fn deinitGraphParts(
    gpa: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
    adj: *std.ArrayList(std.ArrayList(usize)),
) void {
    for (names.items) |n| gpa.free(n);
    names.deinit(gpa);
    for (adj.items) |*a| a.deinit(gpa);
    adj.deinit(gpa);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const build_src = try Io.Dir.cwd().readFileAlloc(io, "build.zig", gpa, .unlimited);
    defer gpa.free(build_src);

    var failed = false;

    // ---- module graph -------------------------------------------------------
    // Nodes: the declared table + build_options + main (the exe root). Edges: the
    // module_edges table + every addImport call site.
    var names: std.ArrayList([]const u8) = .empty;
    var adj: std.ArrayList(std.ArrayList(usize)) = .empty;

    var declared: usize = 0;
    {
        var it = std.mem.splitSequence(u8, build_src, ".{ .name = \"");
        _ = it.next();
        while (it.next()) |chunk| {
            const end = std.mem.indexOfScalar(u8, chunk, '"') orelse continue;
            const rest = chunk[end..];
            if (std.mem.indexOf(u8, rest[0..@min(rest.len, 24)], ".path = \"") == null) continue;
            try names.append(gpa, try gpa.dupe(u8, chunk[0..end]));
            try adj.append(gpa, .empty);
            declared += 1;
        }
    }
    for ([_][]const u8{ "build_options", "main" }) |extra| {
        try names.append(gpa, try gpa.dupe(u8, extra));
        try adj.append(gpa, .empty);
    }
    var g = Graph{ .names = names.items, .adj = adj.items };
    defer deinitGraphParts(gpa, &names, &adj);

    var table_edges: usize = 0;
    {
        var it = std.mem.splitSequence(u8, build_src, ".{ .from = \"");
        _ = it.next();
        while (it.next()) |chunk| {
            const fe = std.mem.indexOfScalar(u8, chunk, '"') orelse continue;
            const from = chunk[0..fe];
            const to_key = ".to = \"";
            const ti = std.mem.indexOf(u8, chunk, to_key) orelse continue;
            const trest = chunk[ti + to_key.len ..];
            const te = std.mem.indexOfScalar(u8, trest, '"') orelse continue;
            const to = trest[0..te];
            const fi = g.idx(from) orelse continue;
            const tid = g.idx(to) orelse continue;
            try adj.items[fi].append(gpa, tid);
            table_edges += 1;
        }
    }

    // Every addImport call site: `<owner>.addImport("<name>", ...)`. The table is data;
    // THIS is the wiring. misc->build_options and main.zig's 45 edges live only here.
    var wired_main: usize = 0;
    {
        var line_it = std.mem.splitScalar(u8, build_src, '\n');
        while (line_it.next()) |line| {
            const key = ".addImport(\"";
            const ki = std.mem.indexOf(u8, line, key) orelse continue;
            const t = std.mem.trimStart(u8, line, " ");
            if (std.mem.startsWith(u8, t, "//")) continue;
            const rest = line[ki + key.len ..];
            const ne = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            const imported = rest[0..ne];
            const owner: []const u8 = if (std.mem.startsWith(u8, t, "exe.root_module"))
                "main"
            else if (std.mem.indexOf(u8, line, "mods.get(\"") != null and std.mem.indexOf(u8, line, "\").?.addImport") != null) blk: {
                const ok = "mods.get(\"";
                const oi = std.mem.indexOf(u8, line, ok).?;
                const orest = line[oi + ok.len ..];
                const oe = std.mem.indexOfScalar(u8, orest, '"') orelse continue;
                break :blk orest[0..oe];
            } else continue;
            const fi = g.idx(owner) orelse continue;
            const tid = g.idx(imported) orelse continue;
            var dup = false;
            for (adj.items[fi].items) |x| if (x == tid) {
                dup = true;
            };
            if (dup) continue;
            try adj.items[fi].append(gpa, tid);
            if (std.mem.eql(u8, owner, "main")) wired_main += 1;
        }
    }

    var scc_text: std.ArrayList(u8) = .empty;
    defer scc_text.deinit(gpa);
    const mod = try measure(gpa, &g, &scc_text);

    std.debug.print("\narch-report @ the module graph the build WIRES (the program)\n", .{});
    printMetrics("modules (real)", mod);
    std.debug.print("    declared in the table: {d} modules / {d} edges; +build_options +main\n", .{ declared, table_edges });

    // ---- unused declared edges ---------------------------------------------
    // main.zig is wired to 45 modules but @imports far fewer. Zig accepts the gap
    // silently, so it is invisible without this. Report, do not gate: dead edges cost
    // no bytes and no compile time -- the finding is that nothing SEES them.
    const main_src = try Io.Dir.cwd().readFileAlloc(io, "src/shell/main.zig", gpa, .unlimited);
    defer gpa.free(main_src);
    var unused: std.ArrayList([]const u8) = .empty;
    defer unused.deinit(gpa);
    const main_i = g.idx("main").?;
    for (adj.items[main_i].items) |t| {
        const needle = try std.fmt.allocPrint(gpa, "@import(\"{s}\")", .{g.names[t]});
        defer gpa.free(needle);
        if (std.mem.indexOf(u8, main_src, needle) == null) try unused.append(gpa, g.names[t]);
    }
    std.debug.print("\n  main.zig: wired {d}, @imports {d} -> {d} DECLARED-BUT-UNUSED edges\n", .{
        wired_main, wired_main - unused.items.len, unused.items.len,
    });
    for (unused.items) |u| std.debug.print("    unused: {s}\n", .{u});

    // ---- file graph ---------------------------------------------------------
    var fnames: std.ArrayList([]const u8) = .empty;
    var fadj: std.ArrayList(std.ArrayList(usize)) = .empty;
    var dir = try Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try fnames.append(gpa, try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path}));
        try fadj.append(gpa, .empty);
    }
    var fg = Graph{ .names = fnames.items, .adj = fadj.items };
    defer deinitGraphParts(gpa, &fnames, &fadj);
    for (fg.names, 0..) |path, i| {
        const body = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(body);
        const dirname = std.fs.path.dirname(path) orelse "src";
        var it = std.mem.splitSequence(u8, body, "@import(\"");
        _ = it.next();
        while (it.next()) |chunk| {
            const e = std.mem.indexOfScalar(u8, chunk, '"') orelse continue;
            const imp = chunk[0..e];
            if (!std.mem.endsWith(u8, imp, ".zig")) continue;
            const joined = try std.fs.path.join(gpa, &.{ dirname, imp });
            defer gpa.free(joined);
            const resolved = try std.fs.path.resolve(gpa, &.{joined});
            defer gpa.free(resolved);
            const cwd_prefix = try std.fs.path.resolve(gpa, &.{"."});
            defer gpa.free(cwd_prefix);
            const rel = if (std.mem.startsWith(u8, resolved, cwd_prefix))
                resolved[cwd_prefix.len + 1 ..]
            else
                resolved;
            const tid = fg.idx(rel) orelse continue;
            var dup = false;
            for (fadj.items[i].items) |x| if (x == tid) {
                dup = true;
            };
            if (!dup) try fadj.items[i].append(gpa, tid);
        }
    }
    var fscc_text: std.ArrayList(u8) = .empty;
    defer fscc_text.deinit(gpa);
    const fm = try measure(gpa, &fg, &fscc_text);
    std.debug.print("\narch-report @ the file graph inside modules (a DIFFERENT graph)\n", .{});
    printMetrics("files", fm);
    if (fscc_text.items.len > 0) std.debug.print("{s}", .{fscc_text.items});

    // ---- tripwires ----------------------------------------------------------
    // Known file SCC: search_main <-> search_back IS the alpha-beta mutual recursion.
    // Per Lakos the answer is to NAME it one component, not break it. Naming it here
    // means a NEW cycle is visible against it instead of hiding behind it (G3).
    const known_scc = "src/engine/search/search_main.zig <-> src/engine/search/search_back.zig";
    const known_scc_rev = "src/engine/search/search_back.zig <-> src/engine/search/search_main.zig";

    std.debug.print("\ntripwires (the compiler gives neither -- both verified by spike)\n", .{});

    if (mod.sccs != 0) {
        std.debug.print("  MODULE DAG: BROKEN -- {d} module(s) in {d} cycle(s)\n{s}", .{ mod.in_cycles, mod.sccs, scc_text.items });
        failed = true;
    } else std.debug.print("  MODULE DAG: intact (0 of {d} modules in cycles)\n", .{mod.n});

    var unknown_scc = false;
    if (fm.sccs > 0) {
        var known: usize = 0;
        if (std.mem.indexOf(u8, fscc_text.items, known_scc) != null or
            std.mem.indexOf(u8, fscc_text.items, known_scc_rev) != null) known = 1;
        if (fm.sccs > known) unknown_scc = true;
    }
    if (unknown_scc) {
        std.debug.print("  FILE SCCs: an UNDECLARED file cycle exists. Either name it a component or break it.\n", .{});
        failed = true;
    } else std.debug.print("  FILE SCCs: {d} known (search_main <-> search_back: the alpha-beta recursion, one component)\n", .{fm.sccs});

    std.debug.print("  UNUSED EDGES: {d} (reported, not gated)\n", .{unused.items.len});

    if (failed) {
        std.debug.print("\narch-report: FAILED (a tripwire fired)\n", .{});
        std.process.exit(1);
    }
    std.debug.print("\narch-report: OK\n", .{});
}
