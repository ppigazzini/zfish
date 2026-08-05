// Hold every golden FILE in the tree to a gate that reads it.
//
// `lane-coverage` asks whether every build STEP is dispatched. This asks the other half of
// the same question about the other half of the battery: a golden is a photograph, and a
// photograph nobody diffs is not a check -- it is a file. The failure is silent by
// construction, because the gate that stopped reading it is not the gate that goes red.
// Nothing here could see it: the goldens are declared one by one in `build/gates.zig`, so a
// gate deleted without its golden leaves a file that every tool walks past.
//
// THE UNIVERSE IS GLOBBED FROM THE TREE, NEVER LISTED. A second list of goldens would rot in
// exactly the way this gate exists to catch -- the same reason `lane-coverage` derives its
// step set from the build graph rather than from a table. `tools/` is walked for `*.golden`
// and every file found must be claimed.
//
// Two directions, because neither answers the other:
//   DECLARED -> TREE   every path `build/gates.zig` names must exist. A gate whose golden is
//                      gone fails at run time with a missing file; it should fail here first,
//                      in a lane that needs no engine.
//   TREE -> DECLARED   every `*.golden` found must be claimed, by the gates table or by a row
//                      in `non_gate_owners` below. Unclaimed is a failure, not a warning.
//
// The owner rows are the allowance, so they expire in both directions: a row naming a golden
// the tree no longer has fails, a row for a golden the gates table has since adopted fails as
// stale, and a row whose owner does not MENTION the golden fails -- an owner is a claim that
// something reads the file, and a claim nothing witnesses is a name.
//
// Exit: 0 every golden claimed and every declaration real, 1 a golden nobody reads / a
// declaration with no file / a stale owner row, 2 a rig fault (no declarations passed, or the
// glob came back under the floor -- a shrunk subject reports OK).

const std = @import("std");
const Io = std.Io;

/// Refuse a subject that lost its members. Every extraction failure in this tree has been a
/// shrinking subject rather than a wrong answer, and a shrunk subject reports OK.
const golden_floor = 15;

const Owner = struct {
    /// Repo-relative path of the golden.
    path: []const u8,
    /// Repo-relative path of the tool that reads it.
    owner: []const u8,
    /// Why it is not a `build/gates.zig` row.
    why: []const u8,
};

/// Goldens read by something other than the golden-gate table. Each must be witnessed: the
/// owner file has to name the golden, or the row is just an assertion.
const non_gate_owners = [_]Owner{
    .{
        .path = "tools/instr_budget.golden",
        .owner = "tools/perf_budget.sh",
        .why = "a retired-instruction budget, not a value diff: it is LOCAL-ONLY on purpose (perf_event_open is refused in many CI containers, and the count is toolchain-specific), so it has no `zig build` step to hang a gates row on",
    },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer arg_it.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    while (arg_it.next()) |a| try argv.append(arena, a);
    if (argv.items.len < 2) {
        std.debug.print("golden-coverage: RIG FAULT -- no declared goldens were passed; the\n", .{});
        std.debug.print("golden-coverage: classification arrived EMPTY, which would report OK\n", .{});
        std.process.exit(2);
    }
    const declared = argv.items[1..];

    var failures: usize = 0;

    // --- DECLARED -> TREE -------------------------------------------------------------
    for (declared) |path| {
        Io.Dir.cwd().access(io, path, .{}) catch {
            std.debug.print("golden-coverage: DECLARED, MISSING  `{s}` is a gate's golden and is not in the tree\n", .{path});
            failures += 1;
        };
    }

    // --- the universe, from the tree --------------------------------------------------
    var found: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(io, "tools", .{ .iterate = true }) catch {
        std.debug.print("golden-coverage: RIG FAULT -- cannot open `tools/` (wrong cwd?)\n", .{});
        std.process.exit(2);
    };
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".golden")) continue;
        try found.append(arena, try std.fmt.allocPrint(arena, "tools/{s}", .{entry.path}));
    }

    if (found.items.len < golden_floor) {
        std.debug.print("golden-coverage: RIG FAULT -- the glob found {d} goldens, under the floor of {d};\n", .{ found.items.len, golden_floor });
        std.debug.print("golden-coverage: a subject that shrank reports OK, so this refuses instead\n", .{});
        std.process.exit(2);
    }

    // --- TREE -> DECLARED -------------------------------------------------------------
    var owned_by_row: usize = 0;
    for (found.items) |path| {
        var claimed = false;
        for (declared) |d| {
            if (std.mem.eql(u8, d, path)) claimed = true;
        }
        if (claimed) continue;

        for (non_gate_owners) |o| {
            if (!std.mem.eql(u8, o.path, path)) continue;
            claimed = true;
            owned_by_row += 1;
            // The owner must exist, and must NAME the golden. A row nothing witnesses is a
            // claim that the file is read, with nothing behind it.
            const src = Io.Dir.cwd().readFileAlloc(io, o.owner, arena, .unlimited) catch {
                std.debug.print("golden-coverage: DEAD OWNER      `{s}` is owned by `{s}`, which is not in the tree\n", .{ path, o.owner });
                failures += 1;
                break;
            };
            const base = std.fs.path.basename(path);
            if (std.mem.indexOf(u8, src, base) == null) {
                std.debug.print("golden-coverage: UNWITNESSED     `{s}` claims owner `{s}`, which never names it\n", .{ path, o.owner });
                failures += 1;
            }
            break;
        }
        if (claimed) continue;

        std.debug.print("golden-coverage: UNCLAIMED       `{s}` is read by NO gate -- a golden nobody diffs\n", .{path});
        std.debug.print("golden-coverage:                 is not a check. Add its gate to build/gates.zig,\n", .{});
        std.debug.print("golden-coverage:                 give it an owner row, or delete the file.\n", .{});
        failures += 1;
    }

    // --- the owner rows expire too ----------------------------------------------------
    for (non_gate_owners) |o| {
        // An owner row is an ARGUMENT, not a name -- the same rule `lane_excuses.txt` is held
        // to. A row that stops making one absorbs a golden nobody reads, silently.
        if (o.why.len == 0) {
            std.debug.print("golden-coverage: UNARGUED ROW    `{s}` claims an owner with no reason -- an owner row is an argument\n", .{o.path});
            failures += 1;
        }
        var present = false;
        for (found.items) |path| {
            if (std.mem.eql(u8, o.path, path)) present = true;
        }
        if (!present) {
            std.debug.print("golden-coverage: STALE OWNER     `{s}` has an owner row and is not in the tree -- delete the row\n", .{o.path});
            failures += 1;
        }
        for (declared) |d| {
            if (!std.mem.eql(u8, d, o.path)) continue;
            std.debug.print("golden-coverage: STALE OWNER     `{s}` is now a gates-table golden; the owner row is absorbed -- delete it\n", .{o.path});
            failures += 1;
        }
    }

    if (failures != 0) {
        std.debug.print("golden-coverage: FAIL -- {d} problem(s) above\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print(
        "golden-coverage: OK ({d} goldens in the tree: {d} read by a gate, {d} by an owner row; {d} declarations all exist)\n",
        .{ found.items.len, found.items.len - owned_by_row, owned_by_row, declared.len },
    );
}
