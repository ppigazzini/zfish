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

#ifndef MOVEPICK_H_INCLUDED
#define MOVEPICK_H_INCLUDED

#include <cstddef>
#include <cstdint>

#include "history.h"
#include "movegen.h"
#include "types.h"

#if defined(ZFISH_ZIG_BUILD)
extern "C" {
struct ZfishMoveSortEntry {
  std::uint16_t raw_move;
  std::uint16_t reserved;
  int           value;
};

void zfish_movepick_partial_insertion_sort(ZfishMoveSortEntry* entries,
                       std::size_t         count,
                       int                 limit);
}
#endif

namespace Stockfish {

#if defined(ZFISH_ZIG_BUILD)
inline void partial_insertion_sort(ExtMove* begin, ExtMove* end, int limit) {
  const auto count = static_cast<std::size_t>(end - begin);
  ZfishMoveSortEntry entries[MAX_MOVES]{};

  for (std::size_t i = 0; i < count; ++i)
  {
    entries[i].raw_move = begin[i].raw();
    entries[i].value    = begin[i].value;
  }

  zfish_movepick_partial_insertion_sort(entries, count, limit);

  for (std::size_t i = 0; i < count; ++i)
  {
    begin[i]       = Move(entries[i].raw_move);
    begin[i].value = entries[i].value;
  }
}
#endif

class Position;

// The MovePicker class is used to pick one pseudo-legal move at a time from the
// current position. The most important method is next_move(), which emits one
// new pseudo-legal move on every call, until there are no moves left, when
// Move::none() is returned. In order to improve the efficiency of the alpha-beta
// algorithm, MovePicker attempts to return the moves which are most likely to get
// a cut-off first.
class MovePicker {

   public:
    MovePicker(const MovePicker&)            = delete;
    MovePicker& operator=(const MovePicker&) = delete;
    MovePicker(const Position&,
               Move,
               Depth,
               const ButterflyHistory*,
               const LowPlyHistory*,
               const CapturePieceToHistory*,
               const PieceToHistory**,
               const SharedHistories*,
               int);
    MovePicker(const Position&, Move, int, const CapturePieceToHistory*);
    Move next_move();
    void skip_quiet_moves();

   private:
    template<typename Pred>
    Move select(Pred);
    template<GenType T>
    ExtMove* score(const MoveList<T>&);
    ExtMove* begin() { return cur; }
    ExtMove* end() { return endCur; }

    const Position&              pos;
    const ButterflyHistory*      mainHistory;
    const LowPlyHistory*         lowPlyHistory;
    const CapturePieceToHistory* captureHistory;
    const PieceToHistory**       continuationHistory;
    const SharedHistories*       sharedHistory;
    Move                         ttMove;
    ExtMove *                    cur, *endCur, *endBadCaptures, *endCaptures, *endGenerated;
    int                          stage;
    int                          threshold;
    Depth                        depth;
    int                          ply;
    bool                         skipQuiets = false;
    ExtMove                      moves[MAX_MOVES];
};

}  // namespace Stockfish

#endif  // #ifndef MOVEPICK_H_INCLUDED
