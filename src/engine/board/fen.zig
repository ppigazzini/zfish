// FEN encoding: format / flip / endgame-code synthesis (M17.3e leaf-extraction).
//
// The FEN *output* side of the board, carved out of the 4200-line position.zig
// god-file. Every entry point takes raw primitives (a 64-byte board image, a
// side/castling/ep byte, counters) rather than a *Position, so this is a pure
// std-only leaf with no dependency on the position graph -- it forms no module
// cycle and position.zig re-exports the three public entry points to keep the
// port surface (position_port.flipFen / formatFen / buildEndgameFen) intact.
//
// A few one-line primitives (allocCString, fileOf, rankOf) and the piece/castling
// constants also exist in position.zig, where other clusters still use them; they
// are duplicated here (kept intentionally tiny) rather than shared through a
// back-import, which would reintroduce a cycle. FEN *parsing* stays in position.zig
// for now (it writes directly into a Position).

const std = @import("std");

// Piece code -> FEN letter (index by the native piece encoding: 1..6 white,
// 9..14 black). Mirrors position.zig's table; FEN letters are intrinsic here.
const piece_to_char = " PNBRQK  pnbrqk";

const white_oo: u8 = 1;
const white_ooo: u8 = 2;
const black_oo: u8 = 4;
const black_ooo: u8 = 8;
const black: u8 = 1;
const sq_none: u8 = 64;

pub fn flipFen(fen_ptr: [*]const u8, fen_len: usize) ?[*:0]u8 {
    return flipFenAlloc(fen_ptr[0..fen_len]) catch null;
}

fn flipFenAlloc(fen: []const u8) ![*:0]u8 {
    const alloc = std.heap.c_allocator;
    var it = std.mem.tokenizeScalar(u8, fen, ' ');
    const placement = it.next() orelse return error.BadFen;
    const active = it.next() orelse return error.BadFen;
    const castling = it.next() orelse return error.BadFen;
    const ep = it.next() orelse return error.BadFen;
    const rest = it.rest(); // half/full move counters

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    // Piece placement with the rank order reversed (vertical mirror).
    var ranks: [8][]const u8 = undefined;
    var nr: usize = 0;
    var rank_it = std.mem.splitScalar(u8, placement, '/');
    while (rank_it.next()) |r| : (nr += 1) ranks[nr] = r;
    var ri: usize = nr;
    while (ri > 0) {
        ri -= 1;
        try out.appendSlice(alloc, ranks[ri]);
        if (ri > 0) try out.append(alloc, '/');
    }
    try out.append(alloc, ' ');
    try out.append(alloc, if (active[0] == 'w') 'B' else 'W');
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, castling);

    // Swap the case of everything so far: flips piece colors, the active color,
    // and castling-rights case in one pass (matches upstream flip()).
    for (out.items) |*ch| {
        ch.* = if (std.ascii.isLower(ch.*)) std.ascii.toUpper(ch.*) else std.ascii.toLower(ch.*);
    }

    try out.append(alloc, ' ');
    if (std.mem.eql(u8, ep, "-")) {
        try out.append(alloc, '-');
    } else {
        try out.append(alloc, ep[0]);
        try out.append(alloc, if (ep[1] == '3') @as(u8, '6') else @as(u8, '3'));
    }
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, rest);

    return try allocCString(out.items);
}

pub fn buildEndgameFen(code_ptr: [*]const u8, code_len: usize, color: u8) ?[*:0]u8 {
    return buildEndgameFenAlloc(code_ptr[0..code_len], color) catch null;
}

pub fn formatFen(
    board_ptr: [*]const u8,
    side_to_move: u8,
    chess960: u8,
    castling_rights: u8,
    white_oo_rook_square: u8,
    white_ooo_rook_square: u8,
    black_oo_rook_square: u8,
    black_ooo_rook_square: u8,
    ep_square: u8,
    rule50: c_int,
    game_ply: c_int,
) ?[*:0]u8 {
    return formatFenAlloc(
        board_ptr[0..64],
        side_to_move,
        chess960 != 0,
        castling_rights,
        white_oo_rook_square,
        white_ooo_rook_square,
        black_oo_rook_square,
        black_ooo_rook_square,
        ep_square,
        rule50,
        game_ply,
    ) catch null;
}

