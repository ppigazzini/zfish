// UCI output formatters (M17.3v).
//
// The live UCI string builders split out of uci.zig: the `info string` renderer,
// the help text, and the unknown-command / critical-error lines. Pure over std +
// the uci_strings base leaf (no engine coupling), so it is a leaf; uci.zig
// re-exports these for its dispatch code.
//
// NOTE: uci.zig also carried ten *dead* formatters -- formatScore/toCp/wdl (thin
// delegators) and formatSquare/formatMove/toLower/formatInfoNoMoves/
// formatInfoFull/formatInfoIter/formatBestmove -- which duplicated the canonical
// versions in src/support/uci_wdl.zig and had no caller anywhere. Those were
// deleted rather than moved; the live callers use uci_wdl.* directly.

const std = @import("std");
const uci_strings = @import("uci_strings");

const allocCString = uci_strings.allocCString;
const allocFormatted = uci_strings.allocFormatted;
const trimAsciiWhitespace = uci_strings.trimAsciiWhitespace;

pub fn formatInfoString(input: []const u8) ?[*:0]u8 {
    return allocInfoString(input) catch null;
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
