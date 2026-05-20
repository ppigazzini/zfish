const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("sys/time.h");
});

const benchmark_port = @import("benchmark");
const misc_port = @import("misc");

pub const DispatchResult = extern struct {
    should_quit: u8,
};

pub const ParsedSetOption = extern struct {
    name: ?[*:0]u8,
    value: ?[*:0]u8,
};

pub const ParsedLimits = extern struct {
    wtime: i64,
    btime: i64,
    winc: i64,
    binc: i64,
    movestogo: c_int,
    depth: c_int,
    mate: c_int,
    perft: c_int,
    infinite: c_int,
    movetime: i64,
    nodes: u64,
    ponder_mode: u8,
    searchmoves: ?[*:0]u8,
};

pub const ParsedPosition = extern struct {
    ok: u8,
    fen: ?[*:0]u8,
    moves: ?[*:0]u8,
};

extern fn zfish_uci_command_stop(engine: *anyopaque) void;
extern fn zfish_uci_command_ponderhit(engine: *anyopaque) void;
extern fn zfish_uci_command_uci(engine: *anyopaque) void;
extern fn zfish_uci_command_setoption_text(engine: *anyopaque, args_ptr: [*]const u8, args_len: usize) void;
extern fn zfish_uci_command_go_text(engine: *anyopaque, args_ptr: [*]const u8, args_len: usize) void;
extern fn zfish_uci_command_position_text(
    engine: *anyopaque,
    full_command_ptr: [*]const u8,
    full_command_len: usize,
) void;
extern fn zfish_uci_command_search_clear(engine: *anyopaque) void;
extern fn zfish_uci_command_isready() void;
extern fn zfish_uci_command_flip(engine: *anyopaque) void;
extern fn zfish_uci_command_bench(engine: *anyopaque, args_ptr: [*]const u8, args_len: usize) void;
extern fn zfish_uci_command_benchmark(engine: *anyopaque, args_ptr: [*]const u8, args_len: usize) void;
extern fn zfish_uci_command_visualize(engine: *anyopaque) void;
extern fn zfish_uci_command_eval(engine: *anyopaque) void;
extern fn zfish_uci_command_compiler() void;
extern fn zfish_uci_command_export_net(
    engine: *anyopaque,
    has_filename: u8,
    filename_ptr: [*]const u8,
    filename_len: usize,
) void;
extern fn zfish_uci_command_help() void;
extern fn zfish_uci_command_unknown(command_ptr: [*]const u8, command_len: usize) void;
extern fn zfish_option_parse_setoption(input_ptr: [*]const u8, input_len: usize) ParsedSetOption;
extern fn zfish_uci_cli_argc(uci_ptr: *const anyopaque) c_int;
extern fn zfish_uci_cli_arg_at(uci_ptr: *const anyopaque, index: c_int) ?[*:0]const u8;
extern fn zfish_uci_read_command_line() ?[*:0]u8;
extern fn zfish_uci_engine_perft_depth(uci_ptr: *anyopaque, depth: c_int) u64;
extern fn zfish_uci_engine_wait_finished(uci_ptr: *anyopaque) void;
extern fn zfish_uci_engine_nodes_searched(uci_ptr: *const anyopaque) u64;
extern fn zfish_uci_engine_reset_nodes_searched() void;
extern fn zfish_uci_engine_hashfull(uci_ptr: *const anyopaque, max_age: c_int) c_int;
extern fn zfish_uci_engine_fen_text(uci_ptr: *const anyopaque) ?[*:0]u8;
extern fn zfish_uci_engine_numa_config_string(uci_ptr: *const anyopaque) ?[*:0]u8;
extern fn zfish_uci_engine_thread_binding_info_text(uci_ptr: *const anyopaque) ?[*:0]u8;
extern fn zfish_uci_set_quiet_listeners(uci_ptr: *anyopaque) void;
extern fn zfish_uci_set_default_listeners(uci_ptr: *anyopaque) void;

