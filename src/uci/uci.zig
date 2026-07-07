const std = @import("std");
const builtin = @import("builtin");
const c = @import("libc");

const benchmark_port = @import("benchmark");
const misc_port = @import("misc");
const engine_mod = @import("engine");
const option_port = @import("option");
const uci_wdl = @import("uci_wdl");
const uci_output = @import("uci_output");
const native_engine = @import("native_engine");
const graph_layout = @import("graph_layout");
const clock = @import("clock");
const uci_strings = @import("uci_strings");

// C stdio stdin, obtained portably (M-PORT). @cImport's translation of the stream macros
// is not uniform across the owned OSes (a comptime-uncallable __acrt_iob_func() macro on
// Windows, an inline getter on macOS), so the underlying entry point is declared directly:
// glibc's global FILE* symbol, macOS's __stdinp global, or the Windows CRT accessor. Each
// arm is comptime-selected, so only the target's symbol is referenced/linked.
const std_streams = struct {
    extern "c" fn __acrt_iob_func(index: c_uint) *c.FILE;
    extern "c" var __stdinp: *c.FILE;
    extern "c" var stdin: *c.FILE;
};
fn cStdin() *c.FILE {
    return switch (builtin.os.tag) {
        .windows => std_streams.__acrt_iob_func(0),
        .macos, .ios, .tvos, .watchos, .visionos => std_streams.__stdinp,
        else => std_streams.stdin,
    };
}

pub const DispatchResult = struct {
    should_quit: u8,
};

const CommandKind = enum {
    quit,
    stop,
    ponderhit,
    uci,
    setoption,
    go,
    position,
    ucinewgame,
    isready,
    flip,
    bench,
    speedtest,
    visualize,
    eval,
    compiler,
    export_net,
    help,
    unknown,
};

// Same layout as the engine module's ByteView; alias it so setPositionEngine takes our
// move views directly (M16.5) rather than through a duplicate C-ABI-mirror struct.
const ByteView = engine_mod.ByteView;

// Build the native LimitsType from the parsed UCI `go` args (including the libc++
// searchmoves std::vector<std::string>) and hand it to the engine go driver. Relocated
// from main.zig (M16.7): startTime is stamped here (earliest point), so the info-line
// elapsed/nps are correct; the searchmoves element buffer is freed after start_thinking
// deep-copied the limits into the workers (moves are SSO -- no per-string heap).
fn goParsed(engine_ptr: *anyopaque, parsed: ParsedLimits) void {
    var limits: graph_layout.LimitsType = std.mem.zeroes(graph_layout.LimitsType);
    const base: [*]u8 = @ptrCast(&limits);
    limits.start_time = clock.now();
    limits.time[0] = parsed.wtime;
    limits.time[1] = parsed.btime;
    limits.inc[0] = parsed.winc;
    limits.inc[1] = parsed.binc;
    limits.movestogo = parsed.movestogo;
    limits.depth = parsed.depth;
    limits.mate = parsed.mate;
    limits.perft = parsed.perft;
    limits.infinite = if (parsed.infinite != 0) 1 else 0;
    limits.movetime = parsed.movetime;
    limits.nodes = parsed.nodes;
    limits.ponder_mode = parsed.ponder_mode;

    var sm_elems: ?*anyopaque = null;
    if (parsed.searchmoves) |sm_ptr| {
        const sm = std.mem.span(sm_ptr);
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, sm, '\n');
        while (it.next()) |tok| {
            if (tok.len != 0) count += 1;
        }
        if (count != 0) {
            const nbytes = count * 24; // count * sizeof(std::string)
            const elems = std.c.malloc(nbytes) orelse @panic("searchmoves: operator new failed");
            const ebase: [*]u8 = @ptrCast(elems);
            @memset(ebase[0..nbytes], 0);
            var i: usize = 0;
            it = std.mem.splitScalar(u8, sm, '\n');
            while (it.next()) |tok| {
                if (tok.len == 0) continue;
                const slot = ebase + i * 24;
                slot[0] = @intCast(tok.len << 1); // libc++ SSO size byte
                @memcpy(slot[1 .. 1 + tok.len], tok);
                i += 1;
            }
            // Write the libc++ vector {begin,end,cap} into the native searchmoves field
            // (LimitsType is a native struct now; searchmoves is no longer at offset 0).
            @as(*usize, @ptrCast(@alignCast(&limits.searchmoves[0]))).* = @intFromPtr(elems); // begin
            @as(*usize, @ptrCast(@alignCast(&limits.searchmoves[8]))).* = @intFromPtr(elems) + nbytes; // end
            @as(*usize, @ptrCast(@alignCast(&limits.searchmoves[16]))).* = @intFromPtr(elems) + nbytes; // cap
            sm_elems = elems;
        }
    }

    engine_mod.goEngine(engine_ptr, @ptrCast(base));
    if (sm_elems) |e| std.c.free(e);
}

