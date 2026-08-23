//! The measurement primitive behind `perf_counters.zig`: fork a child, arm the hardware
//! counters before its first instruction, and read them back when it exits.
//!
//! Split out of `perf_counters.zig` when that file crossed the 500-line god-file bound.
//! The split is a LEAF -- nothing here imports the CLI back -- because a god-file split's
//! default failure mode is a file cycle, which `arch-report`'s SCC tripwire gates.
//!
//! Two shapes, and the difference is who owns the child's stdio. `runOnce` drives the child
//! to completion on an argv it built and reads the bench summary back off a pipe, which is
//! what the A/B and budget modes need. `runWrapped` leaves the three standard descriptors
//! alone so a driver outside this process can talk UCI to the child move by move, which is
//! what the warm-game axis (`tools/ltc_ab.sh`) needs; the node total comes from that driver,
//! which is reading `info` lines anyway.

const std = @import("std");
const linux = std.os.linux;

pub const Counters = struct {
    instructions: u64 = 0,
    cycles: u64 = 0,
    cache_misses: u64 = 0,
    branch_misses: u64 = 0,
    branches: u64 = 0,
    nodes: u64 = 0,

    pub fn ipc(self: Counters) f64 {
        if (self.cycles == 0) return 0;
        return @as(f64, @floatFromInt(self.instructions)) / @as(f64, @floatFromInt(self.cycles));
    }

    // Report misses per retired branch. A miss COUNT cannot say whether a surplus is more
    // branches or worse prediction of the same ones, and those two call for opposite fixes:
    // one is a code-shape problem, the other a data-dependence problem.
    pub fn branchMissRate(self: Counters) f64 {
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

pub fn runOnce(gpa: std.mem.Allocator, argv: []const [*:0]const u8, core: usize) !Counters {
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

/// Count an INTERACTIVELY DRIVEN child, rather than one this tool runs to completion on its
/// own argv. `runOnce` owns the child's stdout so it can read the bench summary back; a UCI
/// session driven over stdin by tools/ltc_replay.py needs the opposite -- the three standard
/// descriptors stay wired to the driver and the counters are the only thing this process
/// keeps. The node total then comes from the driver, which is reading `info` lines anyway.
///
/// The core pin and the arm-before-first-instruction handshake are the same as `runOnce`'s,
/// and for the same reasons: both sides of an A/B must see one thermal state, and a counter
/// enabled after `execve` has already missed the startup it is there to measure.
pub fn runWrapped(argv: []const [*:0]const u8, core: usize) !Counters {
    const pid: linux.pid_t = @intCast(linux.fork());
    if (pid == 0) {
        var set = std.mem.zeroes([16]u64);
        set[core / 64] = @as(u64, 1) << @intCast(core % 64);
        _ = linux.syscall3(.sched_setaffinity, 0, @sizeOf(@TypeOf(set)), @intFromPtr(&set));

        _ = linux.ptrace(linux.PTRACE.TRACEME, 0, 0, 0, 0);
        _ = linux.kill(@intCast(linux.getpid()), linux.SIG.STOP);

        var child_argv: [64:null]?[*:0]const u8 = undefined;
        for (argv, 0..) |a, i| child_argv[i] = a;
        child_argv[argv.len] = null;
        var envp = [_:null]?[*:0]const u8{};
        _ = linux.execve(argv[0], &child_argv, &envp);
        linux.exit(127);
    }
    {
        var status: u32 = 0;
        _ = linux.waitpid(pid, &status, 0);
    }

    const c_instr = try openCounter(@intFromEnum(linux.PERF.COUNT.HW.INSTRUCTIONS), pid);
    defer _ = linux.close(c_instr);
    const c_cyc = try openCounter(@intFromEnum(linux.PERF.COUNT.HW.CPU_CYCLES), pid);
    defer _ = linux.close(c_cyc);
    const c_cache = openCounter(@intFromEnum(linux.PERF.COUNT.HW.CACHE_MISSES), pid) catch -1;
    const c_branch = openCounter(@intFromEnum(linux.PERF.COUNT.HW.BRANCH_MISSES), pid) catch -1;
    const c_branch_all = openCounter(@intFromEnum(linux.PERF.COUNT.HW.BRANCH_INSTRUCTIONS), pid) catch -1;

    const fds = [_]i32{ c_instr, c_cyc, c_cache, c_branch, c_branch_all };
    for (fds) |fd| if (fd >= 0) {
        _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.RESET, 0);
        _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.ENABLE, 0);
    };
    _ = linux.ptrace(linux.PTRACE.DETACH, pid, 0, 0, 0);

    var status: u32 = 0;
    _ = linux.waitpid(pid, &status, 0);

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
    return result;
}