pub fn parseLimits(input: []const u8) ParsedLimits {
    return parseLimitsAlloc(input) catch .{
        .wtime = 0,
        .btime = 0,
        .winc = 0,
        .binc = 0,
        .movestogo = 0,
        .depth = 0,
        .mate = 0,
        .perft = 0,
        .infinite = 0,
        .movetime = 0,
        .nodes = 0,
        .ponder_mode = 0,
        .searchmoves = null,
    };
}

pub fn parsePosition(input: []const u8) ParsedPosition {
    return parsePositionAlloc(input) catch .{ .ok = 0, .fen = null, .moves = null };
}

pub fn formatInfoString(input: []const u8) ?[*:0]u8 {
    return allocInfoString(input) catch null;
}

pub fn formatScore(kind: u8, value: c_int, extra: c_int) ?[*:0]u8 {
    return allocScore(kind, value, extra) catch null;
}

pub fn toCp(value: c_int, material: c_int) c_int {
    const params = winRateParams(material);
    return @intFromFloat(@round(100.0 * @as(f64, @floatFromInt(value)) / params.a));
}

pub fn wdl(value: c_int, material: c_int) ?[*:0]u8 {
    return allocWdl(value, material) catch null;
}

pub fn formatSquare(file: u8, rank: u8) ?[*:0]u8 {
    const bytes = [_]u8{ @as(u8, 'a') + file, @as(u8, '1') + rank };
    return allocCString(bytes[0..]) catch null;
}

pub fn formatMove(from_file: u8, from_rank: u8, to_file: u8, to_rank: u8, promotion: u8) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const extra: usize = if (promotion == 0) 0 else 1;
    const result = allocator.allocSentinel(u8, 4 + extra, 0) catch return null;
    result[0] = @as(u8, 'a') + from_file;
    result[1] = @as(u8, '1') + from_rank;
    result[2] = @as(u8, 'a') + to_file;
    result[3] = @as(u8, '1') + to_rank;
    if (promotion != 0) {
        result[4] = promotion;
    }
    return result.ptr;
}

pub fn toLower(input: []const u8) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const result = allocator.allocSentinel(u8, input.len, 0) catch return null;
    for (input, 0..) |byte, index| {
        result[index] = asciiLower(byte);
    }
    return result.ptr;
}

pub fn formatInfoNoMoves(depth: c_int, score_text: []const u8) ?[*:0]u8 {
    return allocFormatted("info depth {d} score {s}", .{ depth, score_text }) catch null;
}

pub fn formatInfoFull(
    depth: c_int,
    sel_depth: c_int,
    multi_pv: usize,
    score_text: []const u8,
    bound_text: []const u8,
    wdl_text: []const u8,
    show_wdl: u8,
    nodes: usize,
    nps: usize,
    hashfull: c_int,
    tb_hits: usize,
    time_ms: usize,
    pv: []const u8,
) ?[*:0]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(std.heap.c_allocator);

    builder.appendSlice(std.heap.c_allocator, "info depth ") catch return null;
    appendFormatted(&builder, "{d}", .{depth}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " seldepth ") catch return null;
    appendFormatted(&builder, "{d}", .{sel_depth}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " multipv ") catch return null;
    appendFormatted(&builder, "{d}", .{multi_pv}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " score ") catch return null;
    builder.appendSlice(std.heap.c_allocator, score_text) catch return null;
    if (bound_text.len != 0) {
        builder.append(std.heap.c_allocator, ' ') catch return null;
        builder.appendSlice(std.heap.c_allocator, bound_text) catch return null;
    }
    if (show_wdl != 0) {
        builder.appendSlice(std.heap.c_allocator, " wdl ") catch return null;
        builder.appendSlice(std.heap.c_allocator, wdl_text) catch return null;
    }
    builder.appendSlice(std.heap.c_allocator, " nodes ") catch return null;
    appendFormatted(&builder, "{d}", .{nodes}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " nps ") catch return null;
    appendFormatted(&builder, "{d}", .{nps}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " hashfull ") catch return null;
    appendFormatted(&builder, "{d}", .{hashfull}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " tbhits ") catch return null;
    appendFormatted(&builder, "{d}", .{tb_hits}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " time ") catch return null;
    appendFormatted(&builder, "{d}", .{time_ms}) catch return null;
    builder.appendSlice(std.heap.c_allocator, " pv ") catch return null;
    builder.appendSlice(std.heap.c_allocator, pv) catch return null;

    return allocCString(builder.items) catch null;
}