pub fn dispatchCommand(engine: *anyopaque, input: []const u8) DispatchResult {
    const trimmed = trimAsciiWhitespace(input);
    if (trimmed.len == 0 or trimmed[0] == '#')
        return .{ .should_quit = 0 };

    var token_iter = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    const token = token_iter.next() orelse return .{ .should_quit = 0 };
    const args = trimAsciiWhitespace(trimmed[token.len..]);

    switch (classifyCommandToken(token)) {
        .quit => {
            engine_mod.stopEngine(engine);
            return .{ .should_quit = 1 };
        },
        .stop => {
            engine_mod.stopEngine(engine);
            engine_mod.setPonderhitEngine(engine, 1);
            return .{ .should_quit = 0 };
        },
        .ponderhit => {
            engine_mod.setPonderhitEngine(engine, 0);
            return .{ .should_quit = 0 };
        },
        .uci => {
            const info_ptr = misc_port.engineInfoText(1) orelse return .{ .should_quit = 0 };
            defer c.free(@ptrCast(info_ptr));
            const options_ptr = option_port.renderOptions() orelse return .{ .should_quit = 0 };
            defer c.free(@ptrCast(options_ptr));

            std.debug.print(
                "id name {s}\n{s}\nuciok\n",
                .{ std.mem.span(info_ptr), std.mem.span(options_ptr) },
            );
            return .{ .should_quit = 0 };
        },
        .setoption => {
            applySetoption(engine, trimmed);
            return .{ .should_quit = 0 };
        },
        .go => {
            applyGo(engine, trimmed);
            return .{ .should_quit = 0 };
        },
        .position => {
            applyPosition(engine, trimmed);
            return .{ .should_quit = 0 };
        },
        .ucinewgame => {
            engine_mod.searchClearEngine(engine);
            return .{ .should_quit = 0 };
        },
        .isready => {
            _ = c.puts("readyok");
            return .{ .should_quit = 0 };
        },
        .flip => {
            engine_mod.flipEngine(engine);
            return .{ .should_quit = 0 };
        },
        .bench => {
            benchRuntime(engine, args);
            return .{ .should_quit = 0 };
        },
        .speedtest => {
            benchmarkRuntime(engine, args);
            return .{ .should_quit = 0 };
        },
        .visualize => {
            const text_ptr = engine_mod.visualizeEngine(engine) orelse return .{ .should_quit = 0 };
            defer c.free(@ptrCast(text_ptr));
            _ = c.puts(@ptrCast(text_ptr));
            return .{ .should_quit = 0 };
        },
        .eval => {
            const text_ptr = engine_mod.traceEvalEngine(engine) orelse return .{ .should_quit = 0 };
            defer c.free(@ptrCast(text_ptr));
            std.debug.print("\n{s}\n", .{std.mem.span(text_ptr)});
            return .{ .should_quit = 0 };
        },
        .compiler => {
            const compiler_ptr = misc_port.compilerInfoText() orelse return .{ .should_quit = 0 };
            defer c.free(@ptrCast(compiler_ptr));
            _ = c.puts(@ptrCast(compiler_ptr));
            return .{ .should_quit = 0 };
        },
        .export_net => {
            const filename = trimAsciiWhitespace(args);
            engine_mod.saveNetworkEngine(
                engine,
                if (filename.len != 0) filename else null,
            );
            return .{ .should_quit = 0 };
        },
        .help => {
            const help_ptr = helpText() orelse return .{ .should_quit = 0 };
            defer c.free(@ptrCast(help_ptr));
            _ = c.puts(@ptrCast(help_ptr));
            return .{ .should_quit = 0 };
        },
        .unknown => {
            const unknown_ptr = formatUnknownCommand(trimmed) orelse return .{ .should_quit = 0 };
            defer c.free(@ptrCast(unknown_ptr));
            _ = c.puts(@ptrCast(unknown_ptr));
            return .{ .should_quit = 0 };
        },
    }
}

