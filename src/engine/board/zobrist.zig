// Provide the Zobrist hash tables + cuckoo (upcoming-repetition) tables and their runtime
// build.
//
// Hold the board's hashing state, carved out of position.zig: the psq/enpassant/
// castling/side/no-pawns Zobrist keys and the cuckoo tables used to detect an
// upcoming repetition. These are process-global tables built once by init()
// (from a fixed-seed xorshift64* PRNG, mirroring upstream Position::init), then
// read by the make/unmake, state-setup, and repetition code. Pulling them into a
// leaf lets those clusters be split out of position.zig without each reaching
// back for the tables. init() is invoked from position.initRuntime.
//
// Depend only on std + bitboard (cuckoo build) + board_core (sqBb), so it is a
// leaf: position -> zobrist, no cycle.

const std = @import("std");
const bitboard = @import("bitboard");
const board_core = @import("board_core");

const sqBb = board_core.sqBb;

pub var zob_psq: [16 * 64]u64 = undefined;
pub var zob_enpassant: [8]u64 = undefined;
pub var zob_castling: [16]u64 = undefined;
pub var zob_side_val: u64 = undefined;
pub var zob_no_pawns: u64 = undefined;
pub var cuckoo_tbl: [8192]u64 = undefined;
pub var cuckoo_move_tbl: [8192]u16 = undefined;

const Prng = struct {
    s: u64,
    fn rand64(self: *Prng) u64 {
        self.s ^= self.s >> 12;
        self.s ^= self.s << 25;
        self.s ^= self.s >> 27;
        return self.s *% 2685821657736338717;
    }
};

const init_pieces = [_]u8{ 1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14 };

pub inline fn psqIdx(pc: u8, sq: u8) usize {
    return @as(usize, pc) * 64 + sq;
}
pub inline fn h1(key: u64) usize {
    return @intCast(key & 0x1fff);
}
pub inline fn h2(key: u64) usize {
    return @intCast((key >> 16) & 0x1fff);
}

// Build the Zobrist + cuckoo tables (upstream Position::init, xorshift64* seeded
// with 1070372). Idempotent: overwrites the tables from scratch each call.
pub fn init() void {
    var rng = Prng{ .s = 1070372 };
    @memset(&zob_psq, 0);
    for (init_pieces) |pc| {
        for (0..64) |s| zob_psq[@as(usize, pc) * 64 + s] = rng.rand64();
    }
    for (56..64) |s| zob_psq[1 * 64 + s] = 0; // W_PAWN promotion rank
    for (0..8) |s| zob_psq[9 * 64 + s] = 0; // B_PAWN promotion rank
    for (0..8) |f| zob_enpassant[f] = rng.rand64();
    for (0..16) |cr| zob_castling[cr] = rng.rand64();
    zob_side_val = rng.rand64();
    zob_no_pawns = rng.rand64();

    @memset(&cuckoo_tbl, 0);
    @memset(&cuckoo_move_tbl, 0);
    var cuckoo_count: usize = 0;
    for (init_pieces) |pc| {
        const pt = pc & 7;
        if (pt == board_core.pawn_pt) continue; // upstream position.cpp:145: pawns contribute no reversible move
        var s1: u8 = 0;
        while (s1 < 64) : (s1 += 1) {
            var s2: u8 = s1 + 1;
            while (s2 < 64) : (s2 += 1) {
                if ((bitboard.attacks(pt, s1, 0) & sqBb(s2)) != 0) {
                    cuckoo_count += 1;
                    var move: u16 = (@as(u16, s1) << 6) | s2;
                    var key = zob_psq[psqIdx(pc, s1)] ^ zob_psq[psqIdx(pc, s2)] ^ zob_side_val;
                    var i = h1(key);
                    while (true) {
                        const tk = cuckoo_tbl[i];
                        cuckoo_tbl[i] = key;
                        key = tk;
                        const tm = cuckoo_move_tbl[i];
                        cuckoo_move_tbl[i] = move;
                        move = tm;
                        if (move == 0) break;
                        i = if (i == h1(key)) h2(key) else h1(key);
                    }
                }
            }
        }
    }
    // Every reversible non-pawn move contributes one entry (upstream position.cpp:161).
    std.debug.assert(cuckoo_count == 3668);
}

test {
    @import("std").testing.refAllDecls(@This());
}
