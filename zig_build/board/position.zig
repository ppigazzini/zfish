const std = @import("std");

const white_oo: u8 = 1;
const white_ooo: u8 = 2;
const black_oo: u8 = 4;
const black_ooo: u8 = 8;
const black: u8 = 1;
const sq_none: u8 = 64;

const piece_to_char = " PNBRQK  pnbrqk";

extern fn zfish_position_material_zobrist(piece: u8, count_index: usize) u64;

// Memory mirror of upstream Stockfish StateInfo (src/position.h). Field order,
// types, and C-ABI alignment match the C++ struct exactly so Zig can read the
// live state stack that the C++ Position owns. Only used via pointer (never
// allocated here), so it must stay byte-compatible with the C++ layout.
pub const StateInfo = extern struct {
    material_key: u64,
    pawn_key: u64,
    minor_piece_key: u64,
    non_pawn_key: [2]u64,
    non_pawn_material: [2]c_int,
    castling_rights: c_int,
    rule50: c_int,
    plies_from_null: c_int,
    ep_square: u8,
    key: u64,
    checkers_bb: u64,
    previous: ?*StateInfo,
    blockers_for_king: [2]u64,
    pinners: [2]u64,
    check_squares: [8]u64,
    captured_piece: u8,
    repetition: c_int,
};

// Memory mirror of the leading data members of upstream Position (src/position.h),
// up to `chess960`. The trailing NNUE scratch members (DirtyPiece/DirtyThreats)
// are intentionally omitted: this struct is only ever used through a pointer to
// the live C++ object, so leading-field offsets are all that must match.
pub const Position = extern struct {
    board: [64]u8,
    by_type_bb: [8]u64,
    by_color_bb: [2]u64,
    piece_count: [16]c_int,
    castling_rights_mask: [64]c_int,
    castling_rook_square: [16]u8,
    castling_path: [16]u64,
    st: *StateInfo,
    game_ply: c_int,
    side_to_move: u8,
    chess960: bool,
};

pub fn isRepetition(pos_ptr: *const anyopaque, ply: c_int) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const rep = pos.st.repetition;
    return rep != 0 and rep < ply;
}

pub fn hasRepeated(pos_ptr: *const anyopaque) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    var stc: *const StateInfo = pos.st;
    var end = @min(pos.st.rule50, pos.st.plies_from_null);
    while (end >= 4) : (end -= 1) {
        if (stc.repetition != 0) return true;
        stc = stc.previous.?;
    }
    return false;
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

pub fn computeMaterialKey(piece_counts_ptr: [*]const c_int, piece_count_len: usize) u64 {
    const piece_counts = piece_counts_ptr[0..piece_count_len];
    var key: u64 = 0;

    for (piece_counts, 0..) |count, piece_index| {
        if (!isMaterialPiece(@intCast(piece_index))) {
            continue;
        }

        var slot: usize = 0;
        while (slot < @as(usize, @intCast(count))) : (slot += 1) {
            key ^= zfish_position_material_zobrist(@intCast(piece_index), slot);
        }
    }

    return key;
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

fn isMaterialPiece(piece: u8) bool {
    return switch (piece) {
        1...6, 9...14 => true,
        else => false,
    };
}
