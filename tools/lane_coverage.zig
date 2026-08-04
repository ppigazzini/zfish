// Hold every build step to one of three states: an aggregate runs it, a CI workflow names
// it, or `tools/lane_excuses.txt` argues why neither does. A step in none of the three is a
// gate nobody dispatches -- it keeps appearing in `zig build --list-steps`, so a reader sees
// coverage that has stopped existing.
//
// build/lanes.zig supplies the aggregate half by walking the assembled dependency graph, and
// hands it here as `<step>=agg` / `<step>=-` arguments. This file supplies the half the build
// script cannot see: what `.github/workflows/` actually dispatches, and what the tree has
// argued its way out of.
//
// THE EXCUSE LIST IS THE HOLE, so it expires in its own direction. An excused step that DOES
// run is a stale excuse and fails -- otherwise a list written defensively goes on covering
// steps that gained a lane years ago, and the day one loses its lane again the excuse is
// still sitting there absorbing it. An excuse naming a step that no longer exists fails for
// the same reason.
//
// TWO PATTERN TRAPS, both of which have produced a false verdict in a sibling port:
//   * a step NAMED IN A YAML COMMENT is not a step that runs. Skip comment lines, and cut a
//     trailing ` #` comment off a content line.
//   * a prefix match is not a name match: `zig build net` must not be satisfied by
//     `zig build net-fetch`. Tokens are matched WHOLE against the known step set, never as
//     prefixes, which is why the step universe is passed in rather than guessed from text.
//
// Exit: 0 every step laned or argued, 1 a step in no lane / a stale excuse, 2 a rig fault
// (the classification arrived empty, the excuse file is unreadable).

const std = @import("std");

/// Refuse a classification that lost its subject. Every extraction failure this repo has had
/// was a shrinking subject rather than a wrong answer, and a shrunk subject reports OK.
const step_floor = 60;

