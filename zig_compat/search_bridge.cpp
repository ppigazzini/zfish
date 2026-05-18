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

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <utility>

#define ZFISH_SEARCH_BRIDGE_SKIP_TO_CORRECTED_STATIC_EVAL
#define ZFISH_SEARCH_BRIDGE_SKIP_VALUE_DRAW
#define ZFISH_SEARCH_BRIDGE_SKIP_REDUCTION
#include "../src/search.cpp"

extern "C" {
struct ZfishTimemanInput {
  std::int64_t time_us;
  std::int64_t inc_us;
  std::int64_t start_time;
  std::int64_t npmsec;
  std::int64_t move_overhead;
  std::int64_t available_nodes;
  std::int64_t current_optimum_time;
  std::int64_t current_maximum_time;
  int          movestogo;
  int          ply;
  double       original_time_adjust;
  std::uint8_t ponder;
};

struct ZfishTimemanOutput {
  std::int64_t time_us;
  std::int64_t inc_us;
  std::int64_t start_time;
  std::int64_t npmsec;
  std::int64_t available_nodes;
  std::int64_t optimum_time;
  std::int64_t maximum_time;
  double       original_time_adjust;
  std::uint8_t use_nodes_time;
};

  struct ZfishMoveScoreInput {
    std::uint16_t raw_move;
    std::uint8_t  check_bonus;
    std::uint8_t  from_threatened;
    std::uint8_t  to_threatened;
    std::uint8_t  capture_stage;
    int           capture_history;
    int           captured_piece_value;
    int           main_history;
    int           pawn_history;
    int           continuation_sum;
    int           piece_value;
    int           low_ply_bonus;
  };

  struct ZfishMoveSortEntry {
    std::uint16_t raw_move;
    std::uint16_t reserved;
    int           value;
  };

  struct ZfishEvalInput {
    int psqt;
    int positional;
    int optimism;
    int material;
    int rule50_count;
    int value_tb_loss_in_max_ply;
    int value_tb_win_in_max_ply;
  };

int zfish_search_to_corrected_static_eval(int v, int cv);
int zfish_search_value_draw(std::size_t nodes);
int zfish_search_reduction(const int* reductions,
                           int        depth,
                           int        move_number,
                           int        delta,
                           int        root_delta,
                           std::uint8_t improving);
ZfishTimemanOutput zfish_timeman_init(ZfishTimemanInput input);
  void zfish_movepick_score_moves(std::uint8_t               kind,
                  const ZfishMoveScoreInput* inputs,
                  std::size_t                count,
                  ZfishMoveSortEntry*        outputs);
  void zfish_movepick_partial_insertion_sort(ZfishMoveSortEntry* entries,
                         std::size_t         count,
                         int                 limit);
int zfish_eval_compute_value(ZfishEvalInput input);
}

namespace Stockfish {

namespace {

enum Stages {
  MAIN_TT,
  CAPTURE_INIT,
  GOOD_CAPTURE,
  QUIET_INIT,
  GOOD_QUIET,
  BAD_CAPTURE,
  BAD_QUIET,

  EVASION_TT,
  EVASION_INIT,
  EVASION,

  PROBCUT_TT,
  PROBCUT_INIT,
  PROBCUT,

  QSEARCH_TT,
  QCAPTURE_INIT,
  QCAPTURE
};

Value to_corrected_static_eval(const Value v, const int cv) {
    return Value(zfish_search_to_corrected_static_eval(v, cv));
}

Value value_draw(size_t nodes) { return Value(zfish_search_value_draw(nodes)); }

void partial_insertion_sort(ExtMove* begin, ExtMove* end, int limit) {
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

}  // namespace

int Search::Worker::reduction(bool i, Depth d, int mn, int delta) const {
    return zfish_search_reduction(reductions.data(), d, mn, delta, rootDelta, std::uint8_t(i));
}

TimePoint TimeManagement::optimum() const { return optimumTime; }
TimePoint TimeManagement::maximum() const { return maximumTime; }

void TimeManagement::clear() {
  availableNodes = -1;
}

void TimeManagement::advance_nodes_time(std::int64_t nodes) {
  assert(useNodesTime);
  availableNodes = std::max(int64_t(0), availableNodes - nodes);
}

void TimeManagement::init(Search::LimitsType& limits,
              Color               us,
              int                 ply,
              const OptionsMap&   options,
              double&             originalTimeAdjust) {
  const ZfishTimemanInput input = {
    .time_us              = limits.time[us],
    .inc_us               = limits.inc[us],
    .start_time           = limits.startTime,
    .npmsec               = options["nodestime"],
    .move_overhead        = options["Move Overhead"],
    .available_nodes      = availableNodes,
    .current_optimum_time = optimumTime,
    .current_maximum_time = maximumTime,
    .movestogo            = limits.movestogo,
    .ply                  = ply,
    .original_time_adjust = originalTimeAdjust,
    .ponder               = static_cast<std::uint8_t>(options["Ponder"] ? 1 : 0),
  };

  const auto output = zfish_timeman_init(input);

  startTime          = output.start_time;
  optimumTime        = output.optimum_time;
  maximumTime        = output.maximum_time;
  availableNodes     = output.available_nodes;
  useNodesTime       = output.use_nodes_time != 0;
  originalTimeAdjust = output.original_time_adjust;

  limits.time[us] = output.time_us;
  limits.inc[us]  = output.inc_us;
  limits.npmsec   = output.npmsec;
}

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

