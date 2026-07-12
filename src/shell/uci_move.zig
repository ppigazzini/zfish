const std = @import("std");
const movegen_port = @import("movegen");
const position_snapshot = @import("position_snapshot");
const position_types = @import("position_types");
const Position = position_types.Position;

// M16.7: uci_move reads the position snapshot through the main-exported bridge rather
// than importing position -- position (the search driver) imports uci_move to format
// its emit output, so uci_move must not import position back (would cycle).

const normal_move: u16 = 0;
const promotion_move: u16 = 1 << 14;
const castling_move: u16 = 3 << 14;
const move_type_mask: u16 = 3 << 14;
const knight: u8 = 2;
const bishop: u8 = 3;
const rook: u8 = 4;
const queen: u8 = 5;
const file_c: u8 = 2;
const file_g: u8 = 6;
const none_raw: u16 = 0;
const max_moves: usize = 256;

const PositionSnapshot = position_snapshot.PositionSnapshot;

pub fn noneRaw() u16 {
    return none_raw;
}

pub fn toMoveRaw(pos: *const Position, text: []const u8) u16 {
    var move_buffer: [max_moves]u16 = undefined;
    const count = movegen_port.generateLegal(pos, move_buffer[0..].ptr);
    var snapshot = std.mem.zeroes(PositionSnapshot);
    position_snapshot.fill(pos, &snapshot);
    const chess960 = snapshot.is_chess960 != 0;
    return toMoveRawFromLegalMoves(move_buffer[0..count], text, chess960);
}

pub fn toMoveRawFromLegalMoves(legal_moves: []const u16, text: []const u8, chess960: bool) u16 {
    for (legal_moves) |raw_move| {
        if (matchesUciText(raw_move, text, chess960))
            return raw_move;
    }

    return none_raw;
}

fn matchesUciText(raw_move: u16, text: []const u8, chess960: bool) bool {
    if (raw_move == none_raw)
        return false;

    const expected_len: usize = if (moveType(raw_move) == promotion_move) 5 else 4;
    if (text.len != expected_len)
        return false;

    var buffer: [5]u8 = undefined;
    const rendered = renderMoveText(&buffer, raw_move, chess960);

    var index: usize = 0;
    while (index < rendered.len) : (index += 1) {
        if (std.ascii.toLower(text[index]) != rendered[index])
            return false;
    }

    return true;
}

pub fn renderMoveText(buffer: *[5]u8, raw_move: u16, chess960: bool) []const u8 {
    const from = moveFrom(raw_move);
    const target_to = uciToSquare(raw_move, chess960);

    buffer[0] = 'a' + fileOf(from);
    buffer[1] = '1' + rankOf(from);
    buffer[2] = 'a' + fileOf(target_to);
    buffer[3] = '1' + rankOf(target_to);

    if (moveType(raw_move) == promotion_move) {
        buffer[4] = promotionChar(promotionType(raw_move));
        return buffer[0..5];
    }

    return buffer[0..4];
}

fn uciToSquare(raw_move: u16, chess960: bool) u8 {
    if (moveType(raw_move) == castling_move and !chess960) {
        const from = moveFrom(raw_move);
        const to = moveTo(raw_move);
        const file: u8 = if (to > from) file_g else file_c;
        return makeSquare(file, rankOf(from));
    }

    return moveTo(raw_move);
}

fn promotionChar(piece_type: u8) u8 {
    return switch (piece_type) {
        knight => 'n',
        bishop => 'b',
        rook => 'r',
        queen => 'q',
        else => unreachable,
    };
}

fn makeSquare(file: u8, rank: u8) u8 {
    return (rank << 3) + file;
}

fn fileOf(square: u8) u8 {
    return square & 7;
}

fn rankOf(square: u8) u8 {
    return square >> 3;
}

fn moveFrom(raw_move: u16) u8 {
    return @intCast((raw_move >> 6) & 0x3F);
}

fn moveTo(raw_move: u16) u8 {
    return @intCast(raw_move & 0x3F);
}

fn moveType(raw_move: u16) u16 {
    return raw_move & move_type_mask;
}

fn promotionType(raw_move: u16) u8 {
    return @intCast(((raw_move >> 12) & 0x3) + knight);
}

// --- tests (M22.0) --------------------------------------------------------------
test "renderMoveText: normal move and promotion" {
    var buf: [5]u8 = undefined;
    const e2: u16 = 12; // rank 1 (0-based), file e -> 1*8+4
    const e4: u16 = 28;
    try std.testing.expectEqualStrings("e2e4", renderMoveText(&buf, (e2 << 6) | e4, false));

    const e7: u16 = 52;
    const e8: u16 = 60;
    const promo_queen: u16 = 3; // queen - knight, encoded in bits 12..13
    const m: u16 = (1 << 14) | (promo_queen << 12) | (e7 << 6) | e8; // promotion_move
    try std.testing.expectEqualStrings("e7e8q", renderMoveText(&buf, m, false));
}
