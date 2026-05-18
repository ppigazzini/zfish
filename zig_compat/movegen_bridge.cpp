/*
  Stockfish, a UCI chess playing engine derived from Glaurung 2.1
  Copyright (C) 2004-2026 The Stockfish developers (see AUTHORS file)

  Stockfish is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  Stockfish is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

#include "movegen.h"

#include <array>
#include <cstdint>

#include "bitboard.h"
#include "position.h"

namespace Stockfish {

extern "C" {
struct ZfishMovegenSnapshot {
    std::uint8_t side_to_move;
    std::uint64_t pieces_all;
    std::uint64_t pieces_by_color[2];
    std::uint64_t pieces_by_type[8];
    std::uint8_t king_square[2];
    std::uint8_t ep_square;
    std::uint8_t castling_rights;
    std::uint8_t castling_impeded[16];
    std::uint8_t castling_rook_square[16];
    std::uint64_t checkers;
    std::uint64_t blockers_for_king[2];
};

std::size_t zfish_movegen_generate_captures(const void* pos, std::uint16_t* move_list);
std::size_t zfish_movegen_generate_quiets(const void* pos, std::uint16_t* move_list);
std::size_t zfish_movegen_generate_evasions(const void* pos, std::uint16_t* move_list);
std::size_t zfish_movegen_generate_non_evasions(const void* pos, std::uint16_t* move_list);

void zfish_movegen_fill_snapshot(const void* pos_ptr, ZfishMovegenSnapshot* out) {
    const auto& pos = *static_cast<const Position*>(pos_ptr);

    *out = {};
    out->side_to_move = static_cast<std::uint8_t>(pos.side_to_move());
    out->pieces_all = pos.pieces();
    out->pieces_by_color[WHITE] = pos.pieces(WHITE);
    out->pieces_by_color[BLACK] = pos.pieces(BLACK);
    out->pieces_by_type[ALL_PIECES] = pos.pieces();
    out->pieces_by_type[PAWN] = pos.pieces(PAWN);
    out->pieces_by_type[KNIGHT] = pos.pieces(KNIGHT);
    out->pieces_by_type[BISHOP] = pos.pieces(BISHOP);
    out->pieces_by_type[ROOK] = pos.pieces(ROOK);
    out->pieces_by_type[QUEEN] = pos.pieces(QUEEN);
    out->pieces_by_type[KING] = pos.pieces(KING);
    out->king_square[WHITE] = static_cast<std::uint8_t>(pos.square<KING>(WHITE));
    out->king_square[BLACK] = static_cast<std::uint8_t>(pos.square<KING>(BLACK));
    out->ep_square = static_cast<std::uint8_t>(pos.ep_square());
    out->checkers = pos.checkers();
    out->blockers_for_king[WHITE] = pos.blockers_for_king(WHITE);
    out->blockers_for_king[BLACK] = pos.blockers_for_king(BLACK);

    for (const auto cr : {WHITE_OO, WHITE_OOO, BLACK_OO, BLACK_OOO})
    {
        if (pos.can_castle(cr))
            out->castling_rights |= static_cast<std::uint8_t>(cr);
        out->castling_impeded[cr] = static_cast<std::uint8_t>(pos.castling_impeded(cr));
        out->castling_rook_square[cr] = static_cast<std::uint8_t>(pos.castling_rook_square(cr));
    }
}

std::uint64_t zfish_movegen_attacks(std::uint8_t piece_type,
                                    std::uint8_t square,
                                    std::uint64_t occupied) {
    return attacks_bb(static_cast<PieceType>(piece_type), static_cast<Square>(square), occupied);
}

std::uint64_t zfish_movegen_between(std::uint8_t from, std::uint8_t to) {
    return between_bb(static_cast<Square>(from), static_cast<Square>(to));
}
}

static_assert(sizeof(Move) == sizeof(std::uint16_t));

template<>
Move* generate<CAPTURES>(const Position& pos, Move* moveList) {
    const auto count = zfish_movegen_generate_captures(&pos, reinterpret_cast<std::uint16_t*>(moveList));
    return moveList + count;
}

template<>
Move* generate<QUIETS>(const Position& pos, Move* moveList) {
    const auto count = zfish_movegen_generate_quiets(&pos, reinterpret_cast<std::uint16_t*>(moveList));
    return moveList + count;
}

template<>
Move* generate<EVASIONS>(const Position& pos, Move* moveList) {
    const auto count = zfish_movegen_generate_evasions(&pos, reinterpret_cast<std::uint16_t*>(moveList));
    return moveList + count;
}

template<>
Move* generate<NON_EVASIONS>(const Position& pos, Move* moveList) {
    const auto count =
      zfish_movegen_generate_non_evasions(&pos, reinterpret_cast<std::uint16_t*>(moveList));
    return moveList + count;
}

template<>
Move* generate<LEGAL>(const Position& pos, Move* moveList) {

    Color    us     = pos.side_to_move();
    Bitboard pinned = pos.blockers_for_king(us) & pos.pieces(us);
    Square   ksq    = pos.square<KING>(us);
    Move*    cur    = moveList;

    moveList =
      pos.checkers() ? generate<EVASIONS>(pos, moveList) : generate<NON_EVASIONS>(pos, moveList);
    while (cur != moveList)
        if (((pinned & cur->from_sq()) || cur->from_sq() == ksq || cur->type_of() == EN_PASSANT)
            && !pos.legal(*cur))
            *cur = *(--moveList);
        else
            ++cur;

    return moveList;
}

}  // namespace Stockfish
