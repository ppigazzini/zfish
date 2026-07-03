const std = @import("std");
const position_snapshot = @import("position_snapshot");

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

extern fn zfish_movegen_generate_legal(pos: *const anyopaque, out_moves: [*]u16) usize;
extern fn zfish_position_fill_snapshot(pos: *const anyopaque, out: *PositionSnapshot) void;

pub fn noneRaw() u16 {
    return none_raw;
}

pub fn toMoveRaw(pos: *const anyopaque, text: []const u8) u16 {
    var move_buffer: [max_moves]u16 = undefined;
    const count = zfish_movegen_generate_legal(pos, move_buffer[0..].ptr);
    var snapshot = std.mem.zeroes(PositionSnapshot);
    zfish_position_fill_snapshot(pos, &snapshot);
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
