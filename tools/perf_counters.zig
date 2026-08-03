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

const Counters = struct {
    instructions: u64 = 0,
    cycles: u64 = 0,
    cache_misses: u64 = 0,
    branch_misses: u64 = 0,
    branches: u64 = 0,
    nodes: u64 = 0,

    fn ipc(self: Counters) f64 {
        if (self.cycles == 0) return 0;
        return @as(f64, @floatFromInt(self.instructions)) / @as(f64, @floatFromInt(self.cycles));
    }

    // Report misses per retired branch. A miss COUNT cannot say whether a surplus is more
    // branches or worse prediction of the same ones, and those two call for opposite fixes:
    // one is a code-shape problem, the other a data-dependence problem.
    fn branchMissRate(self: Counters) f64 {
        if (self.branches == 0) return 0;
        return @as(f64, @floatFromInt(self.branch_misses)) / @as(f64, @floatFromInt(self.branches));
    }
};

fn openCounter(config: u64, pid: linux.pid_t) !i32 {
    var attr = std.mem.zeroes(linux.perf_event_attr);
    attr.type = .HARDWARE;
    attr.size = @sizeOf(linux.perf_event_attr);
    attr.config = config;
    attr.flags.disabled = true;
    attr.flags.exclude_kernel = true;
    attr.flags.exclude_hv = true;
    attr.flags.inherit = true;
    const rc = linux.perf_event_open(&attr, pid, -1, -1, 0);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return error.PerfEventOpenFailed;
    return @intCast(rc);
}

/// Parse "Nodes searched  : N" out of the child's bench output. Enforce the L5 gate: without it
/// the tool would happily compare two different trees.
fn parseNodes(text: []const u8) ?u64 {
    const marker = "Nodes searched";
    const at = std.mem.find(u8, text, marker) orelse return null;
    var i = at + marker.len;
    while (i < text.len and (text[i] == ' ' or text[i] == ':')) i += 1;
    var end = i;
    while (end < text.len and text[end] >= '0' and text[end] <= '9') end += 1;
    if (end == i) return null;
    return std.fmt.parseInt(u64, text[i..end], 10) catch null;
}

fn runOnce(gpa: std.mem.Allocator, argv: []const [*:0]const u8, core: usize) !Counters {
    var pipe_fds: [2]i32 = undefined;
    if (linux.pipe(&pipe_fds) != 0) return error.PipeFailed;

    const pid: linux.pid_t = @intCast(linux.fork());
    if (pid == 0) {
        // Child: pin to one core so A and B see identical thermal/frequency state.
        var set = std.mem.zeroes([16]u64);
        set[core / 64] = @as(u64, 1) << @intCast(core % 64);
        _ = linux.syscall3(.sched_setaffinity, 0, @sizeOf(@TypeOf(set)), @intFromPtr(&set));

        _ = linux.close(pipe_fds[0]);
        // Capture BOTH stdout and stderr: the engines print the bench summary (and thus the
        // node count this tool gates on) to stderr, not stdout.
        _ = linux.dup2(pipe_fds[1], 1);
        _ = linux.dup2(pipe_fds[1], 2);
        _ = linux.close(pipe_fds[1]);

        _ = linux.ptrace(linux.PTRACE.TRACEME, 0, 0, 0, 0);
        _ = linux.kill(@intCast(linux.getpid()), linux.SIG.STOP);

        var child_argv: [64:null]?[*:0]const u8 = undefined;
        for (argv, 0..) |a, i| child_argv[i] = a;
        child_argv[argv.len] = null;
        var envp = [_:null]?[*:0]const u8{};
        _ = linux.execve(argv[0], &child_argv, &envp);
        linux.exit(127);
    }
    _ = linux.close(pipe_fds[1]);
    { // wait for the child's SIGSTOP: counters must be armed BEFORE it runs
        var status: u32 = 0;
        _ = linux.waitpid(pid, &status, 0);
    }

    const c_instr = try openCounter(@intFromEnum(linux.PERF.COUNT.HW.INSTRUCTIONS), pid);
    defer _ = linux.close(c_instr);
    const c_cyc = try openCounter(@intFromEnum(linux.PERF.COUNT.HW.CPU_CYCLES), pid);
    defer _ = linux.close(c_cyc);
    const c_cache = openCounter(@intFromEnum(linux.PERF.COUNT.HW.CACHE_MISSES), pid) catch -1;
    const c_branch = openCounter(@intFromEnum(linux.PERF.COUNT.HW.BRANCH_MISSES), pid) catch -1;
    // Retired branches, so the miss RATE is readable and not just the miss count.
    const c_branch_all = openCounter(@intFromEnum(linux.PERF.COUNT.HW.BRANCH_INSTRUCTIONS), pid) catch -1;

    const fds = [_]i32{ c_instr, c_cyc, c_cache, c_branch, c_branch_all };
    for (fds) |fd| if (fd >= 0) {
        _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.RESET, 0);
        _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.ENABLE, 0);
    };
    _ = linux.ptrace(linux.PTRACE.DETACH, pid, 0, 0, 0);

    // Drain stdout while the child runs, or a full pipe deadlocks it.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(pipe_fds[0], &buf, buf.len);
        const signed: isize = @bitCast(n);
        if (signed <= 0) break;
        try out.appendSlice(gpa, buf[0..@intCast(n)]);
    }
    _ = linux.close(pipe_fds[0]);
    {
        var status: u32 = 0;
        _ = linux.waitpid(pid, &status, 0);
    }

    for (fds) |fd| if (fd >= 0) {
        _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.DISABLE, 0);
    };

    var result: Counters = .{};
    _ = linux.read(c_instr, std.mem.asBytes(&result.instructions), 8);
    _ = linux.read(c_cyc, std.mem.asBytes(&result.cycles), 8);
    if (c_cache >= 0) {
        _ = linux.read(c_cache, std.mem.asBytes(&result.cache_misses), 8);
        _ = linux.close(c_cache);
    }
    if (c_branch >= 0) {
        _ = linux.read(c_branch, std.mem.asBytes(&result.branch_misses), 8);
        _ = linux.close(c_branch);
    }
    if (c_branch_all >= 0) {
        _ = linux.read(c_branch_all, std.mem.asBytes(&result.branches), 8);
        _ = linux.close(c_branch_all);
    }
    result.nodes = parseNodes(out.items) orelse 0;
    return result;
}

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
        , .{});
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
