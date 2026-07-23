//! Localize a CYCLE gap that instruction counts cannot explain.
//!
//! WHY THIS EXISTS. tools/perf_counters.zig ends at 4 fixed counters and answered the big
//! question (the campaign gap is instruction COUNT). It cannot answer the next one: when a
//! tier shows FEWER instructions but MORE cycles (sse41: instr 0.96 vs cycles 1.02), which
//! pipeline resource eats the difference? That needs stall-class counters -- frontend
//! starvation vs backend-resource blocking, and inside backend: load/store queue, ROB,
//! register files, schedulers -- none of which the generic PERF_COUNT_HW_* set exposes.
//!
//! HOW IT COUNTS. Same protocol as perf_counters.zig (fork, pin to core 0, ptrace-stop,
//! arm counters before exec, interleave A/B, median of per-round PAIRED ratios, refuse on a
//! node-count mismatch). The difference is the counter table: each named SET is up to four
//! events -- cycles and instructions ride along as in-set anchors so every set
//! independently re-verifies the instr/cycle anomaly it is trying to explain -- plus two
//! novel counters from the set's stall class. Zen 4 (family 19h) raw PMC encodings follow
//! /sys/devices/cpu/format: event takes config bits 0-7 and 32-35, umask bits 8-15.
//!
//! THE SETS. `slots` and `front` give AMD's top-down level 1 (PMCx1A0, per-slot: 6 dispatch
//! slots per cycle): frontend-bound slots, backend-stalled slots, retired ops. `l1`/`tlb`
//! split memory stalls by structure; `lq`/`rob`/`regs` split backend token stalls by
//! resource (PMCx0AE/0xAF); `opsrc` splits frontend delivery decoder-vs-op-cache (PMCx0AA)
//! and adds IC misses (PMCx18E). `probe` runs binary A alone over EVERY candidate event in
//! batches of four and prints raw counts -- run it first on a new kernel/CPU: an event that
//! reads 0 there is unsupported (WSL2 passes most but not necessarily all through).
//!
//! Usage (CWD must be resources/ so the net loads):
//!   zig run tools/perf_stalls.zig -- ./zf_sse41 $ORACLE/sf_sse41 12 slots bench 16 1 13
//!   zig run tools/perf_stalls.zig -- ./zf_sse41 ./zf_sse41 12 slots bench 16 1 13  # A/A control
//!   zig run tools/perf_stalls.zig -- ./zf_sse41 x probe bench 16 1 13
//!
//! Run the A/A control for every NEW counter set before trusting an A/B delta: the serial
//! cycle floor on this box is +-1% with a +0.65% A/A bias, and a stall counter has no
//! established floor until its A/A spread has been seen once.

const std = @import("std");
const linux = std.os.linux;

/// Encode a Zen 4 core PMC: event low byte in config[7:0], high nibble in config[35:32],
/// unit mask in config[15:8] -- exactly the sysfs format lines for this PMU.
fn zen4(event: u12, umask: u8) u64 {
    const ev: u64 = event;
    return (ev & 0xFF) | (@as(u64, umask) << 8) | ((ev >> 8) << 32);
}

const Event = struct {
    name: []const u8,
    type_: linux.PERF.TYPE,
    config: u64,
};

const cycles_ev = Event{ .name = "cycles", .type_ = .HARDWARE, .config = @intFromEnum(linux.PERF.COUNT.HW.CPU_CYCLES) };
const instr_ev = Event{ .name = "instructions", .type_ = .HARDWARE, .config = @intFromEnum(linux.PERF.COUNT.HW.INSTRUCTIONS) };

// Zen 4 top-down level 1 (PMCx1A0 de_no_dispatch_per_slot, units of dispatch SLOTS,
// 6 per cycle) and its retiring complement (PMCx0C1 ex_ret_ops).
const fe_slots_ev = Event{ .name = "fe_bound_slots", .type_ = .RAW, .config = zen4(0x1A0, 0x01) };
const be_slots_ev = Event{ .name = "be_stall_slots", .type_ = .RAW, .config = zen4(0x1A0, 0x1E) };
const ret_ops_ev = Event{ .name = "retired_ops", .type_ = .RAW, .config = zen4(0x0C1, 0x00) };

const NamedSet = struct { name: []const u8, events: []const Event };

