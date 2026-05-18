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

#ifndef SCORE_H_INCLUDED
#define SCORE_H_INCLUDED

#include <cassert>
#include <cstdlib>
#include <variant>
#include <utility>

#include "types.h"

#if defined(ZFISH_ZIG_BUILD)
    #include "position.h"

extern "C" {
struct ZfishScoreClass {
        int kind;
        int plies;
        int win;
};

ZfishScoreClass zfish_classify_score(int value,
                                                                         int value_tb_win_in_max_ply,
                                                                         int value_tb,
                                                                         int value_mate);
int zfish_uci_to_cp(int value, int material);
}
#endif

namespace Stockfish {

class Position;

class Score {
   public:
    struct Mate {
        int plies;
    };

    struct Tablebase {
        int  plies;
        bool win;
    };

    struct InternalUnits {
        int value;
    };

    Score() = default;
    Score(Value v, const Position& pos);

    template<typename T>
    bool is() const {
        return std::holds_alternative<T>(score);
    }

    template<typename T>
    T get() const {
        return std::get<T>(score);
    }

    template<typename F>
    decltype(auto) visit(F&& f) const {
        return std::visit(std::forward<F>(f), score);
    }

   private:
    std::variant<Mate, Tablebase, InternalUnits> score;
};

#if defined(ZFISH_ZIG_BUILD)
inline int zig_score_material_count(const Position& pos) {
    return pos.count<PAWN>() + 3 * pos.count<KNIGHT>() + 3 * pos.count<BISHOP>()
         + 5 * pos.count<ROOK>() + 9 * pos.count<QUEEN>();
}

inline Score::Score(Value v, const Position& pos) {
    assert(-VALUE_INFINITE < v && v < VALUE_INFINITE);

    const auto score_class = zfish_classify_score(v, VALUE_TB_WIN_IN_MAX_PLY, VALUE_TB, VALUE_MATE);

    switch (score_class.kind)
    {
    case 0 : score = InternalUnits{zfish_uci_to_cp(v, zig_score_material_count(pos))}; break;
    case 1 : score = Tablebase{score_class.plies, score_class.win != 0}; break;
    case 2 : score = Mate{score_class.plies}; break;
    default : std::abort();
    }
}
#endif

}

#endif  // #ifndef SCORE_H_INCLUDED
