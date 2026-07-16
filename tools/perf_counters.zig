//! Run interleaved paired A/B over CPU HARDWARE COUNTERS. The tool REPORT-18 spent five audits
//! saying it could not have.
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
//!   * Give BOTH: instructions (the work) AND cycles/IPC/cache-misses (the efficiency),
//!     at native speed, on EVERY tier. It is the only tool here that can SEE an IPC/memory gap
//!     rather than infer one -- §0.11 xxii inferred exactly such a component and never could.
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
//! Usage (CWD must be net/ so the net loads):
//!   zig run tools/perf_counters.zig -- ./zf_sse41 $ORACLE/sf_sse41 8 bench 16 1 13
//!   MAX_INSTR_RATIO=1.36 perf_counters ./zf_sse41 $ORACLE/sf_sse41 8 bench 16 1 13
//!
//! See __DEV/4-PERFORMANCE-REFERENCES.md sections 1-2 for the laws this encodes.

const std = @import("std");
const linux = std.os.linux;

const Counters = struct {
    instructions: u64 = 0,
    cycles: u64 = 0,
    cache_misses: u64 = 0,
    branch_misses: u64 = 0,
    nodes: u64 = 0,

    fn ipc(self: Counters) f64 {
        if (self.cycles == 0) return 0;
        return @as(f64, @floatFromInt(self.instructions)) / @as(f64, @floatFromInt(self.cycles));
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
    const at = std.mem.indexOf(u8, text, marker) orelse return null;
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

    const fds = [_]i32{ c_instr, c_cyc, c_cache, c_branch };
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
            \\usage: perf_counters <binA> <binB> <rounds> [bench-args...]   (CWD must be net/)
            \\   e.g: perf_counters ./zf_sse41 ../oracle/sf_sse41 8 bench 16 1 13
            \\
            \\Interleaved paired A/B over hardware counters. Reports instructions (the work) and
            \\cycles/IPC/cache-misses (the efficiency). Works on EVERY arch, incl. avx512/vnni512
            \\where callgrind SIGILLs. Refuses to report if node counts differ (different tree =
            \\different workload = meaningless ratio).
            \\
        , .{});
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
                    "       Run from net/ so the net loads, and use a `bench` command.\n", .{ a.nodes, b.nodes });
                return;
            }
            if (a.nodes != b.nodes) {
                std.debug.print(
                    \\error: node counts differ (A={d}, B={d}).
                    \\       Different trees = different workloads; every ratio would be meaningless.
                    \\
                , .{ a.nodes, b.nodes });
                return;
            }
            std.debug.print("# tree: {d} nodes (identical on both) | {d} rounds | core 0\n", .{ a.nodes, rounds });
            std.debug.print("# {s:>5} {s:>16} {s:>16} {s:>9} {s:>8} {s:>8}\n", .{ "round", "A instr", "B instr", "A/B instr", "A IPC", "B IPC" });
        }
        r_instr[i] = ratio(a.instructions, b.instructions);
        r_cyc[i] = ratio(a.cycles, b.cycles);
        r_ipc[i] = if (b.ipc() > 0) a.ipc() / b.ipc() else 0;
        r_cache[i] = ratio(a.cache_misses, b.cache_misses);
        std.debug.print("  {d:>5} {d:>16} {d:>16} {d:>9.3} {d:>8.3} {d:>8.3}\n", .{ i + 1, a.instructions, b.instructions, r_instr[i], a.ipc(), b.ipc() });
    }

    std.debug.print("\n# MEDIAN PAIRED A/B RATIOS (A is the first binary)\n", .{});
    std.debug.print("#   instructions : {d:.3}   <- the WORK. near-deterministic; trust this most.\n", .{median(r_instr)});
    std.debug.print("#   cycles       : {d:.3}   <- the TIME. carries thermal noise.\n", .{median(r_cyc)});
    std.debug.print("#   IPC          : {d:.3}   <- the EFFICIENCY. <1 means A retires fewer instr/cycle.\n", .{median(r_ipc)});
    std.debug.print("#   cache misses : {d:.3}\n", .{median(r_cache)});
    std.debug.print(
        \\#
        \\# READ IT THIS WAY: cycles ~= instructions / IPC. If A's cycle ratio is worse than its
        \\# instruction ratio, the residue is an IPC/memory gap -- A does similar work but retires
        \\# it slower -- and NO amount of instruction-count reduction closes that half.
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