  MovePicker::MovePicker(const Position&              p,
               Move                         ttm,
               Depth                        d,
               const ButterflyHistory*      mh,
               const LowPlyHistory*         lph,
               const CapturePieceToHistory* cph,
               const PieceToHistory**       ch,
               const SharedHistories*       sh,
               int                          pl) :
    pos(p),
    mainHistory(mh),
    lowPlyHistory(lph),
    captureHistory(cph),
    continuationHistory(ch),
    sharedHistory(sh),
    ttMove(ttm),
    depth(d),
    ply(pl) {

    if (pos.checkers())
      stage = EVASION_TT + !(ttm && pos.pseudo_legal(ttm));

    else
      stage = (depth > 0 ? MAIN_TT : QSEARCH_TT) + !(ttm && pos.pseudo_legal(ttm));
  }

  MovePicker::MovePicker(const Position& p, Move ttm, int th, const CapturePieceToHistory* cph) :
    pos(p),
    captureHistory(cph),
    ttMove(ttm),
    threshold(th) {
    assert(!pos.checkers());

    stage = PROBCUT_TT + !(ttm && pos.capture_stage(ttm) && pos.pseudo_legal(ttm));
  }

  template<GenType Type>
  ExtMove* MovePicker::score(const MoveList<Type>& ml) {

    static_assert(Type == CAPTURES || Type == QUIETS || Type == EVASIONS, "Wrong type");

    Color us = pos.side_to_move();

    [[maybe_unused]] Bitboard threatByLesser[KING + 1];
    if constexpr (Type == QUIETS)
    {
      threatByLesser[PAWN]   = 0;
      threatByLesser[KNIGHT] = threatByLesser[BISHOP] = pos.attacks_by<PAWN>(~us);
      threatByLesser[ROOK] =
        pos.attacks_by<KNIGHT>(~us) | pos.attacks_by<BISHOP>(~us) | threatByLesser[KNIGHT];
      threatByLesser[QUEEN] = pos.attacks_by<ROOK>(~us) | threatByLesser[ROOK];
      threatByLesser[KING]  = 0;
    }

    ZfishMoveScoreInput inputs[MAX_MOVES]{};
    ZfishMoveSortEntry  outputs[MAX_MOVES]{};
    std::size_t         count = 0;

    for (auto move : ml)
    {
      const Square    from          = move.from_sq();
      const Square    to            = move.to_sq();
      const Piece     pc            = pos.moved_piece(move);
      const PieceType pt            = type_of(pc);
      const Piece     capturedPiece = pos.piece_on(to);

      auto& input = inputs[count++];
      input.raw_move             = move.raw();
      input.capture_history      = 0;
      input.captured_piece_value = 0;
      input.main_history         = 0;
      input.pawn_history         = 0;
      input.continuation_sum     = 0;
      input.check_bonus          = 0;
      input.from_threatened      = 0;
      input.to_threatened        = 0;
      input.capture_stage        = 0;
      input.piece_value          = 0;
      input.low_ply_bonus        = 0;

      if constexpr (Type == CAPTURES)
      {
        input.capture_history      = (*captureHistory)[pc][to][type_of(capturedPiece)];
        input.captured_piece_value = int(PieceValue[capturedPiece]);
      }
      else if constexpr (Type == QUIETS)
      {
        input.main_history     = (*mainHistory)[us][move.raw()];
        input.pawn_history     = sharedHistory->pawn_entry(pos)[pc][to];
        input.continuation_sum = (*continuationHistory[0])[pc][to]
                     + (*continuationHistory[1])[pc][to]
                     + (*continuationHistory[2])[pc][to]
                     + (*continuationHistory[3])[pc][to]
                     + (*continuationHistory[5])[pc][to];
        input.check_bonus      = (pos.check_squares(pt) & to) && pos.see_ge(move, -75);
        input.from_threatened  = bool(threatByLesser[pt] & from);
        input.to_threatened    = bool(threatByLesser[pt] & to);
        input.piece_value      = int(PieceValue[pt]);
        if (ply < LOW_PLY_HISTORY_SIZE)
          input.low_ply_bonus = 8 * (*lowPlyHistory)[ply][move.raw()] / (1 + ply);
      }
      else
      {
        input.main_history         = (*mainHistory)[us][move.raw()];
        input.continuation_sum     = (*continuationHistory[0])[pc][to];
        input.captured_piece_value = int(PieceValue[capturedPiece]);
        input.capture_stage        = pos.capture_stage(move);
      }
    }

    const std::uint8_t kind = Type == CAPTURES ? std::uint8_t{0}
                  : Type == QUIETS ? std::uint8_t{1}
                           : std::uint8_t{2};
    zfish_movepick_score_moves(kind, inputs, count, outputs);

    ExtMove* it = cur;
    for (std::size_t i = 0; i < count; ++i)
    {
      ExtMove& move = *it++;
      move          = Move(outputs[i].raw_move);
      move.value    = outputs[i].value;
    }
    return it;
  }

