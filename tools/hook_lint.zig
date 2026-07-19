//! hook_lint: bound and classify the cycle-break mechanism (G2 / D.1).
//!
//! zfish's module graph is a DAG by DESIGN, not by language rule -- Zig compiles and
//! runs import cycles at both granularities. The DAG is bought with function-pointer
//! hooks: where a cycle would exist, a leaf declares `pub var f: *const fn ...` and the
//! composition root (main.zig) registers the implementation at startup. The hooks are
//! the DAG's running bill, and nothing counted them, classified them, or recorded what
//! happens when one is never registered -- so the next hook chose its failure mode by
//! accident. That is what this lints.
//!
//! Enforce four rules, each failing loudly:
//!
//!   1. RATCHET      exactly `baseline` hooks exist. They buy the DAG; they must not
//!                   grow unnoticed. Growth is a design decision, not a drive-by.
//!   2. FAILURE MODE every hook declares `/// failure: loud` (a named panic when
//!                   unregistered) or `/// failure: silent — <why that value is
//!                   correct unregistered>`. A silent default with no stated reason is
//!                   the defect: 8 search-affecting hooks return 0/false/single-threaded
//!                   and the engine keeps playing chess, which in an engine whose whole
//!                   contract is bench=2792255 is the worst possible failure.
//!   3. CLASS        every file declaring hooks states `//! hook-class: lifecycle` or
//!                   `service` in its header. Lifecycle hooks are structurally safe;
//!                   service hooks are the live risk, because a CALLER decides how often
//!                   a service is asked and the hook cannot tell.
//!   4. REGISTERED   every hook is registered by the shipped composition root before the
//!                   engine is reachable. THIS is the rule that protects the bench
//!                   signature: a hook added tomorrow and never wired would not crash --
//!                   it would silently answer, and the engine would still look like a
//!                   working chess engine while searching a different tree.
//!
//! Rule 4 is the one with teeth. Rules 1-3 keep the mechanism legible.

const std = @import("std");
const Io = std.Io;

const baseline: usize = 31;

// List the shipped registration sites. main.zig is the composition root (it may import
// everything and nothing imports it, which is what lets it hand implementations
// backwards to the leaves); position.zig self-registers the 2 snapshot hooks it owns.
// Both run before the engine is constructed (main.zig:67 initRuntime, :68
// installRuntimeHooks, :79 engineConstructAt).
const registrars = [_][]const u8{
    "src/shell/main.zig",
    "src/engine/board/position.zig",
};

var fail_count: usize = 0;

fn report(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("hook-lint: " ++ fmt ++ "\n", args);
    fail_count += 1;
}

const Hook = struct {
    name: []const u8,
    file: []const u8,
    loud: bool,
};

