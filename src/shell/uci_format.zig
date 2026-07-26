// Format the UCI output.
//
// Build the live UCI strings split out of uci.zig: the `info string` renderer,
// the help text, and the unknown-command / critical-error lines. Keep pure over std +
// the uci_strings base leaf (no engine coupling), so it is a leaf; uci.zig
// re-exports these for its dispatch code.
//
// NOTE: recall uci.zig also carried ten *dead* formatters -- formatScore/toCp/wdl (thin
// delegators) and formatSquare/formatMove/toLower/formatInfoNoMoves/
// formatInfoFull/formatInfoIter/formatBestmove -- which duplicated the canonical
// versions in src/support/uci_wdl.zig and had no caller anywhere. Those were
// deleted rather than moved; the live callers use uci_wdl.* directly.

const std = @import("std");
const uci_strings = @import("uci_strings");

const allocFormatted = uci_strings.allocFormatted;
const trimAsciiWhitespace = uci_strings.trimAsciiWhitespace;

// Every renderer here hands back an owned SLICE; the caller frees it with the same
// allocator it passed in.

pub fn formatInfoString(gpa: std.mem.Allocator, input: []const u8) ?[]u8 {
    return allocInfoString(gpa, input) catch null;
}

fn allocInfoString(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(gpa);
    var line_iter = std.mem.splitScalar(u8, input, '\n');
    while (line_iter.next()) |line| {
        if (trimAsciiWhitespace(line).len == 0) {
            continue;
        }
        if (builder.items.len != 0) {
            try builder.append(gpa, '\n');
        }
        try builder.appendSlice(gpa, "info string ");
        try builder.appendSlice(gpa, line);
    }

    return builder.toOwnedSlice(gpa);
}

pub fn helpText(gpa: std.mem.Allocator) ?[]u8 {
    return gpa.dupe(
        u8,
        "\nStockfish is a powerful chess engine for playing and analyzing.\n" ++ "It is released as free software licensed under the GNU GPLv3 License.\n" ++ "Stockfish is normally used with a graphical user interface (GUI) and implements\n" ++ "the Universal Chess Interface (UCI) protocol to communicate with a GUI, an API, etc.\n" ++ "For any further information, visit https://github.com/official-stockfish/Stockfish#readme\n" ++ "or read the corresponding README.md and Copying.txt files distributed along with this program.\n",
    ) catch null;
}

pub fn formatUnknownCommand(gpa: std.mem.Allocator, command: []const u8) ?[]u8 {
    return allocFormatted(gpa, "Unknown command: '{s}'. Type help for more information.", .{command}) catch null;
}

pub fn formatCriticalError(gpa: std.mem.Allocator, command: []const u8, message: []const u8) ?[]u8 {
    return allocFormatted(
        gpa,
        "info string CRITICAL ERROR: Command `{s}` failed. Reason: {s}\n",
        .{ command, message },
    ) catch null;
}

// --- tests--------------------------------------------------------------
test "uci_format: help / unknown / info-string / critical render" {
    // Run on the testing allocator, which the C-string form could not: it now leak-checks
    // every renderer here.
    const gpa = std.testing.allocator;

    const help = helpText(gpa).?;
    defer gpa.free(help);
    try std.testing.expect(std.mem.find(u8, help, "Universal Chess Interface") != null);

    const unk = formatUnknownCommand(gpa, "foo").?;
    defer gpa.free(unk);
    try std.testing.expectEqualStrings("Unknown command: 'foo'. Type help for more information.", unk);

    const info = formatInfoString(gpa, "hello\nworld").?;
    defer gpa.free(info);
    try std.testing.expectEqualStrings("info string hello\ninfo string world", info);

    const crit = formatCriticalError(gpa, "position fen x", "bad fen").?;
    defer gpa.free(crit);
    try std.testing.expectEqualStrings(
        "info string CRITICAL ERROR: Command `position fen x` failed. Reason: bad fen\n",
        crit,
    );
}
