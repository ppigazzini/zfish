// Run the UCI `bench` / `benchmark` commands (extracted from uci.zig).
//
// Drive the bench / benchmark command sequences. Run each command through an
// INJECTED dispatch function pointer (DispatchFn) rather than importing uci.zig's
// command loop back -- uci passes a thin wrapper over dispatchCommand, so this leaf
// carries no cycle. Keep behaviour byte-identical; `stockfish bench` (which pins signature
// 2466447) exercises benchRuntime directly.

const std = @import("std");
const clock = @import("clock");
const benchmark_port = @import("benchmark");
const misc_port = @import("misc");
const engine_mod = @import("engine");
const uci_output = @import("uci_output");
const engine_object = @import("engine_object");
const uci_parse = @import("uci_parse");
const uci_strings = @import("uci_strings");

const parseLimits = uci_parse.parseLimits;
const freeMaybeCString = uci_strings.freeMaybeCString;

/// Dispatch per command, injected by uci.zig (a void wrapper over dispatchCommand).
pub const DispatchFn = *const fn (*engine_object.EngineObject, []const u8) void;

pub fn benchRuntime(uci_ptr: *engine_object.EngineObject, args: []const u8, dispatch: DispatchFn) void {
    const engine_ptr = uci_ptr;

    const current_fen_ptr = engine_mod.fenEngine(engine_ptr) orelse return;
    defer freeMaybeCString(current_fen_ptr);

    const commands_ptr = benchmark_port.setupBench(std.mem.span(current_fen_ptr), args) orelse return;
    defer freeMaybeCString(commands_ptr);
    const commands = std.mem.span(commands_ptr);

    const total_positions = countBenchPositions(commands);
    var nodes: u64 = 0;
    var current_position: u64 = 1;
    var elapsed_start = nowMillis();

    var line_iter = std.mem.splitScalar(u8, commands, '\n');
    while (line_iter.next()) |command| {
        const token = firstToken(command);
        if (token.len == 0) {
            continue;
        }

        if (std.mem.eql(u8, token, "go") or std.mem.eql(u8, token, "eval")) {
            const fen_ptr = engine_mod.fenEngine(engine_ptr) orelse return;
            defer freeMaybeCString(fen_ptr);
            std.debug.print(
                "\nPosition: {d}/{d} ({s})\n",
                .{ current_position, total_positions, std.mem.span(fen_ptr) },
            );
            current_position += 1;

            if (std.mem.eql(u8, token, "go")) {
                const limits = parseLimits(command);
                defer freeMaybeCString(limits.searchmoves);

                if (limits.perft != 0) {
                    nodes += engine_mod.perftEngine(engine_ptr, limits.perft).nodes;
                } else {
                    uci_output.resetLastNodesSearched();
                    dispatch(uci_ptr, command);
                    engine_mod.waitForSearchFinishedEngine(engine_ptr);
                    nodes += uci_output.lastNodesSearched();
                }
            } else {
                dispatch(uci_ptr, command);
            }
            continue;
        }

        dispatch(uci_ptr, command);
        if (std.mem.eql(u8, token, "ucinewgame")) {
            elapsed_start = nowMillis();
        }
    }

    var elapsed = nowMillis() - elapsed_start + 1;
    if (elapsed <= 0) {
        elapsed = 1;
    }

    misc_port.dbgPrint();
    const elapsed_u64: u64 = @intCast(elapsed);
    const nps = if (elapsed_u64 == 0) 0 else @divTrunc(nodes * 1000, elapsed_u64);
    std.debug.print(
        "\n===========================\nTotal time (ms) : {d}\nNodes searched  : {d}\nNodes/second    : {d}\n",
        .{ elapsed, nodes, nps },
    );
}