const State = struct {
    in_aggregate: bool = false,
    in_workflow: bool = false,
    /// Other steps whose graph already does all of this one's work (from build/lanes.zig).
    covered_by: []const u8 = "",
    excuse: ?[]const u8 = null,
    /// Set by the propagation below; the reason is kept for the report.
    laned_via: ?[]const u8 = null,
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("lane-coverage: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

/// Judge whether `tok` is a step-name-shaped token: lowercase, digits, hyphens.
fn stepShaped(tok: []const u8) bool {
    if (tok.len == 0) return false;
    for (tok) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
    }
    return true;
}

/// Mark every step a workflow line dispatches. Read only what follows `zig build` on the
/// line, and stop at the first token that is not step-shaped -- an option, a redirect, a
/// shell operator. Tokens are looked up whole in `steps`, so a name that is merely a prefix
/// of a real step matches nothing.
fn scanLine(line: []const u8, steps: *std.StringHashMap(State)) void {
    // A comment names a step, it does not run one.
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[0] == '#') return;
    // Cut a trailing YAML comment; ` #` mid-line starts one.
    const content = if (std.mem.indexOf(u8, trimmed, " #")) |h| trimmed[0..h] else trimmed;

    var rest = content;
    while (std.mem.indexOf(u8, rest, "zig build")) |at| {
        rest = rest[at + "zig build".len ..];
        var tok_it = std.mem.tokenizeAny(u8, rest, " \t");
        while (tok_it.next()) |raw_tok| {
            // Options and flags may precede the step name (`zig build -Dtsan tsan-race`), so
            // skip them rather than stopping; stop at anything else unrecognisable.
            if (raw_tok.len > 0 and raw_tok[0] == '-') continue;
            // A step name is routinely wrapped in shell syntax the workflows need for their
            // exit-status capture: `if out="$(zig build upstream-map)"; then`. Strip the
            // TRAILING metacharacters before looking the token up. This cannot invent a
            // match -- the lookup below is an exact whole-name comparison against the step
            // set the build handed us, so a trimmed token either IS a step name or is not.
            const tok = std.mem.trimEnd(u8, raw_tok, ")\"';|&,");
            if (!stepShaped(tok)) break;
            if (steps.getPtr(tok)) |st| st.in_workflow = true;
            // Keep going: `zig build parity test` dispatches both.
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    while (arg_it.next()) |a| try args.append(gpa, a);
    if (args.items.len < 4) fail("usage: lane_coverage <repo-root> <excuses> <step>=<agg|-> ...", .{});

    const root = args.items[1];
    const excuses_path = args.items[2];

    var steps = std.StringHashMap(State).init(gpa);
    defer steps.deinit();
    for (args.items[3..]) |spec| {
        var f = std.mem.splitScalar(u8, spec, '|');
        const name = f.next() orelse fail("malformed classification '{s}'", .{spec});
        const agg = f.next() orelse fail("malformed classification '{s}'", .{spec});
        const covered_by = f.next() orelse fail("malformed classification '{s}'", .{spec});
        try steps.put(name, .{
            .in_aggregate = std.mem.eql(u8, agg, "agg"),
            .covered_by = covered_by,
        });
    }
    if (steps.count() < step_floor)
        fail("only {d} step(s) classified (floor {d}) -- the build handed this gate a\n" ++
            "lane-coverage: SHRUNKEN step list, which would report OK over nothing. Refusing.", .{ steps.count(), step_floor });

    // --- what CI dispatches ---------------------------------------------------------
    const wf_dir_path = try std.fmt.allocPrint(gpa, "{s}/.github/workflows", .{root});
    defer gpa.free(wf_dir_path);
    var wf_dir = Io.Dir.cwd().openDir(io, wf_dir_path, .{ .iterate = true }) catch
        fail("cannot open {s} -- nothing to read lanes out of", .{wf_dir_path});
    defer wf_dir.close(io);

    var workflows: usize = 0;
    var wf_it = wf_dir.iterate();
    while (try wf_it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yml") and !std.mem.endsWith(u8, entry.name, ".yaml")) continue;
        const body = wf_dir.readFileAlloc(io, entry.name, gpa, .unlimited) catch
            fail("cannot read workflow {s}", .{entry.name});
        defer gpa.free(body);
        workflows += 1;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| scanLine(line, &steps);
    }
    if (workflows == 0)
        fail("no workflow files read -- every step would read as unlaned. Refusing.", .{});

    // --- what the tree has argued its way out of --------------------------------------
    const excuses_raw = Io.Dir.cwd().readFileAlloc(io, excuses_path, gpa, .unlimited) catch
        fail("cannot read the excuse list {s}", .{excuses_path});
    defer gpa.free(excuses_raw);

    var fail_count: usize = 0;
    var excused: usize = 0;
    var lines = std.mem.splitScalar(u8, excuses_raw, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sep = std.mem.indexOfAny(u8, line, " \t") orelse {
            std.debug.print("lane-coverage: EXCUSE WITH NO REASON  `{s}` -- an excuse is an argument, not a name\n", .{line});
            fail_count += 1;
            continue;
        };
        const name = line[0..sep];
        const reason = std.mem.trim(u8, line[sep..], " \t");
        if (reason.len == 0) {
            std.debug.print("lane-coverage: EXCUSE WITH NO REASON  `{s}`\n", .{name});
            fail_count += 1;
            continue;
        }
        const st = steps.getPtr(name) orelse {
            std.debug.print("lane-coverage: EXCUSE FOR A STEP THAT DOES NOT EXIST  `{s}` -- delete the line\n", .{name});
            fail_count += 1;
            continue;
        };
        st.excuse = reason;
        excused += 1;
    }

    // --- propagate: a step subsumed by a laned step is laned --------------------------
    // `test-graph` is the worked example: nothing dispatches it, but `test` -- which the
    // parity workflow runs twice -- already does all of its work, so it is covered in fact.
    // Iterate to a fixpoint rather than one pass: containment chains, and a single pass
    // would settle on whichever order the hash map happened to yield.
    {
        var seed = steps.iterator();
        while (seed.next()) |e| {
            if (e.value_ptr.in_aggregate) e.value_ptr.laned_via = "an aggregate reaches it";
            if (e.value_ptr.in_workflow) e.value_ptr.laned_via = "a workflow names it";
        }
        var changed = true;
        while (changed) {
            changed = false;
            var it2 = steps.iterator();
            while (it2.next()) |e| {
                if (e.value_ptr.laned_via != null) continue;
                var covs = std.mem.tokenizeScalar(u8, e.value_ptr.covered_by, ',');
                while (covs.next()) |cov| {
                    const owner = steps.get(cov) orelse continue;
                    if (owner.laned_via == null) continue;
                    e.value_ptr.laned_via = "a laned step already does all of its work";
                    changed = true;
                    break;
                }
            }
        }
    }

    // --- `<gate>-update` is accounted for by `<gate>` ---------------------------------
    // "Every golden gate is a pair" is a documented convention here (docs/09), and the
    // update half is a REGENERATION TOOL, not a check: it must never run in CI, and since
    // the refusal landed it exits 2 by default anyway. Excusing 21 near-identical steps by
    // hand would bury the two lines in that file that carry a real argument.
    //
    // Requiring the BASE gate to be laned is what keeps this honest -- an update step whose
    // gate nobody runs still fails, which is the case the rule is worth having for. Same
    // reading docs_lint.sh gives the pairing when it decides which steps need prose.
    {
        var it2 = steps.iterator();
        while (it2.next()) |e| {
            if (e.value_ptr.laned_via != null) continue;
            const name = e.key_ptr.*;
            if (!std.mem.endsWith(u8, name, "-update")) continue;
            const base = steps.get(name[0 .. name.len - "-update".len]) orelse continue;
            if (base.laned_via == null) continue;
            e.value_ptr.laned_via = "its base gate is laned (regeneration half of a gate pair)";
        }
    }

    // --- the verdict, in both directions ----------------------------------------------
    var laned: usize = 0;
    var it = steps.iterator();
    while (it.next()) |e| {
        const st = e.value_ptr.*;
        const runs = st.laned_via != null;
        if (runs) {
            laned += 1;
            if (st.excuse != null) {
                std.debug.print(
                    "lane-coverage: STALE EXCUSE  `{s}` is excused but DOES run ({s}) -- delete the line\n",
                    .{ e.key_ptr.*, st.laned_via.? },
                );
                fail_count += 1;
            }
        } else if (st.excuse == null) {
            std.debug.print(
                "lane-coverage: NO LANE  `zig build {s}` runs in no aggregate and no workflow --\n" ++
                    "lane-coverage:          give it a lane, or an argued line in {s}\n",
                .{ e.key_ptr.*, excuses_path },
            );
            fail_count += 1;
        }
    }

    if (fail_count != 0) {
        std.debug.print("lane-coverage: FAIL -- {d} finding(s) over {d} step(s)\n", .{ fail_count, steps.count() });
        std.process.exit(1);
    }
    std.debug.print(
        "lane-coverage: OK ({d} steps: {d} in a lane, {d} excused with a reason; {d} workflows read)\n",
        .{ steps.count(), laned, excused, workflows },
    );
}

const Io = std.Io;
