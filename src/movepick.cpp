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

#include "movepick.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>

#include "position.h"

namespace Stockfish {

extern "C" {

struct ZfishMoveSortEntry {
    std::uint16_t raw_move;
    std::uint16_t reserved;
    int           value;
};

struct ZfishMovePickerState {
    std::uint16_t      tt_move_raw;
    int                stage;
    int                threshold;
    int                depth;
    std::uint8_t       skip_quiets;
    std::size_t        cur;
    std::size_t        end_cur;
    std::size_t        end_bad_captures;
    std::size_t        end_captures;
    std::size_t        end_generated;
    ZfishMoveSortEntry* moves;
};

struct ZfishMovePickerContext {
    const void* pos;
    const void* main_history;
    const void* low_ply_history;
    const void* capture_history;
    const void* continuation_history;
    const void* shared_history;
    int         ply;
};

int zfish_movepick_init_main_stage(std::uint8_t has_checkers, std::uint8_t has_tt_move, int depth);
int zfish_movepick_init_probcut_stage(std::uint8_t has_tt_move);
std::size_t zfish_movepick_score_list(std::uint8_t kind,
                                      const ZfishMovePickerContext* context,
                                      ZfishMoveSortEntry* outputs);
std::uint16_t zfish_movepick_next_move(ZfishMovePickerState* state,
                                       const ZfishMovePickerContext* context);

}  // extern "C"

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
    cur(moves),
    endCur(moves),
    endBadCaptures(moves),
    endCaptures(moves),
    endGenerated(moves),
    threshold(0),
    depth(d),
    ply(pl) {

    stage = zfish_movepick_init_main_stage(std::uint8_t(pos.checkers() ? 1 : 0),
                                           std::uint8_t(ttm && pos.pseudo_legal(ttm) ? 1 : 0),
                                           depth);
}

MovePicker::MovePicker(const Position& p, Move ttm, int th, const CapturePieceToHistory* cph) :
    pos(p),
    mainHistory(nullptr),
    lowPlyHistory(nullptr),
    captureHistory(cph),
    continuationHistory(nullptr),
    sharedHistory(nullptr),
    ttMove(ttm),
    cur(moves),
    endCur(moves),
    endBadCaptures(moves),
    endCaptures(moves),
    endGenerated(moves),
    threshold(th),
    depth(0),
    ply(0) {
    assert(!pos.checkers());

    stage = zfish_movepick_init_probcut_stage(
      std::uint8_t(ttm && pos.capture_stage(ttm) && pos.pseudo_legal(ttm) ? 1 : 0));
}

template<GenType Type>
ExtMove* MovePicker::score(const MoveList<Type>&) {

    static_assert(Type == CAPTURES || Type == QUIETS || Type == EVASIONS, "Wrong type");

    const std::uint8_t kind = Type == CAPTURES ? std::uint8_t{0}
                                : Type == QUIETS ? std::uint8_t{1}
                                                 : std::uint8_t{2};

    const ZfishMovePickerContext context = {
      .pos                  = &pos,
      .main_history         = mainHistory,
      .low_ply_history      = lowPlyHistory,
      .capture_history      = captureHistory,
      .continuation_history = continuationHistory,
      .shared_history       = sharedHistory,
      .ply                  = ply,
    };

    static_assert(sizeof(ExtMove) == sizeof(ZfishMoveSortEntry));
    static_assert(alignof(ExtMove) == alignof(ZfishMoveSortEntry));

    const std::size_t count =
      zfish_movepick_score_list(kind, &context, reinterpret_cast<ZfishMoveSortEntry*>(cur));

    return cur + count;
}

Move MovePicker::next_move() {

    ZfishMovePickerState state{};
    state.tt_move_raw      = ttMove.raw();
    state.stage            = stage;
    state.threshold        = threshold;
    state.depth            = depth;
    state.skip_quiets      = std::uint8_t(skipQuiets ? 1 : 0);
    state.cur              = static_cast<std::size_t>(cur - moves);
    state.end_cur          = static_cast<std::size_t>(endCur - moves);
    state.end_bad_captures = static_cast<std::size_t>(endBadCaptures - moves);
    state.end_captures     = static_cast<std::size_t>(endCaptures - moves);
    state.end_generated    = static_cast<std::size_t>(endGenerated - moves);
    state.moves            = reinterpret_cast<ZfishMoveSortEntry*>(moves);

    const ZfishMovePickerContext context = {
      .pos                  = &pos,
      .main_history         = mainHistory,
      .low_ply_history      = lowPlyHistory,
      .capture_history      = captureHistory,
      .continuation_history = continuationHistory,
      .shared_history       = sharedHistory,
      .ply                  = ply,
    };

    const Move result = Move(zfish_movepick_next_move(&state, &context));

    ttMove         = Move(state.tt_move_raw);
    stage          = state.stage;
    threshold      = state.threshold;
    depth          = Depth(state.depth);
    skipQuiets     = state.skip_quiets != 0;
    cur            = moves + state.cur;
    endCur         = moves + state.end_cur;
    endBadCaptures = moves + state.end_bad_captures;
    endCaptures    = moves + state.end_captures;
    endGenerated   = moves + state.end_generated;

    return result;
}

void MovePicker::skip_quiet_moves() { skipQuiets = true; }

}  // namespace Stockfish