pub fn benchmarkRuntime(uci_ptr: *engine_object.EngineObject, args: []const u8, dispatch: DispatchFn) void {
    const warmup_positions: usize = 3;
    const engine_ptr = uci_ptr;

    uci_output.setQuietMode(true);
    defer uci_output.setQuietMode(false);

    const setup = benchmark_port.setupBenchmark(args, misc_port.hardwareConcurrency());
    defer freeMaybeCString(setup.commands_ptr);
    defer freeMaybeCString(setup.original_invocation_ptr);
    defer freeMaybeCString(setup.filled_invocation_ptr);

    const commands_ptr = setup.commands_ptr orelse return;
    const commands = std.mem.span(commands_ptr);
    const total_go_commands = countGoCommands(commands);

    const threads_command = std.fmt.allocPrint(std.heap.c_allocator, "setoption name Threads value {d}", .{setup.threads}) catch return;
    defer std.heap.c_allocator.free(threads_command);
    dispatch(uci_ptr, threads_command);

    const hash_command = std.fmt.allocPrint(std.heap.c_allocator, "setoption name Hash value {d}", .{setup.tt_size}) catch return;
    defer std.heap.c_allocator.free(hash_command);
    dispatch(uci_ptr, hash_command);

    dispatch(uci_ptr, "setoption name UCI_Chess960 value false");

    var warmup_count: usize = 1;
    var line_iter = std.mem.splitScalar(u8, commands, '\n');
    while (line_iter.next()) |command| {
        const token = firstToken(command);
        if (token.len == 0) {
            continue;
        }

        if (std.mem.eql(u8, token, "go")) {
            std.debug.print("\rWarmup position {d}/{d}", .{ warmup_count, warmup_positions });
            dispatch(uci_ptr, command);
            engine_mod.waitForSearchFinishedEngine(engine_ptr);
            warmup_count += 1;
        } else {
            dispatch(uci_ptr, command);
        }

        if (warmup_count > warmup_positions) {
            break;
        }
    }

    std.debug.print("\n", .{});

    engine_mod.searchClearEngine(engine_ptr);

    var total_time: i64 = 0;
    var total_nodes: u64 = 0;
    var position_index: usize = 1;
    var hashfull_reads: c_int = 0;
    var total_hashfull_single: c_int = 0;
    var total_hashfull_game: c_int = 0;
    var max_hashfull_single: c_int = 0;
    var max_hashfull_game: c_int = 0;

    line_iter = std.mem.splitScalar(u8, commands, '\n');
    while (line_iter.next()) |command| {
        const token = firstToken(command);
        if (token.len == 0) {
            continue;
        }

        if (std.mem.eql(u8, token, "go")) {
            std.debug.print("\rPosition {d}/{d}", .{ position_index, total_go_commands });
            position_index += 1;

            const started = nowMillis();
            dispatch(uci_ptr, command);
            engine_mod.waitForSearchFinishedEngine(engine_ptr);

            total_time += nowMillis() - started;
            total_nodes += uci_output.lastNodesSearched();

            hashfull_reads += 1;
            const hashfull_single = engine_mod.hashfullEngine(engine_ptr, 0);
            const hashfull_game = engine_mod.hashfullEngine(engine_ptr, 999);
            max_hashfull_single = @max(max_hashfull_single, hashfull_single);
            max_hashfull_game = @max(max_hashfull_game, hashfull_game);
            total_hashfull_single += hashfull_single;
            total_hashfull_game += hashfull_game;
        } else {
            dispatch(uci_ptr, command);
        }
    }

    if (total_time <= 0) {
        total_time = 1;
    }

    misc_port.dbgPrint();
    std.debug.print("\n", .{});

    const version_ptr = misc_port.engineVersionInfoText() orelse return;
    defer freeMaybeCString(version_ptr);
    const compiler_ptr = misc_port.compilerInfoText() orelse return;
    defer freeMaybeCString(compiler_ptr);
    const numa_ptr = engine_mod.numaConfigStringEngine(engine_ptr) orelse return;
    defer freeMaybeCString(numa_ptr);
    const binding_ptr = engine_mod.threadBindingInformationEngine(engine_ptr) orelse return;
    defer freeMaybeCString(binding_ptr);

    const binding = if (std.mem.span(binding_ptr).len == 0) "none" else std.mem.span(binding_ptr);
    const original_invocation = if (setup.original_invocation_ptr) |ptr| std.mem.span(ptr) else "";
    const filled_invocation = if (setup.filled_invocation_ptr) |ptr| std.mem.span(ptr) else "";
    const average_hashfull_single = if (hashfull_reads == 0) 0 else @divTrunc(total_hashfull_single, hashfull_reads);
    const average_hashfull_game = if (hashfull_reads == 0) 0 else @divTrunc(total_hashfull_game, hashfull_reads);
    const total_time_u64: u64 = @intCast(total_time);
    const nps = if (total_time_u64 == 0) 0 else @divTrunc(total_nodes * 1000, total_time_u64);

    std.debug.print(
        "===========================\nVersion                    : {s}{s}" ++
            "Large pages                : {s}\n" ++
            "User invocation            : speedtest {s}\n" ++
            "Filled invocation          : speedtest {s}\n" ++
            "Available processors       : {s}\n" ++
            "Thread count               : {d}\n" ++
            "Thread binding             : {s}\n" ++
            "TT size [MiB]              : {d}\n" ++
            "Hash max, avg [per mille]  : \n" ++
            "    single search          : {d}, {d}\n" ++
            "    single game            : {d}, {d}\n" ++
            "Total nodes searched       : {d}\n" ++
            "Total search time [s]      : {}\n" ++
            "Nodes/second               : {d}\n",
        .{
            std.mem.span(version_ptr),
            std.mem.span(compiler_ptr),
            if (misc_port.hasLargePages()) "yes" else "no",
            original_invocation,
            filled_invocation,
            std.mem.span(numa_ptr),
            setup.threads,
            binding,
            setup.tt_size,
            max_hashfull_single,
            average_hashfull_single,
            max_hashfull_game,
            average_hashfull_game,
            total_nodes,
            @as(f64, @floatFromInt(total_time)) / 1000.0,
            nps,
        },
    );
}

fn countBenchPositions(commands: []const u8) u64 {
    var total: u64 = 0;
    var line_iter = std.mem.splitScalar(u8, commands, '\n');
    while (line_iter.next()) |command| {
        const token = firstToken(command);
        if (std.mem.eql(u8, token, "go") or std.mem.eql(u8, token, "eval")) {
            total += 1;
        }
    }
    return total;
}

fn countGoCommands(commands: []const u8) usize {
    var total: usize = 0;
    var line_iter = std.mem.splitScalar(u8, commands, '\n');
    while (line_iter.next()) |command| {
        if (std.mem.eql(u8, firstToken(command), "go")) {
            total += 1;
        }
    }
    return total;
}

fn firstToken(command: []const u8) []const u8 {
    var token_iter = std.mem.tokenizeAny(u8, command, " \t\r\n");
    return token_iter.next() orelse "";
}

fn nowMillis() i64 {
    // Read monotonic millis (the shared clock module) -- correct for elapsed timing and free
    // of the libc struct_timeval / gettimeofday C-ABI dependency.
    return clock.now();
}
