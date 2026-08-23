//! Run interleaved paired A/B over CPU HARDWARE COUNTERS.
//!
//! WHY THIS EXISTS. The report's §3-P1 declared the campaign "blocked" because "WSL2 has no
//! `perf`", leaving callgrind as the only profiler -- and callgrind SIGILLs on avx512, so every
//! profile in the campaign was taken on sse41 and the top arch was never measured directly.
//! That premise is FALSE: the `perf` *binary* is absent, but `perf_event_open` is not, and it is
//! the syscall that matters. Use it directly, so it works on EVERY arch tier,
//! including vnni512.
//!
//! WHAT IT ADDS OVER THE OTHER TOOLS:
//!   * nps_ab.sh gives wall-clock only -- thermally noisy (L1/L2: the same binary has read
//!     511,286 and 581,024 nps, a 13.6% swing from thermal state alone).
//!   * perf_callgrind.sh gives deterministic INSTRUCTIONS, but ONLY on sse41 (callgrind SIGILLs
//!     on avx512) and at ~50x slowdown. It also cannot see cycles/IPC at all.
//!   * Give BOTH: instructions (the work) AND cycles/IPC/cache-misses/branch-misses (the
//!     efficiency), at native speed, on EVERY tier. It is the only tool here that can SEE an
//!     IPC/memory gap rather than infer one -- §0.11 xxii inferred exactly such a component and
//!     never could. Report the branch-miss ratio: the counter was already opened and read into
//!     Counters, and then dropped, so a change that moved only PREDICTION read as pure noise --
//!     which is the axis both the movepick dispatch and the NNZ walk live on.
//!   * Report RETIRED BRANCHES beside the misses, so the miss RATE is readable. A miss count
//!     alone cannot say whether a surplus is more branches or worse prediction of the same
//!     ones, and those two call for opposite fixes -- reshape the code, or break a data
//!     dependence.
//!   * Report PER-NODE ABSOLUTES beside every ratio, because a ratio with no base cannot say
//!     whether it MATTERS. "cache misses 1.107" reads alarming and is +5.3 misses on a base of
//!     54 per node, which the out-of-order engine hides -- the same tier's cycles sit at 1.018.
//!     Size the thing before chasing it.
//!
//! WHAT IT FOUND ON FIRST USE (2026-07-15, identical 904,097-node tree, zfish/SF):
//!            instructions   cycles    IPC    cache-misses
//!   sse41       1.420       1.440    0.986      1.014
//!   vnni512     1.676       1.554    1.079      0.841
//!   => There is NO IPC or memory deficit -- zfish's IPC and cache behaviour are at parity or
//!      BETTER. The ENTIRE gap is instruction count: zfish executes more work, then retires it
//!      slightly more efficiently. So "cut instructions" is the whole job, and the §0.11 xxii
//!      "IPC component" never existed. Note the gap WIDENS on the top arch (1.420 -> 1.676):
//!      zfish gains -34.3% instructions from sse41->vnni512 where upstream gains -44.4%.
//!
//! THE PROTOCOL IS THE POINT (every rule below was paid for by a wrong result):
//!   * INTERLEAVE, alternating in one loop. Never two readings from different moments (L2).
//!   * TAKE THE MEDIAN OF PER-ROUND PAIRED RATIOS, not the ratio of medians (L3) -- the two disagreed by
//!     2x on a real change here (+6.6% vs the correct +3.2%).
//!   * PIN to one core, so both binaries see the same thermal/frequency state.
//!   * ASSERT NODE COUNTS EQUAL (L5): a different tree is a different workload and every
//!     ratio below would be meaningless. Refuse to report if they differ.
//!
//! Instructions are near-deterministic and are the trustworthy headline; cycles/IPC carry
//! thermal noise, which is exactly why they are reported as interleaved paired ratios.
//!
//! GATING. Set MAX_INSTR_RATIO to make this a regression gate: it exits non-zero when the
//! median paired INSTRUCTION ratio exceeds that bound. Instructions are the right quantity to
//! gate on -- measured spread across rounds is 2,150 in 13.6 BILLION (0.000016%), so a bound
//! is as reproducible as the node count, where an nps threshold is thermally void. Gate on the
//! RATIO against the oracle rather than an absolute count: the ratio cancels machine, libc and
//! net-load differences, so the same bound holds anywhere.
//!
//! Keep this a LOCAL gate. perf_event_open can be refused inside CI containers (poop#17), so it
//! is deliberately not wired into `zig build parity`; run it before committing perf work.
//!
//! Usage (CWD must be resources/ so the net loads):
//!   zig run tools/perf_counters.zig -- ./zf_sse41 $ORACLE/sf_sse41 8 bench 16 1 13
//!   MAX_INSTR_RATIO=1.36 perf_counters ./zf_sse41 $ORACLE/sf_sse41 8 bench 16 1 13
//!
//! The protocol it encodes -- interleaved pairs, core pinning, median of per-round paired
//! ratios -- is the one docs/08-idiomatic-zig.md requires for any speed claim.