  template<typename Pred>
  Move MovePicker::select(Pred filter) {

    for (; cur < endCur; ++cur)
      if (*cur != ttMove && filter())
        return *cur++;

    return Move::none();
  }

  Move MovePicker::next_move() {

    constexpr int goodQuietThreshold = -14000;
  top:
    switch (stage)
    {

    case MAIN_TT :
    case EVASION_TT :
    case QSEARCH_TT :
    case PROBCUT_TT :
      ++stage;
      return ttMove;

    case CAPTURE_INIT :
    case PROBCUT_INIT :
    case QCAPTURE_INIT : {
      MoveList<CAPTURES> ml(pos);

      cur = endBadCaptures = moves;
      endCur = endCaptures = score<CAPTURES>(ml);

      partial_insertion_sort(cur, endCur, std::numeric_limits<int>::min());
      ++stage;
      goto top;
    }

    case GOOD_CAPTURE :
      if (select([&]() {
          if (pos.see_ge(*cur, -cur->value / 18))
            return true;
          std::swap(*endBadCaptures++, *cur);
          return false;
        }))
        return *(cur - 1);

      ++stage;
      [[fallthrough]];

    case QUIET_INIT :
      if (!skipQuiets)
      {
        MoveList<QUIETS> ml(pos);

        endCur = endGenerated = score<QUIETS>(ml);

        partial_insertion_sort(cur, endCur, -3560 * depth);
      }

      ++stage;
      [[fallthrough]];

    case GOOD_QUIET :
      if (!skipQuiets && select([&]() { return cur->value > goodQuietThreshold; }))
        return *(cur - 1);

      cur    = moves;
      endCur = endBadCaptures;

      ++stage;
      [[fallthrough]];

    case BAD_CAPTURE :
      if (select([]() { return true; }))
        return *(cur - 1);

      cur    = endCaptures;
      endCur = endGenerated;

      ++stage;
      [[fallthrough]];

    case BAD_QUIET :
      if (!skipQuiets)
        return select([&]() { return cur->value <= goodQuietThreshold; });

      return Move::none();

    case EVASION_INIT : {
      MoveList<EVASIONS> ml(pos);

      cur    = moves;
      endCur = endGenerated = score<EVASIONS>(ml);

      partial_insertion_sort(cur, endCur, std::numeric_limits<int>::min());
      ++stage;
      [[fallthrough]];
    }

    case EVASION :
    case QCAPTURE :
      return select([]() { return true; });

    case PROBCUT :
      return select([&]() { return pos.see_ge(*cur, threshold); });
    }

    assert(false);
    return Move::none();
  }

  void MovePicker::skip_quiet_moves() { skipQuiets = true; }

}  // namespace Stockfish