fn buildEndgameFenAlloc(code: []const u8, color: u8) ![*:0]u8 {
    std.debug.assert(code.len > 0 and code[0] == 'K');

    const second_king = std.mem.indexOfScalarPos(u8, code, 1, 'K') orelse unreachable;
    const versus = std.mem.indexOfScalar(u8, code, 'v') orelse unreachable;
    const strong_end = @min(second_king, versus);

    const weak_side = code[second_king..];
    const strong_side = code[0..strong_end];

    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(std.heap.c_allocator);

    try builder.appendSlice(std.heap.c_allocator, "8/");
    try appendSide(&builder, weak_side, color == 0);
    try builder.append(std.heap.c_allocator, digitChar(@as(u8, @intCast(8 - weak_side.len))));
    try builder.appendSlice(std.heap.c_allocator, "/8/8/8/8/");
    try appendSide(&builder, strong_side, color == 1);
    try builder.append(std.heap.c_allocator, digitChar(@as(u8, @intCast(8 - strong_side.len))));
    try builder.appendSlice(std.heap.c_allocator, "/8 w - - 0 10");

    return try allocCString(builder.items);
}

fn formatFenAlloc(
    board: []const u8,
    side_to_move: u8,
    chess960: bool,
    castling_rights: u8,
    white_oo_rook_square: u8,
    white_ooo_rook_square: u8,
    black_oo_rook_square: u8,
    black_ooo_rook_square: u8,
    ep_square: u8,
    rule50: c_int,
    game_ply: c_int,
) ![*:0]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(std.heap.c_allocator);

    var rank: i32 = 7;
    while (rank >= 0) : (rank -= 1) {
        var file: usize = 0;
        var empty_count: u8 = 0;

        while (file < 8) : (file += 1) {
            const rank_index: usize = @intCast(rank);
            const square_index = rank_index * 8 + file;
            const piece = board[square_index];
            if (piece == 0) {
                empty_count += 1;
                continue;
            }

            if (empty_count != 0) {
                try builder.append(std.heap.c_allocator, digitChar(empty_count));
                empty_count = 0;
            }

            try builder.append(std.heap.c_allocator, piece_to_char[@as(usize, piece)]);
        }

        if (empty_count != 0) {
            try builder.append(std.heap.c_allocator, digitChar(empty_count));
        }

        if (rank != 0) {
            try builder.append(std.heap.c_allocator, '/');
        }
    }

    try builder.appendSlice(std.heap.c_allocator, if (side_to_move == 0) " w " else " b ");

    var has_castling = false;
    if ((castling_rights & white_oo) != 0) {
        has_castling = true;
        try builder.append(std.heap.c_allocator, if (chess960) rookFileCharUpper(white_oo_rook_square) else 'K');
    }
    if ((castling_rights & white_ooo) != 0) {
        has_castling = true;
        try builder.append(std.heap.c_allocator, if (chess960) rookFileCharUpper(white_ooo_rook_square) else 'Q');
    }
    if ((castling_rights & black_oo) != 0) {
        has_castling = true;
        try builder.append(std.heap.c_allocator, if (chess960) rookFileCharLower(black_oo_rook_square) else 'k');
    }
    if ((castling_rights & black_ooo) != 0) {
        has_castling = true;
        try builder.append(std.heap.c_allocator, if (chess960) rookFileCharLower(black_ooo_rook_square) else 'q');
    }
    if (!has_castling) {
        try builder.append(std.heap.c_allocator, '-');
    }

    if (ep_square == sq_none) {
        try builder.appendSlice(std.heap.c_allocator, " - ");
    } else {
        try builder.append(std.heap.c_allocator, ' ');
        try appendSquare(&builder, ep_square);
        try builder.append(std.heap.c_allocator, ' ');
    }

    try appendInt(&builder, rule50);
    try builder.append(std.heap.c_allocator, ' ');
    const side_offset: c_int = if (side_to_move == black) 1 else 0;
    const fullmove = 1 + @divTrunc(game_ply - side_offset, 2);
    try appendInt(&builder, fullmove);

    return try allocCString(builder.items);
}

