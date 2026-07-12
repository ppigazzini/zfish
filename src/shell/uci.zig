const std = @import("std");
const builtin = @import("builtin");

const benchmark_port = @import("benchmark");
const misc_port = @import("misc");
const engine_mod = @import("engine");
const option_port = @import("option");
const uci_wdl = @import("uci_wdl");
const uci_output = @import("uci_output");
const engine_object = @import("engine_object");
// The bench / benchmark command runners live in their own leaf (uci passes it a
// void wrapper over dispatchCommand, so the leaf has no cycle back into the loop).
const uci_bench = @import("uci_bench.zig");
const graph_layout = @import("graph_layout");
const clock = @import("clock");
const uci_strings = @import("uci_strings");

// Blocking std.Io handle for stdin, plus a persistent line reader (replacing libc
// fgets). `init_single_threaded` spawns no threads and installs no signal handlers, so
// input reading, like output, never touches the engine's native threadpool. The reader
// keeps a 4096-byte buffer across calls (its state must not move, so it lives in a
// module var recovered by @fieldParentPtr); it bounds one command line -- UCI commands
// are short, and a longer line reports error.StreamTooLong, handled as end-of-input.
var stdin_threaded = std.Io.Threaded.init_single_threaded;
var stdin_buffer: [4096]u8 = undefined;
var stdin_reader: std.Io.File.Reader = undefined;
var stdin_ready = false;

fn stdinInterface() *std.Io.Reader {
    if (!stdin_ready) {
        stdin_reader = std.Io.File.stdin().reader(stdin_threaded.io(), &stdin_buffer);
        stdin_ready = true;
    }
    return &stdin_reader.interface;
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
// move views directly rather than through a duplicate struct.
const ByteView = engine_mod.ByteView;

// Build the native LimitsType from the parsed UCI `go` args (including the
// searchmoves list, now Zig-owned graph_layout.SearchMoveText records) and
// hand it to the engine go driver. Relocated from main.zig: startTime is
// stamped here (earliest point), so the info-line elapsed/nps are correct; the
// searchmoves element buffer is freed after start_thinking has read it.
fn goParsed(engine_ptr: *engine_object.EngineObject, parsed: ParsedLimits) void {
    var limits: graph_layout.LimitsType = std.mem.zeroes(graph_layout.LimitsType);
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

    if (parsed.searchmoves) |sm_ptr| {
        const sm = std.mem.span(sm_ptr);
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, sm, '\n');
        while (it.next()) |tok| {
            if (tok.len != 0) count += 1;
        }
        if (count != 0) sm_build: {
            // Zig-owned SearchMoveText records: limits.searchmoves IS
            // the typed slice now -- no {begin,end,cap} header, no separate handle.
            // On OOM, degrade gracefully (search all moves) rather than aborting the game.
            const recs = std.heap.c_allocator.alloc(graph_layout.SearchMoveText, count) catch break :sm_build;
            @memset(recs, std.mem.zeroes(graph_layout.SearchMoveText));
            var i: usize = 0;
            it = std.mem.splitScalar(u8, sm, '\n');
            while (it.next()) |tok| {
                if (tok.len == 0) continue;
                const n: usize = @min(tok.len, recs[i].text.len); // UCI moves are <=5 chars
                recs[i].len = @intCast(n);
                @memcpy(recs[i].text[0..n], tok[0..n]);
                i += 1;
            }
            limits.searchmoves = recs;
        }
    }

    engine_mod.goEngine(engine_ptr, &limits);
    if (limits.searchmoves.len != 0) std.heap.c_allocator.free(limits.searchmoves);
}

pub fn dispatchCommand(engine: *engine_object.EngineObject, input: []const u8) DispatchResult {
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
            defer freeMaybeCString(info_ptr);
            const options_ptr = option_port.renderOptions() orelse return .{ .should_quit = 0 };
            defer freeMaybeCString(options_ptr);

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
            putsLine("readyok");
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
            defer freeMaybeCString(text_ptr);
            putsLine(text_ptr);
            return .{ .should_quit = 0 };
        },
        .eval => {
            const text_ptr = engine_mod.traceEvalEngine(engine) orelse return .{ .should_quit = 0 };
            defer freeMaybeCString(text_ptr);
            std.debug.print("\n{s}\n", .{std.mem.span(text_ptr)});
            return .{ .should_quit = 0 };
        },
        .compiler => {
            const compiler_ptr = misc_port.compilerInfoText() orelse return .{ .should_quit = 0 };
            defer freeMaybeCString(compiler_ptr);
            putsLine(compiler_ptr);
            return .{ .should_quit = 0 };
        },
        .export_net => {
            const filename = trimAsciiWhitespace(args);
            engine_mod.saveNetworkEngine(
                if (filename.len != 0) filename else null,
            );
            return .{ .should_quit = 0 };
        },
        .help => {
            const help_ptr = helpText() orelse return .{ .should_quit = 0 };
            defer freeMaybeCString(help_ptr);
            putsLine(help_ptr);
            return .{ .should_quit = 0 };
        },
        .unknown => {
            const unknown_ptr = formatUnknownCommand(trimmed) orelse return .{ .should_quit = 0 };
            defer freeMaybeCString(unknown_ptr);
            putsLine(unknown_ptr);
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

fn applySetoption(engine: *engine_object.EngineObject, trimmed: []const u8) void {
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

fn applyPosition(engine: *engine_object.EngineObject, trimmed: []const u8) void {
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
        defer freeMaybeCString(err_ptr);
        const critical = formatCriticalError("position", std.mem.span(err_ptr)) orelse return;
        defer freeMaybeCString(critical);
        putsLine(critical);
    }
}

fn applyGo(engine: *engine_object.EngineObject, trimmed: []const u8) void {
    const limits = parseLimits(trimmed);
    defer freeMaybeCString(limits.searchmoves);

    const engine_ptr = engine;

    if (engine_mod.numaConfigInformationEngine(engine_ptr)) |numa_info_ptr| {
        defer freeMaybeCString(numa_info_ptr);
        emitInfoString(std.mem.span(numa_info_ptr));
    }

    if (engine_mod.threadAllocationInformationEngine(engine_ptr)) |thread_info_ptr| {
        defer freeMaybeCString(thread_info_ptr);
        emitInfoString(std.mem.span(thread_info_ptr));
    }

    if (limits.perft != 0) {
        _ = engine_mod.perftEngine(engine_ptr, limits.perft);
        return;
    }

    goParsed(engine_ptr, limits);
}

// Print a NUL-terminated line to stdout through the shared output funnel (replacing
// libc puts): printLine adds the newline and the tear-proof lock, and tees to the log
// like Stockfish's full-cout tee. The span drops the sentinel; the bytes are unchanged.
fn putsLine(ptr: [*:0]const u8) void {
    const s = std.mem.span(ptr);
    uci_output.printLine(s.ptr, s.len);
}

fn emitInfoString(text: []const u8) void {
    const rendered = formatInfoString(text) orelse return;
    defer freeMaybeCString(rendered);
    putsLine(rendered);
}

fn isHelpToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "--help") or
        std.mem.eql(u8, token, "help") or
        std.mem.eql(u8, token, "--license") or
        std.mem.eql(u8, token, "license");
}