pub fn formatInfoIter(depth: c_int, currmove: []const u8, currmove_number: c_int) ?[*:0]u8 {
    return allocFormatted(
        "info depth {d} currmove {s} currmovenumber {d}",
        .{ depth, currmove, currmove_number },
    ) catch null;
}

pub fn formatBestmove(bestmove: []const u8, ponder: []const u8) ?[*:0]u8 {
    if (ponder.len == 0) {
        return allocFormatted("bestmove {s}", .{bestmove}) catch null;
    }

    return allocFormatted("bestmove {s} ponder {s}", .{ bestmove, ponder }) catch null;
}

pub fn helpText() ?[*:0]u8 {
    return allocCString(
        "\nStockfish is a powerful chess engine for playing and analyzing.\n" ++ "It is released as free software licensed under the GNU GPLv3 License.\n" ++ "Stockfish is normally used with a graphical user interface (GUI) and implements\n" ++ "the Universal Chess Interface (UCI) protocol to communicate with a GUI, an API, etc.\n" ++ "For any further information, visit https://github.com/official-stockfish/Stockfish#readme\n" ++ "or read the corresponding README.md and Copying.txt files distributed along with this program.\n",
    ) catch null;
}

pub fn formatUnknownCommand(command: []const u8) ?[*:0]u8 {
    return allocFormatted("Unknown command: '{s}'. Type help for more information.", .{command}) catch null;
}

pub fn formatCriticalError(command: []const u8, message: []const u8) ?[*:0]u8 {
    return allocFormatted(
        "info string CRITICAL ERROR: Command `{s}` failed. Reason: {s}\n",
        .{ command, message },
    ) catch null;
}

pub fn dispatchCommand(engine: *anyopaque, input: []const u8) DispatchResult {
    const trimmed = trimAsciiWhitespace(input);
    if (trimmed.len == 0 or trimmed[0] == '#')
        return .{ .should_quit = 0 };

    var token_iter = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    const token = token_iter.next() orelse return .{ .should_quit = 0 };
    const args = trimAsciiWhitespace(trimmed[token.len..]);

    if (std.mem.eql(u8, token, "quit")) {
        zfish_uci_command_stop(engine);
        return .{ .should_quit = 1 };
    }

    if (std.mem.eql(u8, token, "stop")) {
        zfish_uci_command_stop(engine);
        return .{ .should_quit = 0 };
    }

    if (std.mem.eql(u8, token, "ponderhit")) {
        zfish_uci_command_ponderhit(engine);
        return .{ .should_quit = 0 };
    }

    if (std.mem.eql(u8, token, "uci")) {
        zfish_uci_command_uci(engine);
        return .{ .should_quit = 0 };
    }

    if (std.mem.eql(u8, token, "setoption")) {
        zfish_uci_command_setoption_text(engine, args.ptr, args.len);
        return .{ .should_quit = 0 };
    }

    if (std.mem.eql(u8, token, "go")) {
        zfish_uci_command_go_text(engine, args.ptr, args.len);
        return .{ .should_quit = 0 };
    }

    if (std.mem.eql(u8, token, "position")) {
        zfish_uci_command_position_text(engine, trimmed.ptr, trimmed.len);
        return .{ .should_quit = 0 };
    }

    if (std.mem.eql(u8, token, "ucinewgame")) {
        zfish_uci_command_search_clear(engine);
        return .{ .should_quit = 0 };
    }

    if (std.mem.eql(u8, token, "isready")) {
        zfish_uci_command_isready();
        return .{ .should_quit = 0 };
    }

    if (std.mem.eql(u8, token, "flip")) {
        zfish_uci_command_flip(engine);
        return .{ .should_quit = 0 };
    }

    if (std.mem.eql(u8, token, "bench")) {
        zfish_uci_command_bench(engine, args.ptr, args.len);
        return .{ .should_quit = 0 };
    }

    if (std.mem.eql(u8, token, "speedtest")) {
        zfish_uci_command_benchmark(engine, args.ptr, args.len);
        return .{ .should_quit = 0 };
    }

    if (std.mem.eql(u8, token, "d")) {
        zfish_uci_command_visualize(engine);
        return .{ .should_quit = 0 };
    }

    if (std.mem.eql(u8, token, "eval")) {
        zfish_uci_command_eval(engine);
        return .{ .should_quit = 0 };
    }

    if (std.mem.eql(u8, token, "compiler")) {
        zfish_uci_command_compiler();
        return .{ .should_quit = 0 };
    }

    if (std.mem.eql(u8, token, "export_net")) {
        const filename = trimAsciiWhitespace(args);
        zfish_uci_command_export_net(engine, if (filename.len == 0) 0 else 1, filename.ptr, filename.len);
        return .{ .should_quit = 0 };
    }

    if (std.mem.eql(u8, token, "--help") or std.mem.eql(u8, token, "help") or std.mem.eql(u8, token, "--license") or std.mem.eql(u8, token, "license")) {
        zfish_uci_command_help();
        return .{ .should_quit = 0 };
    }

    zfish_uci_command_unknown(trimmed.ptr, trimmed.len);
    return .{ .should_quit = 0 };
}