const sets = [_]NamedSet{
    // Top-down: which side of dispatch loses the slots.
    .{ .name = "slots", .events = &.{ cycles_ev, instr_ev, fe_slots_ev, be_slots_ev } },
    // Frontend cross-check: the kernel's generic frontend-stall mapping + retired uops.
    .{ .name = "front", .events = &.{ cycles_ev, ret_ops_ev, fe_slots_ev, .{ .name = "stall_fe_generic", .type_ = .HARDWARE, .config = @intFromEnum(linux.PERF.COUNT.HW.STALLED_CYCLES_FRONTEND) } } },
    // L1 misses by structure: demand DC fills from anywhere (0x43; 0x44 adds
    // prefetcher-initiated fills) + IC tag misses.
    .{ .name = "l1", .events = &.{ cycles_ev, instr_ev, .{ .name = "l1d_demand_fill", .type_ = .RAW, .config = zen4(0x043, 0xFF) }, .{ .name = "l1i_tag_miss", .type_ = .RAW, .config = zen4(0x18E, 0x18) } } },
    // TLBs: all L1 dTLB misses (L2 hits + walks) and instruction-side L2 walks.
    .{ .name = "tlb", .events = &.{ cycles_ev, instr_ev, .{ .name = "dtlb_l1_miss", .type_ = .RAW, .config = zen4(0x045, 0xFF) }, .{ .name = "itlb_l2_walk", .type_ = .RAW, .config = zen4(0x085, 0xFF) } } },
    // Backend token stalls, memory queues: cycles dispatch held for a load/store queue slot.
    .{ .name = "lq", .events = &.{ cycles_ev, instr_ev, .{ .name = "stall_load_q", .type_ = .RAW, .config = zen4(0x0AE, 0x02) }, .{ .name = "stall_store_q", .type_ = .RAW, .config = zen4(0x0AE, 0x04) } } },
    // Backend token stalls, retire/schedule: ROB full and integer-scheduler tokens.
    .{ .name = "rob", .events = &.{ cycles_ev, instr_ev, .{ .name = "stall_rob", .type_ = .RAW, .config = zen4(0x0AF, 0x20) }, .{ .name = "stall_int_sched", .type_ = .RAW, .config = zen4(0x0AF, 0x0F) } } },
    // Backend token stalls, register files: integer and FP/vector PRF exhaustion.
    .{ .name = "regs", .events = &.{ cycles_ev, instr_ev, .{ .name = "stall_int_prf", .type_ = .RAW, .config = zen4(0x0AE, 0x01) }, .{ .name = "stall_fp_prf", .type_ = .RAW, .config = zen4(0x0AE, 0x20) } } },
    // Frontend delivery source: ops from the x86 decoder vs from the op cache, + IC misses.
    .{ .name = "opsrc", .events = &.{ cycles_ev, .{ .name = "ops_from_decoder", .type_ = .RAW, .config = zen4(0x0AA, 0x01) }, .{ .name = "ops_from_opcache", .type_ = .RAW, .config = zen4(0x0AA, 0x02) }, .{ .name = "l1i_tag_miss", .type_ = .RAW, .config = zen4(0x18E, 0x18) } } },
};

/// Every distinct event above plus near variants, for `probe` mode.
const probe_events = [_]Event{
    cycles_ev,
    instr_ev,
    fe_slots_ev,
    be_slots_ev,
    ret_ops_ev,
    .{ .name = "stall_fe_generic", .type_ = .HARDWARE, .config = @intFromEnum(linux.PERF.COUNT.HW.STALLED_CYCLES_FRONTEND) },
    .{ .name = "l1d_demand_fill", .type_ = .RAW, .config = zen4(0x043, 0xFF) },
    .{ .name = "l1d_any_fill", .type_ = .RAW, .config = zen4(0x044, 0xFF) },
    .{ .name = "l1i_tag_miss", .type_ = .RAW, .config = zen4(0x18E, 0x18) },
    .{ .name = "dtlb_l1_miss", .type_ = .RAW, .config = zen4(0x045, 0xFF) },
    .{ .name = "itlb_l2_hit", .type_ = .RAW, .config = zen4(0x084, 0x00) },
    .{ .name = "itlb_l2_walk", .type_ = .RAW, .config = zen4(0x085, 0xFF) },
    .{ .name = "stall_load_q", .type_ = .RAW, .config = zen4(0x0AE, 0x02) },
    .{ .name = "stall_store_q", .type_ = .RAW, .config = zen4(0x0AE, 0x04) },
    .{ .name = "stall_rob", .type_ = .RAW, .config = zen4(0x0AF, 0x20) },
    .{ .name = "stall_int_sched", .type_ = .RAW, .config = zen4(0x0AF, 0x0F) },
    .{ .name = "stall_int_prf", .type_ = .RAW, .config = zen4(0x0AE, 0x01) },
    .{ .name = "stall_fp_prf", .type_ = .RAW, .config = zen4(0x0AE, 0x20) },
    .{ .name = "ops_from_decoder", .type_ = .RAW, .config = zen4(0x0AA, 0x01) },
    .{ .name = "ops_from_opcache", .type_ = .RAW, .config = zen4(0x0AA, 0x02) },
};