const std = @import("std");
const linux = std.os.linux;

// A relative import: this tool is built with `zig build-exe` from tools/, so the probe needs
// no module wiring in build.zig to be reachable.
const probe = @import("perf_counters_probe.zig");
const Counters = probe.Counters;
const runOnce = probe.runOnce;
const runWrapped = probe.runWrapped;

fn median(values: []f64) f64 {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const n = values.len;
    if (n == 0) return 0;
    return if (n % 2 == 1) values[n / 2] else (values[n / 2 - 1] + values[n / 2]) / 2.0;
}

pub fn main(init: std.process.Init) !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    var av_list: std.ArrayList([*:0]const u8) = .empty;
    defer av_list.deinit(gpa);
    while (arg_it.next()) |a| try av_list.append(gpa, a.ptr);
    const av = av_list.items;

    if (av.len < 4) {
        std.debug.print(
            \\usage: perf_counters <binA> <binB> <rounds> [bench-args...]   (CWD must be resources/)
            \\   e.g: perf_counters ./zf_sse41 ../oracle/sf_sse41 8 bench 16 1 13
            \\       perf_counters --budget ./stockfish 5 bench 16 1 8
            \\
            \\Interleaved paired A/B over hardware counters. Reports instructions (the work) and
            \\cycles/IPC/cache-misses (the efficiency). Works on EVERY arch, incl. avx512/vnni512
            \\where callgrind SIGILLs. Refuses to report if node counts differ (different tree =
            \\different workload = meaningless ratio).
            \\
            \\--budget takes ONE binary and prints its own median retired-instruction count
            \\instead of a ratio, for the absolute budget gate (tools/perf_budget.sh).
            \\
            \\--wrap COUNTS A CHILD THIS TOOL DOES NOT DRIVE: it execs the argv after `--`
            \\with stdin/stdout inherited, so a UCI session driven by tools/ltc_replay.py is
            \\measured end to end, and writes one TSV line to the -o path. That is the only
            \\way the warm-game axis (tools/ltc_ab.sh) reaches the counters -- `bench` is the
            \\one workload the modes above can express, and it is a COLD search.
            \\   perf_counters --wrap -o /tmp/c.tsv --core 0 -- ./stockfish
            \\
        , .{});
        return;
    }

    // Wrapper mode. The two modes below both OWN the child: they build its argv, run it to
    // completion and read its stdout back. A warm-game replay is driven move by move from
    // outside, so the child has to keep its own stdin and stdout, and the only thing this
    // process contributes is the counter pair around it.
    if (std.mem.eql(u8, std.mem.span(av[1]), "--wrap")) {
        // -o is required rather than defaulted: the caller runs several of these per round
        // and a shared default path is the collision docs/08-idiomatic-zig.md's fleet rules
        // already charge for once.
        if (av.len < 5 or !std.mem.eql(u8, std.mem.span(av[2]), "-o")) {
            std.debug.print("usage: perf_counters --wrap -o <file> [--core N] -- <argv...>\n", .{});
            std.process.exit(2);
        }
        const out_path = std.mem.span(av[3]);
        var first: usize = 4;
        // The core is selectable here where the modes below hard-code 0, because the child
        // is driven by a SEPARATE process. Landing both on one core costs the engine half
        // its throughput -- measured here, 309 knps against 148 -- which leaves the cycle
        // and wall columns describing the contention rather than the engine. Instructions
        // do not move, which is the column this axis gates on either way.
        var core: usize = 0;
        if (first + 1 < av.len and std.mem.eql(u8, std.mem.span(av[first]), "--core")) {
            core = std.fmt.parseInt(usize, std.mem.span(av[first + 1]), 10) catch 0;
            first += 2;
        }
        if (first < av.len and std.mem.eql(u8, std.mem.span(av[first]), "--")) first += 1;
        if (first >= av.len) {
            std.debug.print("perf_counters --wrap: no command after `--`\n", .{});
            std.process.exit(2);
        }
        const c = try runWrapped(av[first..], core);
        var buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "counters instructions={d} cycles={d} cache_misses={d} branch_misses={d} branches={d}\n",
            .{ c.instructions, c.cycles, c.cache_misses, c.branch_misses, c.branches },
        );
        // Write through the raw syscall the rest of this file already speaks, rather than
        // threading an `Io` down for one line: everything above forks, ptraces and reads
        // counter fds directly, and a second I/O vocabulary here would buy nothing.
        const fd = linux.open(out_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        const fd_signed: isize = @bitCast(fd);
        if (fd_signed < 0) {
            std.debug.print("perf_counters --wrap: cannot write {s}\n", .{out_path});
            std.process.exit(2);
        }
        _ = linux.write(@intCast(fd), line.ptr, line.len);
        _ = linux.close(@intCast(fd));
        return;
    }

    // Single-binary mode. Every ratio above cancels the absolute out, so a REGRESSION that
    // moves both sides equally -- or that has no second side to compare against, which is the
    // usual case on a working branch -- is invisible to them. Print the absolute instead and
    // let the caller hold it to a committed budget.
    if (std.mem.eql(u8, std.mem.span(av[1]), "--budget")) {
        if (av.len < 4) {
            std.debug.print("usage: perf_counters --budget <bin> <rounds> [bench-args...]\n", .{});
            return;
        }
        const bin = av[2];
        const rounds_b = std.fmt.parseInt(usize, std.mem.span(av[3]), 10) catch 5;
        var argv_b1: std.ArrayList([*:0]const u8) = .empty;
        defer argv_b1.deinit(gpa);
        try argv_b1.append(gpa, bin);
        for (av[4..]) |a| try argv_b1.append(gpa, a);

        const samples = try gpa.alloc(f64, rounds_b);
        defer gpa.free(samples);
        var nodes: u64 = 0;
        var round: usize = 0;
        while (round < rounds_b) : (round += 1) {
            const c = try runOnce(gpa, argv_b1.items, 0);
            // Pin the workload with the tree size, the same guard the A/B path applies on
            // every round: a count taken over a different node total is not a datum this
            // gate can use.
            if (nodes == 0) nodes = c.nodes;
            if (c.nodes != nodes) {
                std.debug.print(
                    "budget: node count moved between rounds ({d} then {d}) -- refusing\n",
                    .{ nodes, c.nodes },
                );
                std.process.exit(2);
            }
            samples[round] = @floatFromInt(c.instructions);
        }
        const med = median(samples);
        // One machine-readable line; the shell gate parses this and nothing else.
        std.debug.print(
            "budget nodes={d} rounds={d} instructions={d}\n",
            .{ nodes, rounds_b, @as(u64, @intFromFloat(med)) },
        );
        return;
    }

    const bin_a = av[1];
    const bin_b = av[2];
    const rounds = std.fmt.parseInt(usize, std.mem.span(av[3]), 10) catch 8;

    var argv_a: std.ArrayList([*:0]const u8) = .empty;
    defer argv_a.deinit(gpa);
    var argv_b: std.ArrayList([*:0]const u8) = .empty;
    defer argv_b.deinit(gpa);
    try argv_a.append(gpa, bin_a);
    try argv_b.append(gpa, bin_b);
    for (av[4..]) |a| {
        try argv_a.append(gpa, a);
        try argv_b.append(gpa, a);
    }

    var r_instr = try gpa.alloc(f64, rounds);
    defer gpa.free(r_instr);
    var r_cyc = try gpa.alloc(f64, rounds);
    defer gpa.free(r_cyc);
    var r_ipc = try gpa.alloc(f64, rounds);
    defer gpa.free(r_ipc);
    var r_cache = try gpa.alloc(f64, rounds);
    defer gpa.free(r_cache);
    var r_branch = try gpa.alloc(f64, rounds);
    defer gpa.free(r_branch);
    var r_branch_all = try gpa.alloc(f64, rounds);
    defer gpa.free(r_branch_all);
    var rate_a = try gpa.alloc(f64, rounds);
    defer gpa.free(rate_a);
    var rate_b = try gpa.alloc(f64, rounds);
    defer gpa.free(rate_b);
    var pn_instr_a = try gpa.alloc(f64, rounds);
    defer gpa.free(pn_instr_a);
    var pn_instr_b = try gpa.alloc(f64, rounds);
    defer gpa.free(pn_instr_b);
    var pn_cache_a = try gpa.alloc(f64, rounds);
    defer gpa.free(pn_cache_a);
    var pn_cache_b = try gpa.alloc(f64, rounds);
    defer gpa.free(pn_cache_b);
    var pn_branch_a = try gpa.alloc(f64, rounds);
    defer gpa.free(pn_branch_a);
    var pn_branch_b = try gpa.alloc(f64, rounds);
    defer gpa.free(pn_branch_b);

    var first_a: Counters = .{};
    var first_b: Counters = .{};

    for (0..rounds) |i| {
        const a = try runOnce(gpa, argv_a.items, 0);
        const b = try runOnce(gpa, argv_b.items, 0);
        if (i == 0) {
            first_a = a;
            first_b = b;
            if (a.nodes == 0 or b.nodes == 0) {
                std.debug.print("error: could not parse a node count (A={d}, B={d}).\n" ++
                    "       Run from resources/ so the net loads, and use a `bench` command.\n", .{ a.nodes, b.nodes });
                std.process.exit(2);
            }
            if (a.nodes != b.nodes) {
                std.debug.print(
                    \\error: node counts differ (A={d}, B={d}).
                    \\       Different trees = different workloads; every ratio would be meaningless.
                    \\
                , .{ a.nodes, b.nodes });
                std.process.exit(2);
            }
            std.debug.print("# tree: {d} nodes (identical on both) | {d} rounds | core 0\n", .{ a.nodes, rounds });
            std.debug.print("# {s:>5} {s:>16} {s:>16} {s:>9} {s:>8} {s:>8}\n", .{ "round", "A instr", "B instr", "A/B instr", "A IPC", "B IPC" });
        } else if (a.nodes != first_a.nodes or b.nodes != first_b.nodes) {
            // HOLD THE WORKLOAD ON EVERY ROUND, not only the first. A ratio is a statement
            // about equal amounts of work, and round 1 agreeing does not make round 7 agree:
            // an engine that dies mid-run, a net that goes missing after the first launch, or
            // an ablation that quietly searches a different tree all yield a plausible median
            // that reads as a result. This is why `first_a`/`first_b` are kept.
            std.debug.print(
                \\error: node count moved between rounds (round 1 = A {d} / B {d}, round {d} = A {d} / B {d}).
                \\       The workload changed underneath the measurement; every median would be meaningless.
                \\
            , .{ first_a.nodes, first_b.nodes, i + 1, a.nodes, b.nodes });
            std.process.exit(2);
        }
        r_instr[i] = ratio(a.instructions, b.instructions);
        r_cyc[i] = ratio(a.cycles, b.cycles);
        r_ipc[i] = if (b.ipc() > 0) a.ipc() / b.ipc() else 0;
        r_cache[i] = ratio(a.cache_misses, b.cache_misses);
        r_branch[i] = ratio(a.branch_misses, b.branch_misses);
        r_branch_all[i] = ratio(a.branches, b.branches);
        rate_a[i] = a.branchMissRate();
        rate_b[i] = b.branchMissRate();
        const nodes_f: f64 = @floatFromInt(if (a.nodes == 0) 1 else a.nodes);
        pn_instr_a[i] = @as(f64, @floatFromInt(a.instructions)) / nodes_f;
        pn_instr_b[i] = @as(f64, @floatFromInt(b.instructions)) / nodes_f;
        pn_cache_a[i] = @as(f64, @floatFromInt(a.cache_misses)) / nodes_f;
        pn_cache_b[i] = @as(f64, @floatFromInt(b.cache_misses)) / nodes_f;
        pn_branch_a[i] = @as(f64, @floatFromInt(a.branches)) / nodes_f;
        pn_branch_b[i] = @as(f64, @floatFromInt(b.branches)) / nodes_f;
        std.debug.print("  {d:>5} {d:>16} {d:>16} {d:>9.3} {d:>8.3} {d:>8.3}\n", .{ i + 1, a.instructions, b.instructions, r_instr[i], a.ipc(), b.ipc() });
    }

    std.debug.print("\n# MEDIAN PAIRED A/B RATIOS (A is the first binary)\n", .{});
    std.debug.print("#   instructions : {d:.3}   <- the WORK. near-deterministic; trust this most.\n", .{median(r_instr)});
    std.debug.print("#   cycles       : {d:.3}   <- the TIME. carries thermal noise.\n", .{median(r_cyc)});
    std.debug.print("#   IPC          : {d:.3}   <- the EFFICIENCY. <1 means A retires fewer instr/cycle.\n", .{median(r_ipc)});
    std.debug.print("#   cache misses : {d:.3}\n", .{median(r_cache)});
    std.debug.print("#   branch misses: {d:.3}   <- the FRONT END. flat under a footprint change.\n", .{median(r_branch)});
    std.debug.print("#   branches     : {d:.3}   <- how MANY, not how well predicted.\n", .{median(r_branch_all)});
    std.debug.print("#   miss rate    : A {d:.3}%  B {d:.3}%   <- misses per retired branch.\n", .{ median(rate_a) * 100.0, median(rate_b) * 100.0 });
    // Size every ratio above. A ratio with no base cannot say whether it MATTERS: +12% on a
    // miss count worth 1% of cycles is noise, and the same +12% on one worth 30% is the whole
    // gap. Per-node figures, so two runs over different trees stay comparable.
    std.debug.print(
        "#   per node     : A {d:.0} instr, {d:.2} cache miss, {d:.0} branch\n" ++
            "#                  B {d:.0} instr, {d:.2} cache miss, {d:.0} branch\n",
        .{
            median(pn_instr_a), median(pn_cache_a), median(pn_branch_a),
            median(pn_instr_b), median(pn_cache_b), median(pn_branch_b),
        },
    );
    std.debug.print(
        \\#
        \\# READ IT THIS WAY: cycles ~= instructions / IPC. If A's cycle ratio is worse than its
        \\# instruction ratio, the residue is an IPC/memory gap -- A does similar work but retires
        \\# it slower -- and NO amount of instruction-count reduction closes that half. Split that
        \\# residue with the miss lines: branch misses move when the change is a PREDICTION
        \\# one, cache misses when it is a DATA one, and neither moves when it is code FOOTPRINT.
        \\#
        \\# SPLIT THE MISSES with the branch COUNT beside them. A miss ratio alone cannot say
        \\# whether A missed more because it EXECUTES more branches or because it PREDICTS the
        \\# same ones worse, and those call for opposite fixes -- reshape the code, or break a
        \\# data dependence. Read the branch ratio against the miss ratio: equal miss RATES with
        \\# a high branch ratio is branch DENSITY, not misprediction.
        \\
    , .{});

    // Turn this into a regression gate when MAX_INSTR_RATIO is set (see the header).
    const bound_str = init.minimal.environ.getPosix("MAX_INSTR_RATIO") orelse return;
    const bound = std.fmt.parseFloat(f64, bound_str) catch {
        std.debug.print("error: MAX_INSTR_RATIO={s} is not a number\n", .{bound_str});
        std.process.exit(2);
    };
    const got = median(r_instr);
    if (got > bound) {
        std.debug.print("\nFAIL: instruction ratio {d:.4} exceeds MAX_INSTR_RATIO {d:.4}\n", .{ got, bound });
        std.process.exit(1);
    }
    std.debug.print("\nOK: instruction ratio {d:.4} within MAX_INSTR_RATIO {d:.4}\n", .{ got, bound });
}

fn ratio(a: u64, b: u64) f64 {
    if (b == 0) return 0;
    return @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b));
}
