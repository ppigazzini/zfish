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

#include "evaluate.h"

#include <cassert>
#include <cstdlib>
#include <memory>
#include <string>

#include "nnue/network.h"
#include "nnue/nnue_accumulator.h"
#include "nnue/nnue_misc.h"
#include "position.h"
#include "types.h"
#include "uci.h"

extern "C" {
struct ZfishEvalInput {
    int psqt;
    int positional;
    int optimism;
    int material;
    int rule50_count;
    int value_tb_loss_in_max_ply;
    int value_tb_win_in_max_ply;
};

struct ZfishEvalTraceInput {
    const unsigned char* inner_trace_ptr;
    std::size_t          inner_trace_len;
    int                  nnue_internal_value;
    int                  nnue_white_cp;
    int                  final_white_cp;
};

int         zfish_eval_compute_value(ZfishEvalInput input);
const char* zfish_eval_format_trace(ZfishEvalTraceInput input);

struct ZfishNnueTraceInput {
  std::uint8_t side_to_move_white;
  std::size_t  bucket_count;
  std::size_t  correct_bucket;
  const int*   psqt_cp;
  const int*   positional_cp;
};

const char* zfish_nnue_format_trace(ZfishNnueTraceInput input);
}

namespace {

std::string build_nnue_trace(Stockfish::Position&                     pos,
               const Stockfish::Eval::NNUE::Network&     network,
               Stockfish::Eval::NNUE::AccumulatorCaches& caches) {
  auto accumulators = std::make_unique<Stockfish::Eval::NNUE::AccumulatorStack>();
  accumulators->reset();

  const auto t = network.trace_evaluate(pos, *accumulators, caches);

  int psqt_cp[Stockfish::Eval::NNUE::LayerStacks];
  int positional_cp[Stockfish::Eval::NNUE::LayerStacks];
  for (std::size_t bucket = 0; bucket < Stockfish::Eval::NNUE::LayerStacks; ++bucket)
  {
    psqt_cp[bucket] = Stockfish::UCIEngine::to_cp(t.psqt[bucket], pos);
    positional_cp[bucket] = Stockfish::UCIEngine::to_cp(t.positional[bucket], pos);
  }

  const ZfishNnueTraceInput input = {
    .side_to_move_white = static_cast<std::uint8_t>(pos.side_to_move() == Stockfish::WHITE ? 1 : 0),
    .bucket_count       = Stockfish::Eval::NNUE::LayerStacks,
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

}  // namespace

namespace Stockfish {

Value Eval::evaluate(const Eval::NNUE::Network&     network,
                     const Position&                pos,
                     Eval::NNUE::AccumulatorStack&  accumulators,
                     Eval::NNUE::AccumulatorCaches& caches,
                     int                            optimism) {
    assert(!pos.checkers());

    const auto [psqt, positional] = network.evaluate(pos, accumulators, caches);

    const ZfishEvalInput input = {
      .psqt                     = psqt,
      .positional               = positional,
      .optimism                 = optimism,
      .material                 = 534 * pos.count<PAWN>() + pos.non_pawn_material(),
      .rule50_count             = pos.rule50_count(),
      .value_tb_loss_in_max_ply = VALUE_TB_LOSS_IN_MAX_PLY,
      .value_tb_win_in_max_ply  = VALUE_TB_WIN_IN_MAX_PLY,
    };

    return zfish_eval_compute_value(input);
}

std::string Eval::trace(Position& pos, const Eval::NNUE::Network& network) {
    if (pos.checkers())
        return "Final evaluation: none (in check)";

    auto accumulators = std::make_unique<Eval::NNUE::AccumulatorStack>();
    auto caches       = std::make_unique<Eval::NNUE::AccumulatorCaches>(network);

    const auto inner_trace = build_nnue_trace(pos, network, *caches);
    const auto [psqt, positional] = network.evaluate(pos, *accumulators, *caches);

    Value nnue = psqt + positional;
    Value nnue_white_side = pos.side_to_move() == WHITE ? nnue : -nnue;

    Value final_value = evaluate(network, pos, *accumulators, *caches, VALUE_ZERO);
    Value final_white_side = pos.side_to_move() == WHITE ? final_value : -final_value;

    const ZfishEvalTraceInput input = {
      .inner_trace_ptr     = reinterpret_cast<const unsigned char*>(inner_trace.data()),
      .inner_trace_len     = inner_trace.size(),
      .nnue_internal_value = nnue,
      .nnue_white_cp       = UCIEngine::to_cp(nnue_white_side, pos),
      .final_white_cp      = UCIEngine::to_cp(final_white_side, pos),
    };

    const char* rendered = zfish_eval_format_trace(input);
    if (!rendered)
        std::abort();

    std::string result(rendered);
    std::free(const_cast<char*>(rendered));
    return result;
}

}  // namespace Stockfish
