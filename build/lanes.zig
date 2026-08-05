//! Classify every registered step by whether an aggregate already runs it.
//!
//! "A lane that is in no gate is not a lane." A step nobody dispatches rots exactly like a
//! tool nobody invokes, and it rots INVISIBLY: `zig build --list-steps` keeps printing it,
//! so a reader sees coverage that stopped existing. The rule was held by whoever remembered
//! it; this file is the half of the answer that only the build script can give.
//!
//! DERIVED FROM THE GRAPH, NOT FROM THE FLAGS. `build()` assembles `parity` and
//! `parity-portable` by reading `in_parity` / `in_portable` off the gate tables, so a gate
//! answering "am I in the aggregate?" from those same flags would be asking the declaration
//! rather than the tree -- and would agree with a row that had silently lost a flag, which
//! is the one failure build/gates.zig says it can cause. Walk the assembled dependency graph
//! instead: a step is covered when every step it depends on is already reachable from an
//! aggregate. That answer comes from the edges `build()` actually wired.
//!
//! A step with NO dependencies is never "covered". Reachability would call it covered
//! vacuously (the empty set is a subset of anything), which is the shape of every extraction
//! bug this repo has paid for -- an empty subject reporting OK. Such a step is real work
//! (`host-arch` prints, the cross-compile targets install) and belongs in a lane or an
//! excuse like any other.

const std = @import("std");
const config = @import("config.zig");

/// One step and the verdict the graph gives for it.
pub const Classified = struct {
    name: []const u8,
    /// Every dependency of this step is already reachable from an aggregate.
    in_aggregate: bool,
    /// Other top-level steps whose graph already does all of this step's work.
    ///
    /// `test-graph` is the case that forced this field. Its work sits entirely inside
    /// `test`, which CI runs -- so it IS covered, but only the tool knows CI runs `test`,
    /// and only the build script knows `test` subsumes it. Emitting the containment lets
    /// each half answer the part it can see, instead of the build script guessing at CI or
    /// the tool guessing at the graph.
    covered_by: []const []const u8,
};

/// Collect every step reachable from `root`, inclusive, into `set`.
fn reach(set: *std.AutoHashMap(*std.Build.Step, void), root: *std.Build.Step) void {
    if (set.contains(root)) return;
    set.put(root, {}) catch @panic("OOM walking the step graph");
    for (root.dependencies.items) |dep| reach(set, dep);
}

/// Hold every top-level step to the aggregates, and return one row per step.
///
/// Callers pass the aggregates a green push is expected to run; anything they do not reach
/// must be named by a CI workflow or excused, which `tools/lane_coverage.zig` decides -- it
/// is the half that can read `.github/`, which the build script cannot.
/// Decide whether every dependency of `step` is already inside `set`.
///
/// A step with no dependencies is never covered -- see the header. That is the vacuity
/// guard, and it is why this returns false on an empty list rather than the mathematically
/// tidier true.
fn subsumedBy(step: *std.Build.Step, set: *const std.AutoHashMap(*std.Build.Step, void)) bool {
    if (step.dependencies.items.len == 0) return false;
    for (step.dependencies.items) |dep| if (!set.contains(dep)) return false;
    return true;
}