const max_events = 4;

const Sample = struct {
    counts: [max_events]u64 = @splat(0),
    nodes: u64 = 0,
};

fn openCounter(ev: Event, pid: linux.pid_t) !i32 {
    var attr = std.mem.zeroes(linux.perf_event_attr);
    attr.type = ev.type_;
    attr.size = @sizeOf(linux.perf_event_attr);
    attr.config = ev.config;
    attr.flags.disabled = true;
    attr.flags.exclude_kernel = true;
    attr.flags.exclude_hv = true;
    attr.flags.inherit = true;
    const rc = linux.perf_event_open(&attr, pid, -1, -1, 0);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return error.PerfEventOpenFailed;
    return @intCast(rc);
}

/// Parse "Nodes searched  : N" out of the child's bench output; the L5 gate needs it.
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

fn runOnce(gpa: std.mem.Allocator, argv: []const [*:0]const u8, events: []const Event, core: usize) !Sample {
    var pipe_fds: [2]i32 = undefined;
    if (linux.pipe(&pipe_fds) != 0) return error.PipeFailed;

    const pid: linux.pid_t = @intCast(linux.fork());
    if (pid == 0) {
        // Child: pin to one core so A and B see identical thermal/frequency state.
        var set = std.mem.zeroes([16]u64);
        set[core / 64] = @as(u64, 1) << @intCast(core % 64);
        _ = linux.syscall3(.sched_setaffinity, 0, @sizeOf(@TypeOf(set)), @intFromPtr(&set));

        _ = linux.close(pipe_fds[0]);
        // Capture BOTH stdout and stderr: the bench summary (and its node count) is on stderr.
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

    var fds: [max_events]i32 = @splat(-1);
    for (events, 0..) |ev, i| fds[i] = openCounter(ev, pid) catch -1;
    for (fds[0..events.len]) |fd| if (fd >= 0) {
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

    var result: Sample = .{};
    for (fds[0..events.len], 0..) |fd, i| if (fd >= 0) {
        _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.DISABLE, 0);
        _ = linux.read(fd, std.mem.asBytes(&result.counts[i]), 8);
        _ = linux.close(fd);
    };
    result.nodes = parseNodes(out.items) orelse 0;
    return result;
}

fn median(values: []f64) f64 {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const n = values.len;
    if (n == 0) return 0;
    return if (n % 2 == 1) values[n / 2] else (values[n / 2 - 1] + values[n / 2]) / 2.0;
}

fn ratio(a: u64, b: u64) f64 {
    if (b == 0) return 0;
    return @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b));
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

    if (av.len < 5) {
        std.debug.print(
            \\usage: perf_stalls <binA> <binB> <rounds> <set> [bench-args...]   (CWD must be resources/)
            \\       perf_stalls <binA> x 1 probe [bench-args...]
            \\  e.g: perf_stalls ./zf_sse41 ../oracle/sf_sse41 12 slots bench 16 1 13
            \\
            \\Interleaved paired A/B over Zen 4 stall-class counters, one named SET (<=4 events,
            \\cycles+instructions ride along as in-set anchors) per invocation:
            \\
        , .{});
        for (sets) |s| {
            std.debug.print("  {s:>6}:", .{s.name});
            for (s.events) |ev| std.debug.print(" {s}", .{ev.name});
            std.debug.print("\n", .{});
        }
        std.debug.print(
            \\
            \\`probe` runs binA alone over every candidate event (batches of 4) and prints raw
            \\counts -- a 0 means the kernel/CPU does not support that event; run it before
            \\trusting any set on a new box. Run each set as A/A first: a stall counter has no
            \\noise floor until its A/A spread has been seen.
            \\
        , .{});
        return;
    }

    const bin_a = av[1];

    // Probe mode: enumerate candidate events on binA alone, four per run.
    if (std.mem.eql(u8, std.mem.span(av[4]), "probe")) {
        var argv_a: std.ArrayList([*:0]const u8) = .empty;
        defer argv_a.deinit(gpa);
        try argv_a.append(gpa, bin_a);
        for (av[5..]) |a| try argv_a.append(gpa, a);
        std.debug.print("# probe: {s}\n", .{std.mem.span(bin_a)});
        var start: usize = 0;
        while (start < probe_events.len) : (start += max_events) {
            const batch = probe_events[start..@min(start + max_events, probe_events.len)];
            const s = try runOnce(gpa, argv_a.items, batch, 0);
            for (batch, 0..) |ev, i| {
                std.debug.print("  {s:<18} {d:>16}{s}\n", .{ ev.name, s.counts[i], if (s.counts[i] == 0) "   <- UNSUPPORTED?" else "" });
            }
        }
        return;
    }

    const bin_b = av[2];
    const rounds = std.fmt.parseInt(usize, std.mem.span(av[3]), 10) catch 8;
    const set_name = std.mem.span(av[4]);
    const set = for (sets) |s| {
        if (std.mem.eql(u8, s.name, set_name)) break s;
    } else {
        std.debug.print("error: unknown set '{s}' (run with no args for the list)\n", .{set_name});
        std.process.exit(2);
    };
    const events = set.events;

    var argv_a: std.ArrayList([*:0]const u8) = .empty;
    defer argv_a.deinit(gpa);
    var argv_b: std.ArrayList([*:0]const u8) = .empty;
    defer argv_b.deinit(gpa);
    try argv_a.append(gpa, bin_a);
    try argv_b.append(gpa, bin_b);
    for (av[5..]) |a| {
        try argv_a.append(gpa, a);
        try argv_b.append(gpa, a);
    }

    var ratios: [max_events][]f64 = undefined;
    var abs_a: [max_events][]f64 = undefined;
    var abs_b: [max_events][]f64 = undefined;
    for (0..events.len) |e| {
        ratios[e] = try gpa.alloc(f64, rounds);
        abs_a[e] = try gpa.alloc(f64, rounds);
        abs_b[e] = try gpa.alloc(f64, rounds);
    }
    defer for (0..events.len) |e| {
        gpa.free(ratios[e]);
        gpa.free(abs_a[e]);
        gpa.free(abs_b[e]);
    };

    for (0..rounds) |i| {
        const a = try runOnce(gpa, argv_a.items, events, 0);
        const b = try runOnce(gpa, argv_b.items, events, 0);
        if (i == 0) {
            if (a.nodes == 0 or b.nodes == 0) {
                std.debug.print("error: could not parse a node count (A={d}, B={d}).\n" ++
                    "       Run from resources/ so the net loads, and use a `bench` command.\n", .{ a.nodes, b.nodes });
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
            std.debug.print("# set {s} | tree: {d} nodes (identical on both) | {d} rounds | core 0\n", .{ set.name, a.nodes, rounds });
        }
        std.debug.print("  round {d:>2}", .{i + 1});
        for (events, 0..) |ev, e| {
            ratios[e][i] = ratio(a.counts[e], b.counts[e]);
            abs_a[e][i] = @floatFromInt(a.counts[e]);
            abs_b[e][i] = @floatFromInt(b.counts[e]);
            std.debug.print("  {s}={d:.3}", .{ ev.name, ratios[e][i] });
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("\n# MEDIAN PAIRED A/B RATIOS, set {s} (A first; medians of absolutes alongside)\n", .{set.name});
    var cyc_a: f64 = 0;
    var cyc_b: f64 = 0;
    for (events, 0..) |ev, e| {
        const med_a = median(abs_a[e]);
        const med_b = median(abs_b[e]);
        if (std.mem.eql(u8, ev.name, "cycles")) {
            cyc_a = med_a;
            cyc_b = med_b;
        }
        std.debug.print("#   {s:<18}: {d:.4}   (A {d:.0}, B {d:.0})\n", .{ ev.name, median(ratios[e]), med_a, med_b });
    }
    // Rate view: counts per cycle, so a stall class reads as a fraction of time. The slot
    // events are per-SLOT (6 dispatch slots per cycle) -- read them against each other or
    // divide by 6.
    if (cyc_a > 0 and cyc_b > 0) {
        std.debug.print("#\n# per-cycle rates (median absolute / median cycles):\n", .{});
        for (events, 0..) |ev, e| {
            if (std.mem.eql(u8, ev.name, "cycles")) continue;
            std.debug.print("#   {s:<18}: A {d:.4}  B {d:.4}\n", .{ ev.name, median(abs_a[e]) / cyc_a, median(abs_b[e]) / cyc_b });
        }
    }
}
