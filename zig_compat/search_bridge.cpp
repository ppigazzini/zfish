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

#include <cstddef>
#include <cstdint>

#define ZFISH_SEARCH_BRIDGE_SKIP_TO_CORRECTED_STATIC_EVAL
#define ZFISH_SEARCH_BRIDGE_SKIP_VALUE_DRAW
#define ZFISH_SEARCH_BRIDGE_SKIP_REDUCTION
#include "../src/search.cpp"

extern "C" {
int zfish_search_to_corrected_static_eval(int v, int cv);
int zfish_search_value_draw(std::size_t nodes);
int zfish_search_reduction(const int* reductions,
                           int        depth,
                           int        move_number,
                           int        delta,
                           int        root_delta,
                           std::uint8_t improving);
}

namespace Stockfish {

namespace {

Value to_corrected_static_eval(const Value v, const int cv) {
    return Value(zfish_search_to_corrected_static_eval(v, cv));
}

Value value_draw(size_t nodes) { return Value(zfish_search_value_draw(nodes)); }

}  // namespace

int Search::Worker::reduction(bool i, Depth d, int mn, int delta) const {
    return zfish_search_reduction(reductions.data(), d, mn, delta, rootDelta, std::uint8_t(i));
}

}  // namespace Stockfish