fn appendSide(builder: *std.ArrayList(u8), side: []const u8, lower: bool) !void {
    for (side) |byte| {
        try builder.append(std.heap.c_allocator, if (lower) std.ascii.toLower(byte) else byte);
    }
}

fn appendSquare(builder: *std.ArrayList(u8), square: u8) !void {
    try builder.append(std.heap.c_allocator, 'a' + fileOf(square));
    try builder.append(std.heap.c_allocator, '1' + rankOf(square));
}

fn appendInt(builder: *std.ArrayList(u8), value: c_int) !void {
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    try builder.appendSlice(std.heap.c_allocator, text);
}

// Duplicated from position.zig (kept minimal to avoid a back-import cycle).
fn allocCString(value: []const u8) ![*:0]u8 {
    const result = try std.heap.c_allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result[0..value.len], value);
    return result.ptr;
}

fn digitChar(value: u8) u8 {
    return '0' + value;
}

fn fileOf(square: u8) u8 {
    return square & 7;
}

fn rankOf(square: u8) u8 {
    return square >> 3;
}

fn rookFileCharUpper(square: u8) u8 {
    return 'A' + fileOf(square);
}

fn rookFileCharLower(square: u8) u8 {
    return 'a' + fileOf(square);
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "flipFen vertically mirrors and swaps colors" {
    const src = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    const out = flipFen(src.ptr, src.len).?;
    defer std.heap.c_allocator.free(std.mem.span(out));
    // Vertical rank mirror + full case-swap: the symmetric start position returns
    // to the same placement, black to move, castling case-swapped (KQkq -> kqKQ).
    try testing.expectEqualStrings(
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b kqKQ - 0 1",
        std.mem.span(out),
    );
}

test "flipFen is an involution" {
    // flip mirrors the ranks and swaps every case; applying it twice restores the
    // original FEN exactly (rank order back, case back, active color back, and the
    // ep rank 6<->3 mapping back). Covers a symmetric position, an en-passant
    // position, and an asymmetric-castling one.
    const cases = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2",
        "r3k2r/8/8/8/8/8/8/R3K2R w Kq - 5 12",
    };
    for (cases) |fen| {
        const once = flipFen(fen.ptr, fen.len).?;
        defer std.heap.c_allocator.free(std.mem.span(once));
        const once_slice = std.mem.span(once);
        const twice = flipFen(once_slice.ptr, once_slice.len).?;
        defer std.heap.c_allocator.free(std.mem.span(twice));
        try testing.expectEqualStrings(fen, std.mem.span(twice));
    }
}

test "formatFen renders the start position from primitives" {
    // Native piece codes: 1..6 = W P/N/B/R/Q/K, 9..14 = B p/n/b/r/q/k.
    var board = [_]u8{0} ** 64;
    const back = [_]u8{ 4, 2, 3, 5, 6, 3, 2, 4 }; // R N B Q K B N R
    for (0..8) |f| {
        board[f] = back[f]; // rank 1 (white back rank)
        board[8 + f] = 1; // rank 2 white pawns
        board[48 + f] = 9; // rank 7 black pawns
        board[56 + f] = back[f] + 8; // rank 8 black back rank
    }
    const out = formatFen(&board, 0, 0, 0x0F, 7, 0, 63, 56, sq_none, 0, 0).?;
    defer std.heap.c_allocator.free(std.mem.span(out));
    try testing.expectEqualStrings(
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        std.mem.span(out),
    );
}

test "buildEndgameFen places both kings and the extra piece" {
    const code = "KQvK";
    const out = buildEndgameFen(code.ptr, code.len, 0).?;
    defer std.heap.c_allocator.free(std.mem.span(out));
    try testing.expectEqualStrings("8/k7/8/8/8/8/KQ6/8 w - - 0 10", std.mem.span(out));
}