pub fn loopRuntime(uci_ptr: *anyopaque) void {
    const allocator = std.heap.c_allocator;
    const argc = zfish_uci_cli_argc(uci_ptr);

    if (argc != 1) {
        var command = std.ArrayList(u8).empty;
        defer command.deinit(allocator);

        var index: c_int = 1;
        while (index < argc) : (index += 1) {
            const arg_ptr = zfish_uci_cli_arg_at(uci_ptr, index) orelse continue;
            if (command.items.len != 0) {
                command.append(allocator, ' ') catch return;
            }
            command.appendSlice(allocator, std.mem.span(arg_ptr)) catch return;
        }

        _ = dispatchCommand(uci_ptr, command.items);
        return;
    }

    while (true) {
        const command_ptr = zfish_uci_read_command_line();
        if (command_ptr) |ptr| {
            defer c.free(@ptrCast(ptr));
            const result = dispatchCommand(uci_ptr, std.mem.span(ptr));
            if (result.should_quit != 0) {
                return;
            }
        } else {
            _ = dispatchCommand(uci_ptr, "quit");
            return;
        }
    }
}

pub fn benchRuntime(uci_ptr: *anyopaque, args: []const u8) void {
    const current_fen_ptr = zfish_uci_engine_fen_text(uci_ptr) orelse return;
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
            const fen_ptr = zfish_uci_engine_fen_text(uci_ptr) orelse return;
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
                    nodes += zfish_uci_engine_perft_depth(uci_ptr, limits.perft);
                } else {
                    zfish_uci_engine_reset_nodes_searched();
                    _ = dispatchCommand(uci_ptr, command);
                    zfish_uci_engine_wait_finished(uci_ptr);
                    nodes += zfish_uci_engine_nodes_searched(uci_ptr);
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
    zfish_uci_set_quiet_listeners(uci_ptr);
    defer zfish_uci_set_default_listeners(uci_ptr);

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
            zfish_uci_engine_wait_finished(uci_ptr);
            warmup_count += 1;
        } else {
            _ = dispatchCommand(uci_ptr, command);
        }

        if (warmup_count > warmup_positions) {
            break;
        }
    }

    std.debug.print("\n", .{});

    zfish_uci_command_search_clear(uci_ptr);

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
            zfish_uci_engine_wait_finished(uci_ptr);

            total_time += nowMillis() - started;
            total_nodes += zfish_uci_engine_nodes_searched(uci_ptr);

            hashfull_reads += 1;
            const hashfull_single = zfish_uci_engine_hashfull(uci_ptr, 0);
            const hashfull_game = zfish_uci_engine_hashfull(uci_ptr, 999);
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
    const numa_ptr = zfish_uci_engine_numa_config_string(uci_ptr) orelse return;
    defer c.free(@ptrCast(numa_ptr));
    const binding_ptr = zfish_uci_engine_thread_binding_info_text(uci_ptr) orelse return;
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
    var tv: c.struct_timeval = undefined;
    _ = c.gettimeofday(&tv, null);
    return @as(i64, @intCast(tv.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(tv.tv_usec)), 1000);
}