pub fn loopRuntime(uci_ptr: *anyopaque) void {
    // Single erasure boundary: main hands the engine as *anyopaque; the whole UCI
    // dispatch below runs on the typed *EngineObject handle.
    const e: *engine_object.EngineObject = engine_object.EngineObject.fromPtr(uci_ptr);
    const allocator = std.heap.c_allocator;
    const argc = e.cliArgc();

    if (argc != 1) {
        var command = std.ArrayList(u8).empty;
        defer command.deinit(allocator);

        var index: c_int = 1;
        while (index < argc) : (index += 1) {
            const arg_ptr = e.cliArgAt(index) orelse continue;
            if (command.items.len != 0) {
                command.append(allocator, ' ') catch return;
            }
            command.appendSlice(allocator, std.mem.span(arg_ptr)) catch return;
        }

        _ = dispatchCommand(e, command.items);
        return;
    }

    while (true) {
        const command = readCommandLineAlloc() catch {
            _ = dispatchCommand(e, "quit");
            return;
        };
        if (command) |line| {
            defer std.heap.c_allocator.free(line);
            const result = dispatchCommand(e, line);
            if (result.should_quit != 0) {
                return;
            }
        } else {
            _ = dispatchCommand(e, "quit");
            return;
        }
    }
}

fn readCommandLineAlloc() !?[]u8 {
    const reader = stdinInterface();
    // takeDelimiter returns the next line without the '\n' (and the final unterminated
    // line before EOF, then null) -- exactly fgets' line-at-a-time behaviour. An
    // over-long line or a read failure is treated as end-of-input, as a closed stdin was.
    const raw = reader.takeDelimiter('\n') catch return null;
    const line = raw orelse return null;

    var end = line.len;
    while (end > 0 and (line[end - 1] == '\n' or line[end - 1] == '\r')) {
        end -= 1;
    }

    return try std.heap.c_allocator.dupe(u8, line[0..end]);
}

// The bench/benchmark runners live in uci_bench.zig; these thin wrappers keep the
// public entry points and inject dispatchCommand (as a void wrapper) so the leaf carries
// no import cycle back into the command loop.
pub fn benchRuntime(uci_ptr: *engine_object.EngineObject, args: []const u8) void {
    uci_bench.benchRuntime(uci_ptr, args, dispatchVoid);
}

pub fn benchmarkRuntime(uci_ptr: *engine_object.EngineObject, args: []const u8) void {
    uci_bench.benchmarkRuntime(uci_ptr, args, dispatchVoid);
}

fn dispatchVoid(engine: *engine_object.EngineObject, input: []const u8) void {
    _ = dispatchCommand(engine, input);
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

// C-string helpers live in the uci_strings base leaf; aliased so the
// bodies throughout this file stay unqualified.
const appendFormatted = uci_strings.appendFormatted;
const allocFormatted = uci_strings.allocFormatted;
const allocCString = uci_strings.allocCString;
const freeMaybeCString = uci_strings.freeMaybeCString;
const trimAsciiWhitespace = uci_strings.trimAsciiWhitespace;
const asciiLower = uci_strings.asciiLower;
const isSpaceByte = uci_strings.isSpaceByte;

// Live UCI output formatters live in the uci_format leaf; aliased for the
// dispatch code below.
const uci_format = @import("uci_format");
const formatInfoString = uci_format.formatInfoString;
const helpText = uci_format.helpText;
const formatUnknownCommand = uci_format.formatUnknownCommand;
const formatCriticalError = uci_format.formatCriticalError;

// UCI command parsers live in the uci_parse leaf; aliased for the
// dispatch/runtime code.
const uci_parse = @import("uci_parse");
pub const ParsedSetOption = uci_parse.ParsedSetOption;
pub const ParsedLimits = uci_parse.ParsedLimits;
pub const ParsedPosition = uci_parse.ParsedPosition;
pub const parseLimits = uci_parse.parseLimits;
pub const parsePosition = uci_parse.parsePosition;