fn classifyCommandToken(token: []const u8) CommandKind {
    if (std.mem.eql(u8, token, "quit")) return .quit;
    if (std.mem.eql(u8, token, "stop")) return .stop;
    if (std.mem.eql(u8, token, "ponderhit")) return .ponderhit;
    if (std.mem.eql(u8, token, "uci")) return .uci;
    if (std.mem.eql(u8, token, "setoption")) return .setoption;
    if (std.mem.eql(u8, token, "go")) return .go;
    if (std.mem.eql(u8, token, "position")) return .position;
    if (std.mem.eql(u8, token, "ucinewgame")) return .ucinewgame;
    if (std.mem.eql(u8, token, "isready")) return .isready;
    if (std.mem.eql(u8, token, "flip")) return .flip;
    if (std.mem.eql(u8, token, "bench")) return .bench;
    if (std.mem.eql(u8, token, "speedtest")) return .speedtest;
    if (std.mem.eql(u8, token, "d")) return .visualize;
    if (std.mem.eql(u8, token, "eval")) return .eval;
    if (std.mem.eql(u8, token, "compiler")) return .compiler;
    if (std.mem.eql(u8, token, "export_net")) return .export_net;
    if (isHelpToken(token)) return .help;
    return .unknown;
}

fn applySetoption(engine: *anyopaque, trimmed: []const u8) void {
    const parsed = option_port.parseSetOption(trimmed);
    defer freeMaybeCString(parsed.name);
    defer freeMaybeCString(parsed.value);

    const name_ptr = parsed.name orelse return;
    const name = std.mem.span(name_ptr);
    const value = if (parsed.value) |ptr| std.mem.span(ptr) else "";
    const has_value: u8 = if (parsed.value != null and value.len != 0) 1 else 0;

    engine_mod.applySetOptionEngine(
        engine,
        name.ptr,
        name.len,
        value.ptr,
        value.len,
        has_value,
    );
}

fn applyPosition(engine: *anyopaque, trimmed: []const u8) void {
    const parsed = parsePosition(trimmed);
    defer freeMaybeCString(parsed.fen);
    defer freeMaybeCString(parsed.moves);

    if (parsed.ok == 0) {
        return;
    }

    const fen_ptr = parsed.fen orelse return;
    const fen = std.mem.span(fen_ptr);
    var move_views = parseMoveViews(if (parsed.moves) |ptr| std.mem.span(ptr) else "") catch return;
    defer move_views.deinit(std.heap.c_allocator);

    const err = engine_mod.setPositionEngine(
        engine,
        fen.ptr,
        fen.len,
        if (move_views.items.len == 0) null else move_views.items.ptr,
        move_views.items.len,
    );
    if (err) |err_ptr| {
        defer c.free(@ptrCast(err_ptr));
        const critical = formatCriticalError("position", std.mem.span(err_ptr)) orelse return;
        defer c.free(@ptrCast(critical));
        _ = c.puts(@ptrCast(critical));
    }
}