fn parseLimitsAlloc(input: []const u8) !ParsedLimits {
    var result = ParsedLimits{
        .wtime = 0,
        .btime = 0,
        .winc = 0,
        .binc = 0,
        .movestogo = 0,
        .depth = 0,
        .mate = 0,
        .perft = 0,
        .infinite = 0,
        .movetime = 0,
        .nodes = 0,
        .ponder_mode = 0,
        .searchmoves = null,
    };
    var searchmoves = std.ArrayList(u8).empty;
    defer searchmoves.deinit(std.heap.c_allocator);
    var iter = std.mem.tokenizeAny(u8, input, " \t\r\n");

    while (iter.next()) |token| {
        if (std.mem.eql(u8, token, "searchmoves")) {
            while (iter.next()) |move| {
                if (searchmoves.items.len != 0) {
                    try searchmoves.append(std.heap.c_allocator, '\n');
                }
                const lowered = try lowerAlloc(move);
                defer std.heap.c_allocator.free(lowered);
                try searchmoves.appendSlice(std.heap.c_allocator, lowered);
            }
            break;
        } else if (std.mem.eql(u8, token, "wtime")) {
            result.wtime = parseI64(iter.next()) orelse result.wtime;
        } else if (std.mem.eql(u8, token, "btime")) {
            result.btime = parseI64(iter.next()) orelse result.btime;
        } else if (std.mem.eql(u8, token, "winc")) {
            result.winc = parseI64(iter.next()) orelse result.winc;
        } else if (std.mem.eql(u8, token, "binc")) {
            result.binc = parseI64(iter.next()) orelse result.binc;
        } else if (std.mem.eql(u8, token, "movestogo")) {
            result.movestogo = parseInt(c_int, iter.next()) orelse result.movestogo;
        } else if (std.mem.eql(u8, token, "depth")) {
            result.depth = parseInt(c_int, iter.next()) orelse result.depth;
        } else if (std.mem.eql(u8, token, "nodes")) {
            result.nodes = parseInt(u64, iter.next()) orelse result.nodes;
        } else if (std.mem.eql(u8, token, "movetime")) {
            result.movetime = parseI64(iter.next()) orelse result.movetime;
        } else if (std.mem.eql(u8, token, "mate")) {
            result.mate = parseInt(c_int, iter.next()) orelse result.mate;
        } else if (std.mem.eql(u8, token, "perft")) {
            result.perft = parseInt(c_int, iter.next()) orelse result.perft;
        } else if (std.mem.eql(u8, token, "infinite")) {
            result.infinite = 1;
        } else if (std.mem.eql(u8, token, "ponder")) {
            result.ponder_mode = 1;
        }
    }

    result.searchmoves = try allocCString(searchmoves.items);
    return result;
}

fn parsePositionAlloc(input: []const u8) !ParsedPosition {
    var iter = std.mem.tokenizeAny(u8, input, " \t\r\n");
    const first = iter.next() orelse return .{ .ok = 0, .fen = null, .moves = null };
    var token = first;
    if (std.mem.eql(u8, token, "position")) {
        token = iter.next() orelse return .{ .ok = 0, .fen = null, .moves = null };
    }

    var fen = std.ArrayList(u8).empty;
    defer fen.deinit(std.heap.c_allocator);
    var moves = std.ArrayList(u8).empty;
    defer moves.deinit(std.heap.c_allocator);

    if (std.mem.eql(u8, token, "startpos")) {
        try fen.appendSlice(std.heap.c_allocator, start_fen);
        _ = iter.next();
    } else if (std.mem.eql(u8, token, "fen")) {
        while (iter.next()) |fen_token| {
            if (std.mem.eql(u8, fen_token, "moves")) {
                break;
            }
            if (fen.items.len != 0) {
                try fen.append(std.heap.c_allocator, ' ');
            }
            try fen.appendSlice(std.heap.c_allocator, fen_token);
        }
    } else {
        return .{ .ok = 0, .fen = null, .moves = null };
    }

    while (iter.next()) |move| {
        if (moves.items.len != 0) {
            try moves.append(std.heap.c_allocator, '\n');
        }
        try moves.appendSlice(std.heap.c_allocator, move);
    }

    return .{
        .ok = 1,
        .fen = try allocCString(fen.items),
        .moves = try allocCString(moves.items),
    };
}

