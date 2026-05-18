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

#include "nnue/nnue_misc.h"

#include <cstdlib>
#include <memory>
#include <string>

#include "../src/nnue/network.h"
#include "../src/nnue/nnue_accumulator.h"
#include "../src/position.h"
#include "../src/uci.h"

extern "C" {
struct ZfishNnueTraceInput {
    std::uint8_t side_to_move_white;
    std::size_t  bucket_count;
    std::size_t  correct_bucket;
    const int*   psqt_cp;
    const int*   positional_cp;
};

const char* zfish_nnue_format_trace(ZfishNnueTraceInput input);
}

namespace Stockfish::Eval::NNUE {

std::string trace(Position& pos, const Network& network, AccumulatorCaches& caches) {
    auto accumulators = std::make_unique<AccumulatorStack>();
    accumulators->reset();

    const auto t = network.trace_evaluate(pos, *accumulators, caches);

    int psqt_cp[LayerStacks];
    int positional_cp[LayerStacks];
    for (std::size_t bucket = 0; bucket < LayerStacks; ++bucket)
    {
        psqt_cp[bucket]       = UCIEngine::to_cp(t.psqt[bucket], pos);
        positional_cp[bucket] = UCIEngine::to_cp(t.positional[bucket], pos);
    }

    const ZfishNnueTraceInput input = {
      .side_to_move_white = static_cast<std::uint8_t>(pos.side_to_move() == WHITE ? 1 : 0),
      .bucket_count       = LayerStacks,
      .correct_bucket     = t.correctBucket,
      .psqt_cp            = psqt_cp,
      .positional_cp      = positional_cp,
    };

    const char* rendered = zfish_nnue_format_trace(input);
    if (!rendered)
        std::abort();

    std::string result(rendered);
    std::free(const_cast<char*>(rendered));
    return result;
}

}  // namespace Stockfish::Eval::NNUE