fn applyGo(engine: *anyopaque, trimmed: []const u8) void {
    const limits = parseLimits(trimmed);
    defer freeMaybeCString(limits.searchmoves);

    const engine_ptr = engine;

    if (engine_mod.numaConfigInformationEngine(engine_ptr)) |numa_info_ptr| {
        defer c.free(@ptrCast(numa_info_ptr));
        emitInfoString(std.mem.span(numa_info_ptr));
    }

    if (engine_mod.threadAllocationInformationEngine(engine_ptr)) |thread_info_ptr| {
        defer c.free(@ptrCast(thread_info_ptr));
        emitInfoString(std.mem.span(thread_info_ptr));
    }

    if (limits.perft != 0) {
        _ = engine_mod.perftEngine(engine_ptr, limits.perft);
        return;
    }

    goParsed(engine_ptr, limits);
}

fn emitInfoString(text: []const u8) void {
    const rendered = formatInfoString(text) orelse return;
    defer c.free(@ptrCast(rendered));
    _ = c.puts(@ptrCast(rendered));
}

fn isHelpToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "--help") or
        std.mem.eql(u8, token, "help") or
        std.mem.eql(u8, token, "--license") or
        std.mem.eql(u8, token, "license");
}

pub fn loopRuntime(uci_ptr: *anyopaque) void {
    const allocator = std.heap.c_allocator;
    const argc = native_engine.NativeEngine.fromPtr(@constCast(uci_ptr)).cliArgc();

    if (argc != 1) {
        var command = std.ArrayList(u8).empty;
        defer command.deinit(allocator);

        var index: c_int = 1;
        while (index < argc) : (index += 1) {
            const arg_ptr = native_engine.NativeEngine.fromPtr(@constCast(uci_ptr)).cliArgAt(index) orelse continue;
            if (command.items.len != 0) {
                command.append(allocator, ' ') catch return;
            }
            command.appendSlice(allocator, std.mem.span(arg_ptr)) catch return;
        }

        _ = dispatchCommand(uci_ptr, command.items);
        return;
    }

    while (true) {
        const command = readCommandLineAlloc() catch {
            _ = dispatchCommand(uci_ptr, "quit");
            return;
        };
        if (command) |line| {
            defer std.heap.c_allocator.free(line);
            const result = dispatchCommand(uci_ptr, line);
            if (result.should_quit != 0) {
                return;
            }
        } else {
            _ = dispatchCommand(uci_ptr, "quit");
            return;
        }
    }
}

fn readCommandLineAlloc() !?[]u8 {
    var buffer: [4096]u8 = undefined;
    const read_ptr = c.fgets(@ptrCast(&buffer), @intCast(buffer.len), cStdin());
    if (read_ptr == null) {
        return null;
    }

    const line = std.mem.span(@as([*:0]u8, @ptrCast(&buffer)));
    var end = line.len;
    while (end > 0 and (line[end - 1] == '\n' or line[end - 1] == '\r')) {
        end -= 1;
    }

    const owned = try std.heap.c_allocator.dupe(u8, line[0..end]);
    return owned;
}

pub fn benchRuntime(uci_ptr: *anyopaque, args: []const u8) void {
    const engine_ptr = uci_ptr;

    const current_fen_ptr = engine_mod.fenEngine(engine_ptr) orelse return;
    defer c.free(@ptrCast(current_fen_ptr));

    const commands_ptr = benchmark_port.setupBench(std.mem.span(current_fen_ptr), args) orelse return;
    defer c.free(@ptrCast(commands_ptr));
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
            defer c.free(@ptrCast(fen_ptr));
            std.debug.print(
                "\nPosition: {d}/{d} ({s})\n",
                .{ current_position, total_positions, std.mem.span(fen_ptr) },
            );
            current_position += 1;

            if (std.mem.eql(u8, token, "go")) {
                const limits = parseLimits(command);
                defer freeMaybeCString(limits.searchmoves);

                if (limits.perft != 0) {
                    nodes += engine_mod.perftEngine(engine_ptr, limits.perft);
                } else {
                    uci_output.resetLastNodesSearched();
                    _ = dispatchCommand(uci_ptr, command);
                    engine_mod.waitForSearchFinishedEngine(engine_ptr);
                    nodes += uci_output.lastNodesSearched();
                }
            } else {
                _ = dispatchCommand(uci_ptr, command);
            }
            continue;
        }

        _ = dispatchCommand(uci_ptr, command);
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