fn allocInfoString(input: []const u8) !?[*:0]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(std.heap.c_allocator);
    var line_iter = std.mem.splitScalar(u8, input, '\n');
    while (line_iter.next()) |line| {
        if (trimAsciiWhitespace(line).len == 0) {
            continue;
        }
        if (builder.items.len != 0) {
            try builder.append(std.heap.c_allocator, '\n');
        }
        try builder.appendSlice(std.heap.c_allocator, "info string ");
        try builder.appendSlice(std.heap.c_allocator, line);
    }

    return try allocCString(builder.items);
}

fn allocScore(kind: u8, value: c_int, extra: c_int) !?[*:0]u8 {
    return switch (kind) {
        0 => blk: {
            const mate = @divTrunc(if (value > 0) value + 1 else value, 2);
            break :blk try allocFormatted("mate {d}", .{mate});
        },
        1 => blk: {
            const tb_cp: c_int = 20000;
            const score = (if (extra != 0) tb_cp else -tb_cp) - value;
            break :blk try allocFormatted("cp {d}", .{score});
        },
        else => try allocFormatted("cp {d}", .{value}),
    };
}

fn allocWdl(value: c_int, material: c_int) !?[*:0]u8 {
    const win = winRateModel(value, material);
    const loss = winRateModel(-value, material);
    const draw = 1000 - win - loss;
    return try allocFormatted("{d} {d} {d}", .{ win, draw, loss });
}

fn winRateModel(value: c_int, material: c_int) c_int {
    const params = winRateParams(material);
    return @intFromFloat(0.5 + 1000.0 / (1.0 + std.math.exp((params.a - @as(f64, @floatFromInt(value))) / params.b)));
}

const WinRateParams = struct {
    a: f64,
    b: f64,
};

fn winRateParams(material: c_int) WinRateParams {
    const clamped = std.math.clamp(material, 17, 78);
    const m = @as(f64, @floatFromInt(clamped)) / 58.0;
    const as = [_]f64{ -72.32565836, 185.93832038, -144.58862193, 416.44950446 };
    const bs = [_]f64{ 83.86794042, -136.06112997, 69.98820887, 47.62901433 };
    const a = (((as[0] * m + as[1]) * m + as[2]) * m) + as[3];
    const b = (((bs[0] * m + bs[1]) * m + bs[2]) * m) + bs[3];
    return .{ .a = a, .b = b };
}

fn lowerAlloc(input: []const u8) ![]u8 {
    const allocator = std.heap.c_allocator;
    const result = try allocator.alloc(u8, input.len);
    for (input, 0..) |byte, index| {
        result[index] = asciiLower(byte);
    }
    return result;
}

fn appendFormatted(buffer: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const allocator = std.heap.c_allocator;
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try buffer.appendSlice(allocator, formatted);
}

fn allocFormatted(comptime fmt: []const u8, args: anytype) !?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    return try allocCString(formatted);
}

fn allocCString(value: []const u8) !?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result[0..value.len], value);
    return result.ptr;
}

fn freeMaybeCString(value: ?[*:0]u8) void {
    if (value) |ptr|
        std.heap.c_allocator.free(std.mem.span(ptr));
}

fn trimAsciiWhitespace(input: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = input.len;
    while (start < end and isSpaceByte(input[start])) : (start += 1) {}
    while (end > start and isSpaceByte(input[end - 1])) {
        end -= 1;
    }
    return input[start..end];
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn isSpaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}

fn parseI64(token: ?[]const u8) ?i64 {
    return parseInt(i64, token);
}

fn parseInt(comptime T: type, token: ?[]const u8) ?T {
    const text = token orelse return null;
    return std.fmt.parseInt(T, text, 10) catch null;
}

const start_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
