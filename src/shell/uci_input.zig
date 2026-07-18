// Read UCI command lines from stdin, split out of uci.zig. Owns the persistent std.Io stdin
// reader and nothing else: no command dispatch, no engine state, so it sits below the command
// loop and can be reasoned about (and broken) on its own.

const std = @import("std");

// Hold a blocking std.Io handle for stdin, plus a persistent line reader (replacing libc
// fgets). `init_single_threaded` spawns no threads and installs no signal handlers, so
// input reading, like output, never touches the engine's thread pool. Keep the reader's
// 4096-byte buffer across calls (its state must not move, so it lives in a
// module var recovered by @fieldParentPtr). It bounds one REFILL, not one command line:
// `position startpos moves ...` passes 4096 bytes in a ~450-move game, and match runners
// resend the whole line every move, so readCommandLineAlloc stitches a longer line across
// refills rather than truncating it.
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

// Return the next command line (caller owns it, freed with the C allocator), or null at
// end-of-input.
pub fn readCommandLineAlloc() !?[]u8 {
    const reader = stdinInterface();
    const gpa = std.heap.c_allocator;

    // Take the next line via takeDelimiter, without the '\n' (and the final unterminated
    // line before EOF, then null) -- exactly fgets' line-at-a-time behaviour. Treat a read
    // failure as end-of-input, as a closed stdin was.
    //
    // Do NOT treat error.StreamTooLong that way: it only means the line outran one buffer
    // refill, and conflating it with EOF made the loop dispatch `quit` and exit 0 with no
    // diagnostic -- the engine vanishing mid-game on a legal 450-move `position ... moves`
    // line, which every match runner resends each move. Stitch the pieces instead; upstream's
    // getline is unbounded and must not be the more robust of the two.
    var carry: std.ArrayList(u8) = .empty;
    errdefer carry.deinit(gpa);
    var stitching = false;

    const line = while (true) {
        const raw = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                const chunk = reader.buffered();
                // A full buffer is what StreamTooLong means, so this cannot spin; bail
                // rather than loop forever if that ever stops holding.
                if (chunk.len == 0) {
                    carry.deinit(gpa);
                    return null;
                }
                try carry.appendSlice(gpa, chunk);
                reader.toss(chunk.len);
                stitching = true;
                continue;
            },
            error.ReadFailed => {
                carry.deinit(gpa);
                return null;
            },
        };
        const tail = raw orelse {
            // EOF: a stitched prefix is still a command; nothing pending is end-of-input.
            if (stitching) break "";
            carry.deinit(gpa);
            return null;
        };
        if (!stitching) {
            carry.deinit(gpa);
            return try dupeTrimmed(gpa, tail);
        }
        break tail;
    };

    try carry.appendSlice(gpa, line);
    return try dupeTrimmed(gpa, carry.items);
}

// Drop the trailing newline/carriage return a GUI may or may not send (Windows sends CRLF).
fn dupeTrimmed(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
    var end = line.len;
    while (end > 0 and (line[end - 1] == '\n' or line[end - 1] == '\r')) {
        end -= 1;
    }
    return gpa.dupe(u8, line[0..end]);
}

test "dupeTrimmed strips LF and CRLF, keeps interior whitespace" {
    const gpa = std.testing.allocator;
    const lf = try dupeTrimmed(gpa, "go depth 5\n");
    defer gpa.free(lf);
    try std.testing.expectEqualStrings("go depth 5", lf);

    const crlf = try dupeTrimmed(gpa, "go depth 5\r\n");
    defer gpa.free(crlf);
    try std.testing.expectEqualStrings("go depth 5", crlf);

    const bare = try dupeTrimmed(gpa, "isready");
    defer gpa.free(bare);
    try std.testing.expectEqualStrings("isready", bare);
}