pub fn benchmarkRuntime(uci_ptr: *anyopaque, args: []const u8) void {
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
    _ = dispatchCommand(uci_ptr, threads_command);

    const hash_command = std.fmt.allocPrint(std.heap.c_allocator, "setoption name Hash value {d}", .{setup.tt_size}) catch return;
    defer std.heap.c_allocator.free(hash_command);
    _ = dispatchCommand(uci_ptr, hash_command);

    _ = dispatchCommand(uci_ptr, "setoption name UCI_Chess960 value false");

    var warmup_count: usize = 1;
    var line_iter = std.mem.splitScalar(u8, commands, '\n');
    while (line_iter.next()) |command| {
        const token = firstToken(command);
        if (token.len == 0) {
            continue;
        }

        if (std.mem.eql(u8, token, "go")) {
            std.debug.print("\rWarmup position {d}/{d}", .{ warmup_count, warmup_positions });
            _ = dispatchCommand(uci_ptr, command);
            engine_mod.waitForSearchFinishedEngine(engine_ptr);
            warmup_count += 1;
        } else {
            _ = dispatchCommand(uci_ptr, command);
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
            _ = dispatchCommand(uci_ptr, command);
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
            _ = dispatchCommand(uci_ptr, command);
        }
    }

    if (total_time <= 0) {
        total_time = 1;
    }

    misc_port.dbgPrint();
    std.debug.print("\n", .{});

    const version_ptr = misc_port.engineVersionInfoText() orelse return;
    defer c.free(@ptrCast(version_ptr));
    const compiler_ptr = misc_port.compilerInfoText() orelse return;
    defer c.free(@ptrCast(compiler_ptr));
    const numa_ptr = engine_mod.numaConfigStringEngine(engine_ptr) orelse return;
    defer c.free(@ptrCast(numa_ptr));
    const binding_ptr = engine_mod.threadBindingInformationEngine(engine_ptr) orelse return;
    defer c.free(@ptrCast(binding_ptr));

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
    // Monotonic millis (the shared clock module) -- correct for elapsed timing and free
    // of the libc struct_timeval / gettimeofday C-ABI dependency.
    return clock.now();
}

fn parseMoveViews(moves_text: []const u8) !std.ArrayList(ByteView) {
    var views = std.ArrayList(ByteView).empty;
    errdefer views.deinit(std.heap.c_allocator);

    if (moves_text.len == 0)
        return views;

    var iter = std.mem.splitScalar(u8, moves_text, '\n');
    while (iter.next()) |move| {
        if (move.len == 0)
            continue;

        try views.append(std.heap.c_allocator, .{
            .ptr = move.ptr,
            .len = move.len,
        });
    }

    return views;
}

// C-string helpers live in the uci_strings base leaf (M17.3u); aliased so the
// bodies throughout this file stay unqualified.
const appendFormatted = uci_strings.appendFormatted;
const allocFormatted = uci_strings.allocFormatted;
const allocCString = uci_strings.allocCString;
const freeMaybeCString = uci_strings.freeMaybeCString;
const trimAsciiWhitespace = uci_strings.trimAsciiWhitespace;
const asciiLower = uci_strings.asciiLower;
const isSpaceByte = uci_strings.isSpaceByte;

// Live UCI output formatters live in the uci_format leaf (M17.3v); aliased for the
// dispatch code below.
const uci_format = @import("uci_format");
const formatInfoString = uci_format.formatInfoString;
const helpText = uci_format.helpText;
const formatUnknownCommand = uci_format.formatUnknownCommand;
const formatCriticalError = uci_format.formatCriticalError;

// UCI command parsers live in the uci_parse leaf (M17.3w); aliased for the
// dispatch/runtime code.
const uci_parse = @import("uci_parse");
pub const ParsedSetOption = uci_parse.ParsedSetOption;
pub const ParsedLimits = uci_parse.ParsedLimits;
pub const ParsedPosition = uci_parse.ParsedPosition;
pub const parseLimits = uci_parse.parseLimits;
pub const parsePosition = uci_parse.parsePosition;
