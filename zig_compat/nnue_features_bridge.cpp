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

#include "nnue/features/full_threats.h"
#include "nnue/features/half_ka_v2_hm.h"

#include <array>
#include <cstdint>

#include "bitboard.h"
#include "misc.h"
#include "position.h"
#include "types.h"
#include "nnue/nnue_common.h"

namespace Stockfish::Eval::NNUE::Features {

extern "C" {
struct ZfishHalfDiff {
    std::uint8_t from;
    std::uint8_t to;
    std::uint8_t pc;
    std::uint8_t remove_sq;
    std::uint8_t add_sq;
    std::uint8_t remove_pc;
    std::uint8_t add_pc;
};

struct ZfishDirtyThreatRaw {
    std::uint32_t data;
};

struct ZfishFullDiff {
    std::uint8_t us;
    std::uint8_t prev_ksq;
    std::uint8_t ksq;
};

struct ZfishHalfThreatParams {
    std::uint8_t perspective;
    std::uint8_t square;
    std::uint8_t piece;
    std::uint8_t king_square;
};

struct ZfishFullThreatParams {
    std::uint8_t perspective;
    std::uint8_t attacker;
    std::uint8_t from_sq;
    std::uint8_t to_sq;
    std::uint8_t attacked;
    std::uint8_t king_square;
};

std::uint32_t       zfish_half_ka_make_index(ZfishHalfThreatParams params);
bool                zfish_half_ka_requires_refresh(ZfishHalfDiff diff, std::uint8_t perspective);

std::uint32_t       zfish_full_threats_make_index(ZfishFullThreatParams params);
bool                zfish_full_threats_requires_refresh(ZfishFullDiff diff, std::uint8_t perspective);
}

IndexType HalfKAv2_hm::make_index(Color perspective, Square s, Piece pc, Square ksq) {
    return zfish_half_ka_make_index({static_cast<std::uint8_t>(perspective),
                                     static_cast<std::uint8_t>(s),
                                     static_cast<std::uint8_t>(pc),
                                     static_cast<std::uint8_t>(ksq)});
}

void HalfKAv2_hm::append_active_indices(Color perspective, const Position& pos, IndexList& active) {
    Square   ksq = pos.square<KING>(perspective);
    Bitboard bb  = pos.pieces();
    while (bb)
    {
        Square s = pop_lsb(bb);
        active.push_back(make_index(perspective, s, pos.piece_on(s), ksq));
    }
}

void HalfKAv2_hm::append_changed_indices(
  Color perspective, Square ksq, const DiffType& diff, IndexList& removed, IndexList& added) {
    removed.push_back(make_index(perspective, diff.from, diff.pc, ksq));
    if (diff.to != SQ_NONE)
        added.push_back(make_index(perspective, diff.to, diff.pc, ksq));

    if (diff.remove_sq != SQ_NONE)
        removed.push_back(make_index(perspective, diff.remove_sq, diff.remove_pc, ksq));

    if (diff.add_sq != SQ_NONE)
        added.push_back(make_index(perspective, diff.add_sq, diff.add_pc, ksq));
}

bool HalfKAv2_hm::requires_refresh(const DiffType& diff, Color perspective) {
    return zfish_half_ka_requires_refresh(
      {static_cast<std::uint8_t>(diff.from), static_cast<std::uint8_t>(diff.to),
       static_cast<std::uint8_t>(diff.pc), static_cast<std::uint8_t>(diff.remove_sq),
       static_cast<std::uint8_t>(diff.add_sq), static_cast<std::uint8_t>(diff.remove_pc),
       static_cast<std::uint8_t>(diff.add_pc)},
      static_cast<std::uint8_t>(perspective));
}

IndexType FullThreats::make_index(
  Color perspective, Piece attacker, Square from, Square to, Piece attacked, Square ksq) {
    return zfish_full_threats_make_index({static_cast<std::uint8_t>(perspective),
                                          static_cast<std::uint8_t>(attacker),
                                          static_cast<std::uint8_t>(from),
                                          static_cast<std::uint8_t>(to),
                                          static_cast<std::uint8_t>(attacked),
                                          static_cast<std::uint8_t>(ksq)});
}

void FullThreats::append_active_indices(Color perspective, const Position& pos, IndexList& active) {
    const Square   ksq      = pos.square<KING>(perspective);
    const Bitboard occupied = pos.pieces();
    const Bitboard pawns    = pos.pieces(PAWN);

    for (Color color : {WHITE, BLACK})
    {
        const Color c = Color(perspective ^ color);

        {
            const Piece    attacker = make_piece(c, PAWN);
            const Bitboard cPawns   = pos.pieces(c, PAWN);
            const Bitboard pushers  = pawn_single_push_bb(~c, pawns) & cPawns;

            auto process_pawn_attacks = [&](Bitboard attacks, Direction attkDir) {
                while (attacks)
                {
                    Square to       = pop_lsb(attacks);
                    Square from     = to - attkDir;
                    Piece  attacked = pos.piece_on(to);
                    IndexType index = make_index(perspective, attacker, from, to, attacked, ksq);
                    active.push_back_if_lt(index, Dimensions);
                }
            };

            if (c == WHITE)
            {
                process_pawn_attacks(shift<NORTH_EAST>(cPawns) & occupied, NORTH_EAST);
                process_pawn_attacks(shift<NORTH_WEST>(cPawns) & occupied, NORTH_WEST);
                process_pawn_attacks(shift<NORTH>(pushers), NORTH);
            }
            else
            {
                process_pawn_attacks(shift<SOUTH_WEST>(cPawns) & occupied, SOUTH_WEST);
                process_pawn_attacks(shift<SOUTH_EAST>(cPawns) & occupied, SOUTH_EAST);
                process_pawn_attacks(shift<SOUTH>(pushers), SOUTH);
            }
        }

        for (PieceType pt = KNIGHT; pt < KING; ++pt)
        {
            Piece    attacker = make_piece(c, pt);
            Bitboard bb       = pos.pieces(c, pt);
            while (bb)
            {
                Square   from    = pop_lsb(bb);
                Bitboard attacks = attacks_bb(pt, from, occupied) & occupied;
                while (attacks)
                {
                    Square    to       = pop_lsb(attacks);
                    Piece     attacked = pos.piece_on(to);
                    IndexType index    = make_index(perspective, attacker, from, to, attacked, ksq);
                    active.push_back_if_lt(index, Dimensions);
                }
            }
        }
    }
}

void FullThreats::append_changed_indices(Color                   perspective,
                                         Square                  ksq,
                                         const DiffType&         diff,
                                         IndexList&              removed,
                                         IndexList&              added,
                                         FusedUpdateData*,
                                         bool,
                                         const ThreatWeightType* prefetchBase,
                                         IndexType               prefetchStride) {
    const auto& list = diff.list;
    for (std::size_t i = 0; i < list.size(); ++i)
    {
        const auto raw = list[i].raw();
        const bool add = raw >> 31;
        const IndexType index = make_index(perspective, list[i].pc(), list[i].pc_sq(),
                                           list[i].threatened_sq(), list[i].threatened_pc(), ksq);
        if (prefetchBase)
            prefetch<PrefetchRw::READ, PrefetchLoc::LOW>(reinterpret_cast<const void*>(
              reinterpret_cast<uintptr_t>(prefetchBase) + index * prefetchStride));
        (add ? added : removed).push_back_if_lt(index, Dimensions);
    }
}

bool FullThreats::requires_refresh(const DiffType& diff, Color perspective) {
    return zfish_full_threats_requires_refresh(
      {static_cast<std::uint8_t>(diff.us), static_cast<std::uint8_t>(diff.prevKsq),
       static_cast<std::uint8_t>(diff.ksq)},
      static_cast<std::uint8_t>(perspective));
}

}  // namespace Stockfish::Eval::NNUE::Features