pub fn classify(b: *std.Build, aggregates: []const *std.Build.Step) []const Classified {
    const gpa = b.allocator;

    var agg_set = std.AutoHashMap(*std.Build.Step, void).init(gpa);
    for (aggregates) |agg| reach(&agg_set, agg);

    // Every top-level step, paired with the set its own graph reaches. Built once: the
    // containment test below is quadratic in the step count, and at ~90 steps that is
    // nothing, but re-walking the graph inside the inner loop would not be.
    const Root = struct { name: []const u8, step: *std.Build.Step, set: std.AutoHashMap(*std.Build.Step, void) };
    var roots: std.ArrayList(Root) = .empty;
    var it = b.top_level_steps.iterator();
    while (it.next()) |entry| {
        const step = &entry.value_ptr.*.step;
        var set = std.AutoHashMap(*std.Build.Step, void).init(gpa);
        reach(&set, step);
        roots.append(gpa, .{ .name = entry.key_ptr.*, .step = step, .set = set }) catch @panic("OOM");
    }

    var rows: std.ArrayList(Classified) = .empty;
    for (roots.items) |target| {
        var covered_by: std.ArrayList([]const u8) = .empty;
        for (roots.items) |candidate| {
            if (candidate.step == target.step) continue;
            if (subsumedBy(target.step, &candidate.set))
                covered_by.append(gpa, candidate.name) catch @panic("OOM");
        }
        rows.append(gpa, .{
            .name = target.name,
            .in_aggregate = subsumedBy(target.step, &agg_set),
            .covered_by = covered_by.items,
        }) catch @panic("OOM classifying steps");
    }
    return rows.items;
}

/// Register `lane-coverage`, handing the tool the graph's verdict for every step.
///
/// The classification travels as arguments rather than a written manifest: a file on disk is
/// a second copy of the graph, and this repo has been bitten by exactly that -- a declared
/// table drifting from the tree it describes. Passing it inline means the gate cannot read a
/// membership the build did not just compute.
///
/// ORDER IS THE WHOLE POINT OF THIS FUNCTION'S SHAPE, and getting it wrong makes the gate
/// the one step nothing holds. `classify` reads `b.top_level_steps` and the edges present at
/// the moment it runs, so this step must be REGISTERED and JOINED to its aggregate BEFORE
/// classifying -- otherwise `lane-coverage` is absent from its own subject, and the check
/// that every gate has a lane is itself in none. Hence the join happens here rather than at
/// the call site: a caller doing it afterwards would compile, pass, and prove less.
///
/// Call this LAST in `build()`. Any step declared after it is not in the subject either.
pub fn register(
    b: *std.Build,
    tool: *std.Build.Step.Compile,
    aggregates: []const *std.Build.Step,
) *std.Build.Step {
    const cmd = b.addRunArtifact(tool);
    // Read the tool's own exit status: this gate's verdict is the point of running it.
    cmd.expectExitCode(0);
    // ALWAYS RUN. The subject includes every file under `.github/workflows/`, which cannot be
    // declared as inputs here without a second list that rots exactly like the one this gate
    // exists to replace. Left cacheable, an edit that removes a step from a workflow does not
    // invalidate the run, so the gate reports the lanes of a tree that no longer exists --
    // measured, not feared: appending a line to a workflow left `lane-coverage` cached and
    // silent. It reads text and costs milliseconds, so always-run is the cheap correct arm.
    cmd.has_side_effects = true;

    const step = b.step(
        "lane-coverage",
        "Hold every build step to a lane: in an aggregate, named by a CI workflow, or excused",
    );
    step.dependOn(&cmd.step);
    // Join first, classify second -- see above. It reads text and the graph (no engine, no
    // net), so it costs the aggregate nothing.
    aggregates[0].dependOn(step);

    // The build root, through the ONE shim that knows which std.Build field holds it.
    // Naming `b.build_root` here is what took the 0.17 lane down at configure time.
    cmd.addArg(config.repoPath(b, "."));
    cmd.addFileArg(b.path("tools/lane_excuses.txt"));
    // `<name>|<agg|->|<coverer,coverer,...>` -- see tools/lane_coverage.zig for the reading.
    for (classify(b, aggregates)) |row| {
        var joined: std.ArrayList(u8) = .empty;
        for (row.covered_by, 0..) |c, i| {
            if (i != 0) joined.append(b.allocator, ',') catch @panic("OOM");
            joined.appendSlice(b.allocator, c) catch @panic("OOM");
        }
        cmd.addArg(b.fmt("{s}|{s}|{s}", .{
            row.name,
            if (row.in_aggregate) "agg" else "-",
            joined.items,
        }));
    }
    return step;
}