/// Match a hook declaration: `pub var <name>: *const fn ...`. The type often wraps onto the
/// next line, so match on the two anchors rather than the whole signature.
fn hookNameOf(line: []const u8) ?[]const u8 {
    const decl = "pub var ";
    if (!std.mem.startsWith(u8, line, decl)) return null;
    if (std.mem.indexOf(u8, line, ": *const fn") == null) return null;
    const rest = line[decl.len..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    return std.mem.trim(u8, rest[0..colon], " ");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var hooks: std.ArrayList(Hook) = .empty;
    defer hooks.deinit(gpa);

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }

    // Collect every .zig file under src/.
    var dir = try Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try files.append(gpa, try gpa.dupe(u8, entry.path));
    }

    // Read the registration sites once.
    var registrar_src: std.ArrayList([]const u8) = .empty;
    defer {
        for (registrar_src.items) |s| gpa.free(s);
        registrar_src.deinit(gpa);
    }
    for (registrars) |r| {
        const body = Io.Dir.cwd().readFileAlloc(io, r, gpa, .unlimited) catch {
            report("cannot read registrar {s}", .{r});
            continue;
        };
        defer gpa.free(body);
        // Keep only lines that are actual code. A substring search over the raw file
        // cannot tell `x.f = &impl;` from `// x.f = &impl;`, so a commented-out
        // registration would satisfy rule 4 while the hook silently answers at
        // runtime -- the exact defect this rule exists to catch. Found by watching
        // the inject-fail NOT go red.
        var code: std.ArrayList(u8) = .empty;
        errdefer code.deinit(gpa);
        var lit = std.mem.splitScalar(u8, body, '\n');
        while (lit.next()) |line| {
            const t = std.mem.trimStart(u8, std.mem.trimEnd(u8, line, "\r"), " ");
            if (std.mem.startsWith(u8, t, "//")) continue;
            try code.appendSlice(gpa, t);
            try code.append(gpa, '\n');
        }
        try registrar_src.append(gpa, try code.toOwnedSlice(gpa));
    }

    for (files.items) |rel| {
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{rel});
        defer gpa.free(path);
        const body = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(body);
        if (std.mem.indexOf(u8, body, ": *const fn") == null) continue;

        var file_has_hook = false;
        var prev_doc: std.ArrayList([]const u8) = .empty;
        defer prev_doc.deinit(gpa);

        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const trimmed = std.mem.trimStart(u8, line, " ");
            if (std.mem.startsWith(u8, trimmed, "///")) {
                try prev_doc.append(gpa, trimmed);
                continue;
            }
            if (hookNameOf(line)) |name| {
                file_has_hook = true;

                // Rule 2: require the declaration to state what happens when nobody registers it.
                var loud = false;
                var declared = false;
                for (prev_doc.items) |d| {
                    if (std.mem.indexOf(u8, d, "failure: loud") != null) {
                        loud = true;
                        declared = true;
                    } else if (std.mem.indexOf(u8, d, "failure: silent") != null) {
                        declared = true;
                        // Require a silent default to say WHY it is correct unregistered.
                        const marker = "failure: silent";
                        const idx = std.mem.indexOf(u8, d, marker).?;
                        const why = std.mem.trim(u8, d[idx + marker.len ..], " -—:");
                        if (why.len < 12)
                            report(
                                "{s}: hook '{s}' defaults SILENT with no stated reason. " ++
                                    "Say why that value is correct when unregistered, or make it loud.",
                                .{ path, name },
                            );
                    }
                }
                if (!declared)
                    report(
                        "{s}: hook '{s}' declares no failure mode. Add '/// failure: loud' or " ++
                            "'/// failure: silent — <why that value is correct unregistered>'.",
                        .{ path, name },
                    );

                try hooks.append(gpa, .{
                    .name = try gpa.dupe(u8, name),
                    .file = try gpa.dupe(u8, path),
                    .loud = loud,
                });
            }
            prev_doc.clearRetainingCapacity();
        }

        // Rule 3: require the file to state its class.
        if (file_has_hook) {
            const lifecycle = std.mem.indexOf(u8, body, "hook-class: lifecycle") != null;
            const service = std.mem.indexOf(u8, body, "hook-class: service") != null;
            if (!lifecycle and !service)
                report(
                    "{s}: declares hooks but no '//! hook-class: lifecycle|service' header. " ++
                        "Lifecycle hooks are structurally safe; service hooks are the live risk.",
                    .{path},
                );
        }
    }
    defer for (hooks.items) |h| {
        gpa.free(h.name);
        gpa.free(h.file);
    };

    // Rule 4: require the shipped composition root to register every hook.
    for (hooks.items) |h| {
        const needle = try std.fmt.allocPrint(gpa, ".{s} = ", .{h.name});
        defer gpa.free(needle);
        var found = false;
        for (registrar_src.items) |s| {
            if (std.mem.indexOf(u8, s, needle) != null) found = true;
        }
        if (!found)
            report(
                "hook '{s}' ({s}) is never registered by the composition root. " ++
                    "Unregistered it answers silently and the engine keeps running -- " ++
                    "a wrong bench, not a crash. Register it in main.zig.",
                .{ h.name, h.file },
            );
    }

    // Rule 1: enforce the ratchet.
    var loud_n: usize = 0;
    for (hooks.items) |h| loud_n += @intFromBool(h.loud);
    if (hooks.items.len != baseline)
        report(
            "hook count is {d}, baseline {d}. Hooks buy the DAG and are its running bill: " ++
                "adding one is a design decision. If deliberate, update `baseline` in tools/hook_lint.zig.",
            .{ hooks.items.len, baseline },
        );

    if (fail_count != 0) {
        std.debug.print("hook-lint: FAILED ({d} problem(s))\n", .{fail_count});
        std.process.exit(1);
    }
    std.debug.print(
        "hook-lint: OK ({d} hooks, baseline {d}; {d} loud / {d} silent-with-reason; " ++
            "all classified and registered by the composition root)\n",
        .{ hooks.items.len, baseline, loud_n, hooks.items.len - loud_n },
    );
}
