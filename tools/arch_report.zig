//! arch_report: report coupling and raise the two tripwires the compiler will not give (G1 / D.2).
//!
//! Report Lakos CCD/ACD/NCCD over zfish's import graphs, at BOTH granularities,
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
//! point. Parse the addImport call sites, and report the table-only
//! subgraph separately and clearly labelled.

const std = @import("std");
const Io = std.Io;
const arch_graph = @import("arch_graph.zig");

const Graph = arch_graph.Graph;
const Metrics = arch_graph.Metrics;
const toPosixSep = arch_graph.toPosixSep;
const measure = arch_graph.measure;
const printMetrics = arch_graph.printMetrics;
const deinitGraphParts = arch_graph.deinitGraphParts;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const build_src = try Io.Dir.cwd().readFileAlloc(io, "build.zig", gpa, .unlimited);
    defer gpa.free(build_src);
    // The two graph TABLES moved to build/modules.zig; the addImport CALL SITES did not.
    // Read both and scan each for what it actually holds -- pointing every scan at one file
    // would silently report an empty graph and still exit 0.
    const graph_src = try Io.Dir.cwd().readFileAlloc(io, "build/modules.zig", gpa, .unlimited);
    defer gpa.free(graph_src);

    var failed = false;

    // ---- module graph -------------------------------------------------------
    // Nodes: the declared table + build_options + main (the exe root). Edges: the
    // module_edges table + every addImport call site.
    var names: std.ArrayList([]const u8) = .empty;
    var adj: std.ArrayList(std.ArrayList(usize)) = .empty;

    var declared: usize = 0;
    {
        var it = std.mem.splitSequence(u8, graph_src, ".{ .name = \"");
        _ = it.next();
        while (it.next()) |chunk| {
            const end = std.mem.findScalar(u8, chunk, '"') orelse continue;
            const rest = chunk[end..];
            if (std.mem.find(u8, rest[0..@min(rest.len, 24)], ".path = \"") == null) continue;
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
        var it = std.mem.splitSequence(u8, graph_src, ".{ .from = \"");
        _ = it.next();
        while (it.next()) |chunk| {
            const fe = std.mem.findScalar(u8, chunk, '"') orelse continue;
            const from = chunk[0..fe];
            const to_key = ".to = \"";
            const ti = std.mem.find(u8, chunk, to_key) orelse continue;
            const trest = chunk[ti + to_key.len ..];
            const te = std.mem.findScalar(u8, trest, '"') orelse continue;
            const to = trest[0..te];
            const fi = g.idx(from) orelse continue;
            const tid = g.idx(to) orelse continue;
            try adj.items[fi].append(gpa, tid);
            table_edges += 1;
        }
    }

    // Scan every addImport call site: `<owner>.addImport("<name>", ...)`. The table is data;
    // THIS is the wiring. misc->build_options and main.zig's 45 edges live only here.
    var wired_main: usize = 0;
    {
        var line_it = std.mem.splitScalar(u8, build_src, '\n');
        while (line_it.next()) |line| {
            const key = ".addImport(\"";
            const ki = std.mem.find(u8, line, key) orelse continue;
            const t = std.mem.trimStart(u8, line, " ");
            if (std.mem.startsWith(u8, t, "//")) continue;
            const rest = line[ki + key.len ..];
            const ne = std.mem.findScalar(u8, rest, '"') orelse continue;
            const imported = rest[0..ne];
            const owner: []const u8 = if (std.mem.startsWith(u8, t, "exe.root_module"))
                "main"
            else if (std.mem.find(u8, line, "mods.get(\"") != null and std.mem.find(u8, line, "\").?.addImport") != null) blk: {
                const ok = "mods.get(\"";
                const oi = std.mem.find(u8, line, ok).?;
                const orest = line[oi + ok.len ..];
                const oe = std.mem.findScalar(u8, orest, '"') orelse continue;
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
    // Note that main.zig is wired to 45 modules but @imports far fewer. Zig accepts the gap
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
        if (std.mem.find(u8, main_src, needle) == null) try unused.append(gpa, g.names[t]);
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
    // Two spellings per file: `fpaths` is what the platform will open, `fnames` is the key
    // everything else is compared against. They differ only on Windows, and only there does
    // conflating them break anything -- silently, and in the direction that reports success.
    var fpaths: std.ArrayList([]const u8) = .empty;
    defer {
        for (fpaths.items) |p| gpa.free(p);
        fpaths.deinit(gpa);
    }
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try fpaths.append(gpa, try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path}));
        try fnames.append(gpa, toPosixSep(try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path})));
        try fadj.append(gpa, .empty);
    }
    var fg = Graph{ .names = fnames.items, .adj = fadj.items };
    defer deinitGraphParts(gpa, &fnames, &fadj);
    for (fg.names, 0..) |path, i| {
        const body = try Io.Dir.cwd().readFileAlloc(io, fpaths.items[i], gpa, .unlimited);
        defer gpa.free(body);
        const dirname = std.fs.path.dirname(path) orelse "src";
        var it = std.mem.splitSequence(u8, body, "@import(\"");
        _ = it.next();
        while (it.next()) |chunk| {
            const e = std.mem.findScalar(u8, chunk, '"') orelse continue;
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
            // `resolve` hands back the platform's separators; the keys use '/'.
            const tid = fg.idx(toPosixSep(rel)) orelse continue;
            var dup = false;
            for (fadj.items[i].items) |x| if (x == tid) {
                dup = true;
            };
            if (!dup) try fadj.items[i].append(gpa, tid);
        }
    }
    // ---- reachability: is every file COMPILED by anything? -------------------
    //
    // The file graph above is built by WALKING src/, so a file nothing imports is a node with
    // no in-edge, present in N and invisible in every other reading. That is not a cosmetic
    // gap: a source the build never names is not compiled, not linked and not covered by any
    // gate, while still looking maintained. Verified by spike -- a stray src/ file whose only
    // declaration was `@compileError` passed the whole `parity` aggregate, because the error
    // fires on ANALYSIS and nothing analysed it.
    //
    // The roots are the declared entry points, and ALL THREE build files have to be read for
    // the set to be complete: build/modules.zig (the module table), build/tests.zig (the test
    // and fuzz roots, which own files the shipped graph does not reach), and build.zig itself.
    // The first run of this tripwire named src/engine/headless.zig, which is not an orphan at
    // all -- it is the `zig build engine` root, declared in build.zig and nowhere else. A root
    // reader that misses a root reports every file below it as dead, so the miss shows up as a
    // finding rather than as silence, which is the way round to want it.
    var reachable = try gpa.alloc(bool, fg.names.len);
    defer gpa.free(reachable);
    @memset(reachable, false);
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(gpa);
    const tests_src = try Io.Dir.cwd().readFileAlloc(io, "build/tests.zig", gpa, .unlimited);
    defer gpa.free(tests_src);
    for ([_][]const u8{ graph_src, tests_src, build_src }) |decl| {
        var it = std.mem.splitSequence(u8, decl, "\"src/");
        _ = it.next();
        while (it.next()) |chunk| {
            const e = std.mem.findScalar(u8, chunk, '"') orelse continue;
            if (!std.mem.endsWith(u8, chunk[0..e], ".zig")) continue;
            const path = try std.fmt.allocPrint(gpa, "src/{s}", .{chunk[0..e]});
            defer gpa.free(path);
            const rid = fg.idx(path) orelse continue;
            if (!reachable[rid]) {
                reachable[rid] = true;
                try queue.append(gpa, rid);
            }
        }
    }
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        for (fg.adj[queue.items[qi]].items) |t| {
            if (!reachable[t]) {
                reachable[t] = true;
                try queue.append(gpa, t);
            }
        }
    }
    var orphans: std.ArrayList(u8) = .empty;
    defer orphans.deinit(gpa);
    var orphan_count: usize = 0;
    for (fg.names, 0..) |path, i| {
        if (reachable[i]) continue;
        orphan_count += 1;
        try orphans.print(gpa, "    ORPHAN: {s}\n", .{path});
    }

    var fscc_text: std.ArrayList(u8) = .empty;
    defer fscc_text.deinit(gpa);
    const fm = try measure(gpa, &fg, &fscc_text);
    std.debug.print("\narch-report @ the file graph inside modules (a DIFFERENT graph)\n", .{});
    printMetrics("files", fm);
    if (fscc_text.items.len > 0) std.debug.print("{s}", .{fscc_text.items});

    // ---- tripwires ----------------------------------------------------------
    // Name the known file SCC: search_main <-> search_back IS the alpha-beta mutual recursion.
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
        if (std.mem.find(u8, fscc_text.items, known_scc) != null or
            std.mem.find(u8, fscc_text.items, known_scc_rev) != null) known = 1;
        if (fm.sccs > known) unknown_scc = true;
    }
    if (unknown_scc) {
        std.debug.print("  FILE SCCs: an UNDECLARED file cycle exists. Either name it a component or break it.\n", .{});
        failed = true;
    } else std.debug.print("  FILE SCCs: {d} known (search_main <-> search_back: the alpha-beta recursion, one component)\n", .{fm.sccs});
    if (orphan_count != 0) {
        std.debug.print("  SOURCE REACH: {d} file(s) no declared root reaches -- compiled by NOTHING, gated by nothing.\n", .{orphan_count});
        std.debug.print("{s}", .{orphans.items});
        failed = true;
    } else std.debug.print("  SOURCE REACH: every src/ file is reachable from a declared root\n", .{});

    std.debug.print("  UNUSED EDGES: {d} (reported, not gated)\n", .{unused.items.len});

    if (failed) {
        std.debug.print("\narch-report: FAILED (a tripwire fired)\n", .{});
        std.process.exit(1);
    }
    std.debug.print("\narch-report: OK\n", .{});
}
