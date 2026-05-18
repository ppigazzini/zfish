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

#include "uci.h"

#include <algorithm>
#include <array>
#include <bitset>
#include <cctype>
#include <cstdlib>
#include <initializer_list>
#include <iterator>
#include <map>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "benchmark.h"
#include "engine.h"
#include "memory.h"
#include "misc.h"
#include "movegen.h"
#include "numa.h"
#include "position.h"
#include "score.h"
#include "search.h"
#include "tune.h"
#include "types.h"
#include "ucioption.h"

#define ZFISH_POSITION_BRIDGE_SKIP_COMPUTE_MATERIAL_KEY
#define ZFISH_POSITION_BRIDGE_SKIP_ENDGAME_SET
#define ZFISH_POSITION_BRIDGE_SKIP_FEN
#include "../src/position.cpp"

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

#include "engine.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <deque>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iosfwd>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <ostream>
#include <sstream>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

#define INCBIN_SILENCE_BITCODE_WARNING
#include "incbin/incbin.h"

#include "evaluate.h"
#include "misc.h"
#include "nnue/network.h"
#include "nnue/nnue_architecture.h"
#include "nnue/nnue_common.h"
#include "nnue/nnue_misc.h"
#include "numa.h"
#include "perft.h"
#include "position.h"
#include "search.h"
#include "shm.h"
#include "syzygy/tbprobe.h"
#include "types.h"
#include "uci.h"
#include "ucioption.h"

#define PieceToChar engine_bridge_tbprobe_piece_to_char
#define ZFISH_TBPROBE_BRIDGE_SKIP_DTZ_BEFORE_ZEROING
#define ZFISH_TBPROBE_BRIDGE_SKIP_ADD
#include "../src/syzygy/tbprobe.cpp"
#undef PieceToChar

#include "nnue/nnue_accumulator.h"
#include "nnue/features/full_threats.h"
#include "nnue/features/half_ka_v2_hm.h"

#include <new>

#include "bitboard.h"
#include "nnue/nnue_feature_transformer.h"  // IWYU pragma: keep
#include "nnue/simd.h"

namespace Stockfish::Eval::NNUE {

using namespace SIMD;

namespace {

template<bool Forward, typename FeatureSet>
void update_accumulator_incremental(Color                               perspective,
                                    const FeatureTransformer&           featureTransformer,
                                    const Square                        ksq,
                                    AccumulatorState<FeatureSet>&       target_state,
                                    const AccumulatorState<FeatureSet>& computed);

void update_accumulator_refresh_cache(Color                            perspective,
                                      const FeatureTransformer&        featureTransformer,
                                      const Position&                  pos,
                                      AccumulatorState<PSQFeatureSet>& accumulatorState,
                                      AccumulatorCaches&               cache);

void update_threats_accumulator_full(Color                               perspective,
                                     const FeatureTransformer&           featureTransformer,
                                     const Position&                     pos,
                                     AccumulatorState<ThreatFeatureSet>& accumulatorState);

constexpr std::uint8_t ZfishAccumulatorPsqFeature    = 0;
constexpr std::uint8_t ZfishAccumulatorThreatFeature = 1;

}  // namespace

template<typename T>
const AccumulatorState<T>& AccumulatorStack::latest() const noexcept {
    return accumulators<T>()[size - 1];
}

template const AccumulatorState<PSQFeatureSet>& AccumulatorStack::latest() const noexcept;
template const AccumulatorState<ThreatFeatureSet>& AccumulatorStack::latest() const noexcept;

template<typename T>
AccumulatorState<T>& AccumulatorStack::mut_latest() noexcept {
    return mut_accumulators<T>()[size - 1];
}

template<typename T>
const std::array<AccumulatorState<T>, AccumulatorStack::MaxSize>&
AccumulatorStack::accumulators() const noexcept {
    static_assert(std::is_same_v<T, PSQFeatureSet> || std::is_same_v<T, ThreatFeatureSet>,
                  "Invalid Feature Set Type");

    if constexpr (std::is_same_v<T, PSQFeatureSet>)
        return psq_accumulators;

    if constexpr (std::is_same_v<T, ThreatFeatureSet>)
        return threat_accumulators;
}

template<typename T>
std::array<AccumulatorState<T>, AccumulatorStack::MaxSize>&
AccumulatorStack::mut_accumulators() noexcept {
    static_assert(std::is_same_v<T, PSQFeatureSet> || std::is_same_v<T, ThreatFeatureSet>,
                  "Invalid Feature Set Type");

    if constexpr (std::is_same_v<T, PSQFeatureSet>)
        return psq_accumulators;

    if constexpr (std::is_same_v<T, ThreatFeatureSet>)
        return threat_accumulators;
}

void AccumulatorStack::reset() noexcept {
    psq_accumulators[0].reset({});
    threat_accumulators[0].reset({});
    size = 1;
}

std::pair<DirtyPiece&, DirtyThreats&> AccumulatorStack::push() noexcept {
    assert(size < MaxSize);
    auto& dp  = psq_accumulators[size].reset();
    auto& dts = threat_accumulators[size].reset();
    new (&dts) DirtyThreats;
    size++;
    return {dp, dts};
}

void AccumulatorStack::pop() noexcept {
    assert(size > 1);
    size--;
}

struct AccumulatorBridgeAccess {
    static std::size_t stackSize(const AccumulatorStack& stack) { return stack.size; }

    static bool psqComputed(const AccumulatorStack& stack, std::size_t index, Color perspective) {
        return stack.accumulators<PSQFeatureSet>()[index].computed[perspective];
    }

    static bool threatComputed(const AccumulatorStack& stack,
                               std::size_t            index,
                               Color                  perspective) {
        return stack.accumulators<ThreatFeatureSet>()[index].computed[perspective];
    }

    static bool psqRequiresRefresh(const AccumulatorStack& stack,
                                   std::size_t            index,
                                   Color                  perspective) {
        return PSQFeatureSet::requires_refresh(stack.accumulators<PSQFeatureSet>()[index].diff,
                                               perspective);
    }

    static bool threatRequiresRefresh(const AccumulatorStack& stack,
                                      std::size_t            index,
                                      Color                  perspective) {
        return ThreatFeatureSet::requires_refresh(
          stack.accumulators<ThreatFeatureSet>()[index].diff, perspective);
    }

    static void forwardPsq(AccumulatorStack&           stack,
                           Color                       perspective,
                           const Position&             pos,
                           const FeatureTransformer&   featureTransformer,
                           std::size_t                 begin) {
        stack.forward_update_incremental<PSQFeatureSet>(
          perspective, pos, featureTransformer, begin);
    }

    static void forwardThreat(AccumulatorStack&         stack,
                              Color                     perspective,
                              const Position&           pos,
                              const FeatureTransformer& featureTransformer,
                              std::size_t               begin) {
        stack.forward_update_incremental<ThreatFeatureSet>(
          perspective, pos, featureTransformer, begin);
    }

    static void backwardPsq(AccumulatorStack&         stack,
                            Color                     perspective,
                            const Position&           pos,
                            const FeatureTransformer& featureTransformer,
                            std::size_t               end) {
        stack.backward_update_incremental<PSQFeatureSet>(perspective, pos, featureTransformer, end);
    }

    static void backwardThreat(AccumulatorStack&         stack,
                               Color                     perspective,
                               const Position&           pos,
                               const FeatureTransformer& featureTransformer,
                               std::size_t               end) {
        stack.backward_update_incremental<ThreatFeatureSet>(
          perspective, pos, featureTransformer, end);
    }

    static void refreshPsq(AccumulatorStack&         stack,
                           Color                     perspective,
                           const Position&           pos,
                           const FeatureTransformer& featureTransformer,
                           AccumulatorCaches&        cache) {
                update_accumulator_refresh_cache(
                    perspective, featureTransformer, pos, stack.mut_latest<PSQFeatureSet>(), cache);
    }

    static void refreshThreat(AccumulatorStack&         stack,
                              Color                     perspective,
                              const Position&           pos,
                              const FeatureTransformer& featureTransformer,
                              AccumulatorCaches&        cache) {
                (void) cache;
                update_threats_accumulator_full(
                    perspective, featureTransformer, pos, stack.mut_latest<ThreatFeatureSet>());
    }
};

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

std::uint32_t zfish_half_ka_make_index(ZfishHalfThreatParams params);
bool          zfish_half_ka_requires_refresh(ZfishHalfDiff diff, std::uint8_t perspective);

std::uint32_t zfish_full_threats_make_index(ZfishFullThreatParams params);
bool          zfish_full_threats_requires_refresh(ZfishFullDiff diff, std::uint8_t perspective);

void zfish_accumulator_evaluate(void*                  stack,
                                const void*            pos,
                                const void*            feature_transformer,
                                void*                  cache);

std::size_t zfish_accumulator_stack_size(const void* stack_ptr) {
    return AccumulatorBridgeAccess::stackSize(*static_cast<const AccumulatorStack*>(stack_ptr));
}

bool zfish_accumulator_state_computed(const void*    stack_ptr,
                                      std::uint8_t   feature_kind,
                                      std::size_t    index,
                                      std::uint8_t   perspective) {
    const auto& stack = *static_cast<const AccumulatorStack*>(stack_ptr);
    const auto  side  = static_cast<Color>(perspective);

    switch (feature_kind)
    {
    case ZfishAccumulatorPsqFeature:
        return AccumulatorBridgeAccess::psqComputed(stack, index, side);
    case ZfishAccumulatorThreatFeature:
        return AccumulatorBridgeAccess::threatComputed(stack, index, side);
    default:
        assert(false);
        return false;
    }
}

bool zfish_accumulator_requires_refresh(const void*  stack_ptr,
                                        std::uint8_t feature_kind,
                                        std::size_t  index,
                                        std::uint8_t perspective) {
    const auto& stack = *static_cast<const AccumulatorStack*>(stack_ptr);
    const auto  side  = static_cast<Color>(perspective);

    switch (feature_kind)
    {
    case ZfishAccumulatorPsqFeature:
        return AccumulatorBridgeAccess::psqRequiresRefresh(stack, index, side);
    case ZfishAccumulatorThreatFeature:
        return AccumulatorBridgeAccess::threatRequiresRefresh(stack, index, side);
    default:
        assert(false);
        return false;
    }
}

void zfish_accumulator_forward_update(void*          stack_ptr,
                                      std::uint8_t   feature_kind,
                                      std::uint8_t   perspective,
                                      const void*    pos_ptr,
                                      const void*    feature_transformer_ptr,
                                      std::size_t    begin) {
    auto&       stack              = *static_cast<AccumulatorStack*>(stack_ptr);
    const auto& pos                = *static_cast<const Position*>(pos_ptr);
    const auto& featureTransformer =
      *static_cast<const FeatureTransformer*>(feature_transformer_ptr);
    const auto side = static_cast<Color>(perspective);

    switch (feature_kind)
    {
    case ZfishAccumulatorPsqFeature:
        AccumulatorBridgeAccess::forwardPsq(stack, side, pos, featureTransformer, begin);
        return;
    case ZfishAccumulatorThreatFeature:
        AccumulatorBridgeAccess::forwardThreat(stack, side, pos, featureTransformer, begin);
        return;
    default:
        assert(false);
        return;
    }
}

void zfish_accumulator_backward_update(void*         stack_ptr,
                                       std::uint8_t  feature_kind,
                                       std::uint8_t  perspective,
                                       const void*   pos_ptr,
                                       const void*   feature_transformer_ptr,
                                       std::size_t   end) {
    auto&       stack              = *static_cast<AccumulatorStack*>(stack_ptr);
    const auto& pos                = *static_cast<const Position*>(pos_ptr);
    const auto& featureTransformer =
      *static_cast<const FeatureTransformer*>(feature_transformer_ptr);
    const auto side = static_cast<Color>(perspective);

    switch (feature_kind)
    {
    case ZfishAccumulatorPsqFeature:
        AccumulatorBridgeAccess::backwardPsq(stack, side, pos, featureTransformer, end);
        return;
    case ZfishAccumulatorThreatFeature:
        AccumulatorBridgeAccess::backwardThreat(stack, side, pos, featureTransformer, end);
        return;
    default:
        assert(false);
        return;
    }
}

void zfish_accumulator_refresh_latest(void*          stack_ptr,
                                      std::uint8_t   feature_kind,
                                      std::uint8_t   perspective,
                                      const void*    pos_ptr,
                                      const void*    feature_transformer_ptr,
                                      void*          cache_ptr) {
    auto&       stack              = *static_cast<AccumulatorStack*>(stack_ptr);
    const auto& pos                = *static_cast<const Position*>(pos_ptr);
    const auto& featureTransformer =
      *static_cast<const FeatureTransformer*>(feature_transformer_ptr);
    auto&      cache = *static_cast<AccumulatorCaches*>(cache_ptr);
    const auto side  = static_cast<Color>(perspective);

    switch (feature_kind)
    {
    case ZfishAccumulatorPsqFeature:
        AccumulatorBridgeAccess::refreshPsq(stack, side, pos, featureTransformer, cache);
        return;
    case ZfishAccumulatorThreatFeature:
        AccumulatorBridgeAccess::refreshThreat(stack, side, pos, featureTransformer, cache);
        return;
    default:
        assert(false);
        return;
    }
}
}

void AccumulatorStack::evaluate(const Position&           pos,
                                const FeatureTransformer& featureTransformer,
                                AccumulatorCaches&        cache) noexcept {
    zfish_accumulator_evaluate(this, &pos, &featureTransformer, &cache);
}

template<typename FeatureSet>
void AccumulatorStack::forward_update_incremental(Color                     perspective,
                                                  const Position&           pos,
                                                  const FeatureTransformer& featureTransformer,
                                                  const std::size_t         begin) noexcept {
    assert(begin < accumulators<FeatureSet>().size());
    assert(accumulators<FeatureSet>()[begin].computed[perspective]);

    const Square ksq = pos.square<KING>(perspective);

    for (std::size_t next = begin + 1; next < size; next++)
    {
        update_accumulator_incremental<true>(perspective, featureTransformer, ksq,
                                             mut_accumulators<FeatureSet>()[next],
                                             accumulators<FeatureSet>()[next - 1]);
    }

    assert(latest<FeatureSet>().computed[perspective]);
}

template<typename FeatureSet>
void AccumulatorStack::backward_update_incremental(Color                     perspective,
                                                   const Position&           pos,
                                                   const FeatureTransformer& featureTransformer,
                                                   const std::size_t         end) noexcept {
    assert(end < accumulators<FeatureSet>().size());
    assert(end < size);
    assert(latest<FeatureSet>().computed[perspective]);

    const Square ksq = pos.square<KING>(perspective);

    for (std::int64_t next = std::int64_t(size) - 2; next >= std::int64_t(end); next--)
        update_accumulator_incremental<false>(perspective, featureTransformer, ksq,
                                              mut_accumulators<FeatureSet>()[next],
                                              accumulators<FeatureSet>()[next + 1]);

    assert(accumulators<FeatureSet>()[end].computed[perspective]);
}

namespace {

template<typename VectorWrapper,
         IndexType Width,
         UpdateOperation... ops,
         typename ElementType,
         typename... Ts,
         std::enable_if_t<is_all_same_v<ElementType, Ts...>, bool> = true>
void fused_row_reduce(const ElementType* in, ElementType* out, const Ts* const... rows) {
    constexpr IndexType size = Width * sizeof(ElementType) / sizeof(typename VectorWrapper::type);

    auto* vecIn  = reinterpret_cast<const typename VectorWrapper::type*>(in);
    auto* vecOut = reinterpret_cast<typename VectorWrapper::type*>(out);

    for (IndexType i = 0; i < size; ++i)
        vecOut[i] = fused<VectorWrapper, ops...>(
          vecIn[i], reinterpret_cast<const typename VectorWrapper::type*>(rows)[i]...);
}

template<typename FeatureSet>
struct AccumulatorUpdateContext {
    Color                               perspective;
    const FeatureTransformer&           featureTransformer;
    const AccumulatorState<FeatureSet>& from;
    AccumulatorState<FeatureSet>&       to;

    AccumulatorUpdateContext(Color                               persp,
                             const FeatureTransformer&           ft,
                             const AccumulatorState<FeatureSet>& accF,
                             AccumulatorState<FeatureSet>&       accT) noexcept :
        perspective{persp},
        featureTransformer{ft},
        from{accF},
        to{accT} {}

    template<UpdateOperation... ops,
             typename... Ts,
             std::enable_if_t<is_all_same_v<IndexType, Ts...>, bool> = true>
    void apply(const Ts... indices) {
        constexpr IndexType Dimensions = FeatureTransformer::OutputDimensions;

        auto to_weight_vector = [&](const IndexType index) {
            return &featureTransformer.weights[index * Dimensions];
        };

        auto to_psqt_weight_vector = [&](const IndexType index) {
            return &featureTransformer.psqtWeights[index * PSQTBuckets];
        };

        fused_row_reduce<Vec16Wrapper, Dimensions, ops...>(from.accumulation[perspective].data(),
                                                           to.accumulation[perspective].data(),
                                                           to_weight_vector(indices)...);

        fused_row_reduce<Vec32Wrapper, PSQTBuckets, ops...>(
          from.psqtAccumulation[perspective].data(), to.psqtAccumulation[perspective].data(),
          to_psqt_weight_vector(indices)...);
    }

    void apply(const typename FeatureSet::IndexList& added,
               const typename FeatureSet::IndexList& removed) {
        constexpr IndexType Dimensions = FeatureTransformer::OutputDimensions;

        const auto& fromAcc = from.accumulation[perspective];
        auto&       toAcc   = to.accumulation[perspective];

        const auto& fromPsqtAcc = from.psqtAccumulation[perspective];
        auto&       toPsqtAcc   = to.psqtAccumulation[perspective];

#ifdef VECTOR
        using Tiling = SIMDTiling<Dimensions, Dimensions, PSQTBuckets>;

        vec_t      acc[Tiling::NumRegs];
        psqt_vec_t psqt[Tiling::NumPsqtRegs];

        const auto* threatWeights = &featureTransformer.threatWeights[0];

        for (IndexType j = 0; j < Dimensions / Tiling::TileHeight; ++j)
        {
            auto* fromTile = reinterpret_cast<const vec_t*>(&fromAcc[j * Tiling::TileHeight]);
            auto* toTile   = reinterpret_cast<vec_t*>(&toAcc[j * Tiling::TileHeight]);

            for (IndexType k = 0; k < Tiling::NumRegs; ++k)
                acc[k] = fromTile[k];

            for (int i = 0; i < removed.ssize(); ++i)
            {
                size_t       index  = removed[i];
                const size_t offset = Dimensions * index;
                auto*        column = reinterpret_cast<const vec_i8_t*>(&threatWeights[offset]);

#ifdef USE_NEON
                for (IndexType k = 0; k < Tiling::NumRegs; k += 2)
                {
                    acc[k]     = vsubw_s8(acc[k], vget_low_s8(column[k / 2]));
                    acc[k + 1] = vsubw_high_s8(acc[k + 1], column[k / 2]);
                }
#else
                for (IndexType k = 0; k < Tiling::NumRegs; ++k)
                    acc[k] = vec_sub_16(acc[k], vec_convert_8_16(column[k]));
#endif
            }

            for (int i = 0; i < added.ssize(); ++i)
            {
                size_t       index  = added[i];
                const size_t offset = Dimensions * index;
                auto*        column = reinterpret_cast<const vec_i8_t*>(&threatWeights[offset]);

#ifdef USE_NEON
                for (IndexType k = 0; k < Tiling::NumRegs; k += 2)
                {
                    acc[k]     = vaddw_s8(acc[k], vget_low_s8(column[k / 2]));
                    acc[k + 1] = vaddw_high_s8(acc[k + 1], column[k / 2]);
                }
#else
                for (IndexType k = 0; k < Tiling::NumRegs; ++k)
                    acc[k] = vec_add_16(acc[k], vec_convert_8_16(column[k]));
#endif
            }

            for (IndexType k = 0; k < Tiling::NumRegs; k++)
                vec_store(&toTile[k], acc[k]);

            threatWeights += Tiling::TileHeight;
        }

        for (IndexType j = 0; j < PSQTBuckets / Tiling::PsqtTileHeight; ++j)
        {
            auto* fromTilePsqt =
              reinterpret_cast<const psqt_vec_t*>(&fromPsqtAcc[j * Tiling::PsqtTileHeight]);
            auto* toTilePsqt =
              reinterpret_cast<psqt_vec_t*>(&toPsqtAcc[j * Tiling::PsqtTileHeight]);

            for (IndexType k = 0; k < Tiling::NumPsqtRegs; ++k)
                psqt[k] = fromTilePsqt[k];

            for (int i = 0; i < removed.ssize(); ++i)
            {
                size_t       index      = removed[i];
                const size_t offset     = PSQTBuckets * index + j * Tiling::PsqtTileHeight;
                auto*        columnPsqt = reinterpret_cast<const psqt_vec_t*>(
                  &featureTransformer.threatPsqtWeights[offset]);

                for (std::size_t k = 0; k < Tiling::NumPsqtRegs; ++k)
                    psqt[k] = vec_sub_psqt_32(psqt[k], columnPsqt[k]);
            }

            for (int i = 0; i < added.ssize(); ++i)
            {
                size_t       index      = added[i];
                const size_t offset     = PSQTBuckets * index + j * Tiling::PsqtTileHeight;
                auto*        columnPsqt = reinterpret_cast<const psqt_vec_t*>(
                  &featureTransformer.threatPsqtWeights[offset]);

                for (std::size_t k = 0; k < Tiling::NumPsqtRegs; ++k)
                    psqt[k] = vec_add_psqt_32(psqt[k], columnPsqt[k]);
            }

            for (IndexType k = 0; k < Tiling::NumPsqtRegs; ++k)
                vec_store_psqt(&toTilePsqt[k], psqt[k]);
        }

#else

        toAcc     = fromAcc;
        toPsqtAcc = fromPsqtAcc;

        for (const auto index : removed)
        {
            const IndexType offset = Dimensions * index;

            for (IndexType j = 0; j < Dimensions; ++j)
                toAcc[j] -= featureTransformer.threatWeights[offset + j];

            for (std::size_t k = 0; k < PSQTBuckets; ++k)
                toPsqtAcc[k] -= featureTransformer.threatPsqtWeights[index * PSQTBuckets + k];
        }

        for (const auto index : added)
        {
            const IndexType offset = Dimensions * index;

            for (IndexType j = 0; j < Dimensions; ++j)
                toAcc[j] += featureTransformer.threatWeights[offset + j];

            for (std::size_t k = 0; k < PSQTBuckets; ++k)
                toPsqtAcc[k] += featureTransformer.threatPsqtWeights[index * PSQTBuckets + k];
        }

#endif
    }
};

template<typename FeatureSet>
auto make_accumulator_update_context(Color                               perspective,
                                     const FeatureTransformer&           featureTransformer,
                                     const AccumulatorState<FeatureSet>& accumulatorFrom,
                                     AccumulatorState<FeatureSet>&       accumulatorTo) noexcept {
    return AccumulatorUpdateContext<FeatureSet>{perspective, featureTransformer, accumulatorFrom,
                                                accumulatorTo};
}

template<bool Forward, typename FeatureSet>
void update_accumulator_incremental(Color                               perspective,
                                    const FeatureTransformer&           featureTransformer,
                                    const Square                        ksq,
                                    AccumulatorState<FeatureSet>&       target_state,
                                    const AccumulatorState<FeatureSet>& computed) {

    assert(computed.computed[perspective]);
    assert(!target_state.computed[perspective]);

    typename FeatureSet::IndexList removed, added;
    if constexpr (std::is_same_v<FeatureSet, ThreatFeatureSet>)
    {
        const auto* pfBase   = &featureTransformer.threatWeights[0];
        IndexType   pfStride = FeatureTransformer::OutputDimensions;
        if constexpr (Forward)
            FeatureSet::append_changed_indices(perspective, ksq, target_state.diff, removed, added,
                                               nullptr, false, pfBase, pfStride);
        else
            FeatureSet::append_changed_indices(perspective, ksq, computed.diff, added, removed,
                                               nullptr, false, pfBase, pfStride);
    }
    else
    {
        if constexpr (Forward)
            FeatureSet::append_changed_indices(perspective, ksq, target_state.diff, removed, added);
        else
            FeatureSet::append_changed_indices(perspective, ksq, computed.diff, added, removed);
    }

    auto updateContext =
      make_accumulator_update_context(perspective, featureTransformer, computed, target_state);

    if constexpr (std::is_same_v<FeatureSet, ThreatFeatureSet>)
        updateContext.apply(added, removed);
    else
    {
        [[maybe_unused]] const int addedSize   = added.ssize();
        [[maybe_unused]] const int removedSize = removed.ssize();

        assert(addedSize == 1 || addedSize == 2);
        assert(removedSize == 1 || removedSize == 2);
        assert((Forward && addedSize <= removedSize) || (!Forward && addedSize >= removedSize));

        sf_assume(addedSize == 1 || addedSize == 2);
        sf_assume(removedSize == 1 || removedSize == 2);

        if (!(removedSize == 1 || removedSize == 2) || !(addedSize == 1 || addedSize == 2))
            sf_unreachable();

        if ((Forward && removedSize == 1) || (!Forward && addedSize == 1))
        {
            assert(addedSize == 1 && removedSize == 1);
            updateContext.template apply<Add, Sub>(added[0], removed[0]);
        }
        else if (Forward && addedSize == 1)
        {
            assert(removedSize == 2);
            updateContext.template apply<Add, Sub, Sub>(added[0], removed[0], removed[1]);
        }
        else if (!Forward && removedSize == 1)
        {
            assert(addedSize == 2);
            updateContext.template apply<Add, Add, Sub>(added[0], added[1], removed[0]);
        }
        else
        {
            assert(addedSize == 2 && removedSize == 2);
            updateContext.template apply<Add, Add, Sub, Sub>(added[0], added[1], removed[0],
                                                             removed[1]);
        }
    }
}

Bitboard get_changed_pieces(const std::array<Piece, SQUARE_NB>& oldPieces,
                            const std::array<Piece, SQUARE_NB>& newPieces) {
#if defined(USE_AVX2)
    static_assert(sizeof(Piece) == 1);
    Bitboard sameBB = 0;

    for (int i = 0; i < 64; i += 32)
    {
        const __m256i old_v = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(&oldPieces[i]));
        const __m256i new_v = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(&newPieces[i]));
        const __m256i cmpEqual        = _mm256_cmpeq_epi8(old_v, new_v);
        const std::uint32_t equalMask = _mm256_movemask_epi8(cmpEqual);
        sameBB |= static_cast<Bitboard>(equalMask) << i;
    }
    return ~sameBB;
#elif defined(USE_NEON)
    uint8x16x4_t old_v = vld4q_u8(reinterpret_cast<const uint8_t*>(oldPieces.data()));
    uint8x16x4_t new_v = vld4q_u8(reinterpret_cast<const uint8_t*>(newPieces.data()));
    auto         cmp   = [=](const int i) { return vceqq_u8(old_v.val[i], new_v.val[i]); };

    uint8x16_t cmp0_1 = vsriq_n_u8(cmp(1), cmp(0), 1);
    uint8x16_t cmp2_3 = vsriq_n_u8(cmp(3), cmp(2), 1);
    uint8x16_t merged = vsriq_n_u8(cmp2_3, cmp0_1, 2);
    merged            = vsriq_n_u8(merged, merged, 4);
    uint8x8_t sameBB  = vshrn_n_u16(vreinterpretq_u16_u8(merged), 4);

    return ~vget_lane_u64(vreinterpret_u64_u8(sameBB), 0);
#else
    Bitboard changed = 0;

    for (Square sq = SQUARE_ZERO; sq < SQUARE_NB; ++sq)
        changed |= static_cast<Bitboard>(oldPieces[sq] != newPieces[sq]) << sq;

    return changed;
#endif
}

void update_accumulator_refresh_cache(Color                            perspective,
                                      const FeatureTransformer&        featureTransformer,
                                      const Position&                  pos,
                                      AccumulatorState<PSQFeatureSet>& accumulator,
                                      AccumulatorCaches&               cache) {
    constexpr auto Dimensions = FeatureTransformer::OutputDimensions;

    using Tiling [[maybe_unused]] = SIMDTiling<Dimensions, Dimensions, PSQTBuckets>;

    const Square             ksq   = pos.square<KING>(perspective);
    auto&                    entry = cache[ksq][perspective];
    PSQFeatureSet::IndexList removed, added;

    const Bitboard changedBB = get_changed_pieces(entry.pieces, pos.piece_array());
    Bitboard       removedBB = changedBB & entry.pieceBB;
    Bitboard       addedBB   = changedBB & pos.pieces();

#if defined(USE_AVX512ICL)
    PSQFeatureSet::write_indices(entry.pieces, pos.piece_array(), removedBB, addedBB, perspective,
                                 ksq, removed, added);
#else
    while (removedBB)
    {
        Square sq = pop_lsb(removedBB);
        removed.push_back(PSQFeatureSet::make_index(perspective, sq, entry.pieces[sq], ksq));
    }
    while (addedBB)
    {
        Square sq = pop_lsb(addedBB);
        added.push_back(PSQFeatureSet::make_index(perspective, sq, pos.piece_on(sq), ksq));
    }
#endif

    entry.pieceBB = pos.pieces();
    entry.pieces  = pos.piece_array();

    accumulator.computed[perspective] = true;

#ifdef VECTOR
    vec_t      acc[Tiling::NumRegs];
    psqt_vec_t psqt[Tiling::NumPsqtRegs];

    const auto* weights = &featureTransformer.weights[0];

    for (IndexType j = 0; j < Dimensions / Tiling::TileHeight; ++j)
    {
        auto* accTile =
          reinterpret_cast<vec_t*>(&accumulator.accumulation[perspective][j * Tiling::TileHeight]);
        auto* entryTile = reinterpret_cast<vec_t*>(&entry.accumulation[j * Tiling::TileHeight]);

        for (IndexType k = 0; k < Tiling::NumRegs; ++k)
            acc[k] = entryTile[k];

        for (int i = 0; i < removed.ssize(); ++i)
        {
            size_t       index  = removed[i];
            const size_t offset = Dimensions * index;
            auto*        column = reinterpret_cast<const vec_t*>(&weights[offset]);

            for (IndexType k = 0; k < Tiling::NumRegs; ++k)
                acc[k] = vec_sub_16(acc[k], column[k]);
        }
        for (int i = 0; i < added.ssize(); ++i)
        {
            size_t       index  = added[i];
            const size_t offset = Dimensions * index;
            auto*        column = reinterpret_cast<const vec_t*>(&weights[offset]);

            for (IndexType k = 0; k < Tiling::NumRegs; ++k)
                acc[k] = vec_add_16(acc[k], column[k]);
        }

        for (IndexType k = 0; k < Tiling::NumRegs; k++)
            vec_store(&entryTile[k], acc[k]);
        for (IndexType k = 0; k < Tiling::NumRegs; k++)
            vec_store(&accTile[k], acc[k]);

        weights += Tiling::TileHeight;
    }

    for (IndexType j = 0; j < PSQTBuckets / Tiling::PsqtTileHeight; ++j)
    {
        auto* accTilePsqt = reinterpret_cast<psqt_vec_t*>(
          &accumulator.psqtAccumulation[perspective][j * Tiling::PsqtTileHeight]);
        auto* entryTilePsqt =
          reinterpret_cast<psqt_vec_t*>(&entry.psqtAccumulation[j * Tiling::PsqtTileHeight]);

        for (IndexType k = 0; k < Tiling::NumPsqtRegs; ++k)
            psqt[k] = entryTilePsqt[k];

        for (int i = 0; i < removed.ssize(); ++i)
        {
            size_t       index  = removed[i];
            const size_t offset = PSQTBuckets * index + j * Tiling::PsqtTileHeight;
            auto*        columnPsqt =
              reinterpret_cast<const psqt_vec_t*>(&featureTransformer.psqtWeights[offset]);

            for (std::size_t k = 0; k < Tiling::NumPsqtRegs; ++k)
                psqt[k] = vec_sub_psqt_32(psqt[k], columnPsqt[k]);
        }
        for (int i = 0; i < added.ssize(); ++i)
        {
            size_t       index  = added[i];
            const size_t offset = PSQTBuckets * index + j * Tiling::PsqtTileHeight;
            auto*        columnPsqt =
              reinterpret_cast<const psqt_vec_t*>(&featureTransformer.psqtWeights[offset]);

            for (std::size_t k = 0; k < Tiling::NumPsqtRegs; ++k)
                psqt[k] = vec_add_psqt_32(psqt[k], columnPsqt[k]);
        }

        for (IndexType k = 0; k < Tiling::NumPsqtRegs; ++k)
            vec_store_psqt(&entryTilePsqt[k], psqt[k]);
        for (IndexType k = 0; k < Tiling::NumPsqtRegs; ++k)
            vec_store_psqt(&accTilePsqt[k], psqt[k]);
    }

#else

    for (const auto index : removed)
    {
        const IndexType offset = Dimensions * index;
        for (IndexType j = 0; j < Dimensions; ++j)
            entry.accumulation[j] -= featureTransformer.weights[offset + j];

        for (std::size_t k = 0; k < PSQTBuckets; ++k)
            entry.psqtAccumulation[k] -= featureTransformer.psqtWeights[index * PSQTBuckets + k];
    }
    for (const auto index : added)
    {
        const IndexType offset = Dimensions * index;
        for (IndexType j = 0; j < Dimensions; ++j)
            entry.accumulation[j] += featureTransformer.weights[offset + j];

        for (std::size_t k = 0; k < PSQTBuckets; ++k)
            entry.psqtAccumulation[k] += featureTransformer.psqtWeights[index * PSQTBuckets + k];
    }

    accumulator.accumulation[perspective]     = entry.accumulation;
    accumulator.psqtAccumulation[perspective] = entry.psqtAccumulation;
#endif
}

void update_threats_accumulator_full(Color                               perspective,
                                     const FeatureTransformer&           featureTransformer,
                                     const Position&                     pos,
                                     AccumulatorState<ThreatFeatureSet>& accumulator) {
    constexpr IndexType Dimensions = FeatureTransformer::OutputDimensions;
    using Tiling [[maybe_unused]]  = SIMDTiling<Dimensions, Dimensions, PSQTBuckets>;

    ThreatFeatureSet::IndexList active;
    ThreatFeatureSet::append_active_indices(perspective, pos, active);

    accumulator.computed[perspective] = true;

#ifdef VECTOR
    vec_t      acc[Tiling::NumRegs];
    psqt_vec_t psqt[Tiling::NumPsqtRegs];

    const auto* threatWeights = &featureTransformer.threatWeights[0];

    for (IndexType j = 0; j < Dimensions / Tiling::TileHeight; ++j)
    {
        auto* accTile =
          reinterpret_cast<vec_t*>(&accumulator.accumulation[perspective][j * Tiling::TileHeight]);

        for (IndexType k = 0; k < Tiling::NumRegs; ++k)
            acc[k] = vec_zero();

        int i = 0;

        for (; i < active.ssize(); ++i)
        {
            size_t       index  = active[i];
            const size_t offset = Dimensions * index;
            auto*        column = reinterpret_cast<const vec_i8_t*>(&threatWeights[offset]);

#ifdef USE_NEON
            for (IndexType k = 0; k < Tiling::NumRegs; k += 2)
            {
                acc[k]     = vaddw_s8(acc[k], vget_low_s8(column[k / 2]));
                acc[k + 1] = vaddw_high_s8(acc[k + 1], column[k / 2]);
            }
#else
            for (IndexType k = 0; k < Tiling::NumRegs; ++k)
                acc[k] = vec_add_16(acc[k], vec_convert_8_16(column[k]));
#endif
        }

        for (IndexType k = 0; k < Tiling::NumRegs; k++)
            vec_store(&accTile[k], acc[k]);

        threatWeights += Tiling::TileHeight;
    }

    for (IndexType j = 0; j < PSQTBuckets / Tiling::PsqtTileHeight; ++j)
    {
        auto* accTilePsqt = reinterpret_cast<psqt_vec_t*>(
          &accumulator.psqtAccumulation[perspective][j * Tiling::PsqtTileHeight]);

        for (IndexType k = 0; k < Tiling::NumPsqtRegs; ++k)
            psqt[k] = vec_zero_psqt();

        for (int i = 0; i < active.ssize(); ++i)
        {
            size_t       index  = active[i];
            const size_t offset = PSQTBuckets * index + j * Tiling::PsqtTileHeight;
            auto*        columnPsqt =
              reinterpret_cast<const psqt_vec_t*>(&featureTransformer.threatPsqtWeights[offset]);

            for (std::size_t k = 0; k < Tiling::NumPsqtRegs; ++k)
                psqt[k] = vec_add_psqt_32(psqt[k], columnPsqt[k]);
        }

        for (IndexType k = 0; k < Tiling::NumPsqtRegs; ++k)
            vec_store_psqt(&accTilePsqt[k], psqt[k]);
    }

#else

    for (IndexType j = 0; j < Dimensions; ++j)
        accumulator.accumulation[perspective][j] = 0;

    for (std::size_t k = 0; k < PSQTBuckets; ++k)
        accumulator.psqtAccumulation[perspective][k] = 0;

    for (const auto index : active)
    {
        const IndexType offset = Dimensions * index;

        for (IndexType j = 0; j < Dimensions; ++j)
            accumulator.accumulation[perspective][j] +=
              featureTransformer.threatWeights[offset + j];

        for (std::size_t k = 0; k < PSQTBuckets; ++k)
            accumulator.psqtAccumulation[perspective][k] +=
              featureTransformer.threatPsqtWeights[index * PSQTBuckets + k];
    }

#endif
}

}  // namespace

namespace Features {

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
                    Square to        = pop_lsb(attacks);
                    Square from      = to - attkDir;
                    Piece  attackedP = pos.piece_on(to);
                    IndexType index  = make_index(perspective, attacker, from, to, attackedP, ksq);
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
                    Square    to        = pop_lsb(attacks);
                    Piece     attackedP = pos.piece_on(to);
                    IndexType index     = make_index(perspective, attacker, from, to, attackedP, ksq);
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

}  // namespace Features

}  // namespace Stockfish::Eval::NNUE

#if !defined(UNIVERSAL_BINARY) && !defined(_MSC_VER) && !defined(NNUE_EMBEDDING_OFF)
INCBIN(EmbeddedNNUE, EvalFileDefaultName);
#elif defined(UNIVERSAL_BINARY)
    #define WEAK_SYM __attribute__((weak))
extern const unsigned char gEmbeddedNNUEData[] WEAK_SYM = {
    #embed EvalFileDefaultName
};
extern const unsigned int gEmbeddedNNUESize WEAK_SYM = sizeof(gEmbeddedNNUEData);
#else
const unsigned char gEmbeddedNNUEData[1] = {0x0};
const unsigned int  gEmbeddedNNUESize    = 1;
#endif

namespace Stockfish {

namespace NN = Eval::NNUE;

constexpr int MaxHashMB  = Is64Bit ? 33554432 : 2048;
int           MaxThreads = std::max(1024, 4 * int(get_hardware_concurrency()));

constexpr NumaAutoPolicy DefaultNumaPolicy = BundledL3Policy{32};

extern "C" {
struct ZfishCountPair {
    std::size_t current;
    std::size_t total;
};

const char* zfish_engine_format_numa_info(const unsigned char* config_ptr, std::size_t config_len);
const char* zfish_engine_format_thread_binding(const ZfishCountPair* pairs_ptr, std::size_t pair_count);
const char* zfish_engine_format_thread_allocation(std::size_t          thread_count,
                                                  const unsigned char* binding_ptr,
                                                  std::size_t          binding_len);
const char* zfish_engine_format_network_status(std::size_t          replica_index,
                                               std::uint8_t        status,
                                               const unsigned char* error_ptr,
                                               std::size_t          error_len);
struct ZfishEvalTraceInput {
    const unsigned char* inner_trace_ptr;
    std::size_t          inner_trace_len;
    int                  nnue_internal_value;
    int                  nnue_white_cp;
    int                  final_white_cp;
};

struct ZfishNnueTraceInput {
    std::uint8_t side_to_move_white;
    std::size_t  bucket_count;
    std::size_t  correct_bucket;
    const int*   psqt_cp;
    const int*   positional_cp;
};

const char* zfish_eval_format_trace(ZfishEvalTraceInput input);
const char* zfish_nnue_format_trace(ZfishNnueTraceInput input);
const char* zfish_tbprobe_build_code(const unsigned char* piece_types_ptr, std::size_t piece_count);
int         zfish_tbprobe_dtz_before_zeroing(int wdl);
std::uint64_t zfish_misc_hash_bytes(const unsigned char* data_ptr, std::size_t data_len);
std::size_t   zfish_misc_str_to_size_t(const unsigned char* input_ptr, std::size_t input_len);
const char*   zfish_misc_read_file_to_string(const unsigned char* path_ptr, std::size_t path_len);
const char*   zfish_misc_remove_whitespace(const unsigned char* input_ptr, std::size_t input_len);
bool          zfish_misc_is_whitespace(const unsigned char* input_ptr, std::size_t input_len);
const char*   zfish_misc_get_binary_directory(const unsigned char* argv0_ptr, std::size_t argv0_len);
const char*   zfish_misc_get_working_directory();
const char*   zfish_misc_engine_info_text();
}

namespace {

struct Tie: public std::streambuf {

    Tie(std::streambuf* b, std::streambuf* l) :
        buf(b),
        logBuf(l) {}

    int sync() override { return logBuf->pubsync(), buf->pubsync(); }
    int overflow(int c) override { return log(buf->sputc(char(c)), "<< "); }
    int underflow() override { return buf->sgetc(); }
    int uflow() override { return log(buf->sbumpc(), ">> "); }

    std::streambuf *buf, *logBuf;

    int log(int c, const char* prefix) {
        static int last = '\n';

        if (last == '\n')
            logBuf->sputn(prefix, 3);

        return last = logBuf->sputc(char(c));
    }
};

class Logger {

    Logger() :
        in(std::cin.rdbuf(), file.rdbuf()),
        out(std::cout.rdbuf(), file.rdbuf()) {}
    ~Logger() { start(""); }

    std::ofstream file;
    Tie           in, out;

   public:
    static void start(const std::string& fname) {
        static Logger l;

        if (l.file.is_open())
        {
            std::cout.rdbuf(l.out.buf);
            std::cin.rdbuf(l.in.buf);
            l.file.close();
        }

        if (!fname.empty())
        {
            l.file.open(fname, std::ifstream::out);

            if (!l.file.is_open())
            {
                std::cerr << "Unable to open debug log file " << fname << std::endl;
                exit(EXIT_FAILURE);
            }

            std::cin.rdbuf(&l.in);
            std::cout.rdbuf(&l.out);
        }
    }
};

std::string take_string_and_free_engine_required(const char* rendered) {
    if (!rendered)
        std::abort();

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

int dtz_before_zeroing(WDLScore wdl) { return zfish_tbprobe_dtz_before_zeroing(int(wdl)); }

}  // namespace

void TBTables::add(const std::vector<PieceType>& pieces) {
    const std::string code = take_string_and_free_engine_required(
      zfish_tbprobe_build_code(reinterpret_cast<const unsigned char*>(pieces.data()), pieces.size()));

    TBFile file_dtz(code + ".rtbz");
    if (file_dtz.is_open())
    {
        file_dtz.close();
        foundDTZFiles++;
    }

    TBFile file(code + ".rtbw");

    if (!file.is_open())
        return;

    file.close();
    foundWDLFiles++;

    MaxCardinality = std::max(int(pieces.size()), MaxCardinality);

    wdlTable.emplace_back(code);
    dtzTable.emplace_back(wdlTable.back());

    insert(wdlTable.back().key, &wdlTable.back(), &dtzTable.back());
    insert(wdlTable.back().key2, &wdlTable.back(), &dtzTable.back());
}

namespace Eval::NNUE {

struct NetworkBridgeAccess {
    static const EvalFile& evalFile(const Network& network) { return network.evalFile; }

    static void loadUserNet(Network& network, const std::string& dir, const std::string& evalfilePath) {
        network.load_user_net(dir, evalfilePath);
    }

    static void loadInternal(Network& network) { network.load_internal(); }

    static bool saveNamed(const Network& network,
                          std::ostream&  stream,
                          const std::string& name,
                          const std::string& netDescription) {
        return network.save(stream, name, netDescription);
    }

    static const FeatureTransformer& featureTransformer(const Network& network) {
        return network.featureTransformer;
    }

    static const NetworkArchitecture& layer(const Network& network, std::size_t bucket) {
        return network.network[bucket];
    }
};

namespace Detail {

template<typename T>
bool read_parameters(std::istream& stream, T& reference) {

    std::uint32_t header;
    header = read_little_endian<std::uint32_t>(stream);
    if (!stream || header != T::get_hash_value())
        return false;
    return reference.read_parameters(stream);
}

template<typename T>
bool write_parameters(std::ostream& stream, const T& reference) {

    write_little_endian<std::uint32_t>(stream, T::get_hash_value());
    return reference.write_parameters(stream);
}

}  // namespace Detail

extern "C" {
struct ZfishByteView {
    const unsigned char* ptr;
    std::size_t          len;
};

struct ZfishNetworkSaveResult {
    std::uint8_t saved;
    const char*  message;
};

struct ZfishNetworkVerifyResult {
    std::uint8_t should_exit;
    const char*  message;
};

struct ZfishNetworkEvalOutput {
    int psqt;
    int positional;
};

struct ZfishNetworkVerifyInfo {
    std::size_t size_bytes;
    std::size_t input_dimensions;
    std::size_t transformed_dimensions;
    int         fc0_outputs;
    int         fc1_outputs;
};

struct ZfishNetworkTraceOutput {
    int         psqt[LayerStacks];
    int         positional[LayerStacks];
    std::size_t correct_bucket;
};

void zfish_network_load(void*                network,
                        const unsigned char* root_directory_ptr,
                        std::size_t          root_directory_len,
                        const unsigned char* evalfile_path_ptr,
                        std::size_t          evalfile_path_len);
ZfishNetworkSaveResult zfish_network_save(const void*          network,
                                          std::uint8_t         has_filename,
                                          const unsigned char* filename_ptr,
                                          std::size_t          filename_len);
ZfishNetworkVerifyResult zfish_network_verify(const void*          network,
                                              const unsigned char* evalfile_path_ptr,
                                              std::size_t          evalfile_path_len);
ZfishNetworkEvalOutput zfish_network_evaluate(const void* network,
                                              const void* pos,
                                              void*       accumulator_stack,
                                              void*       cache);
ZfishNetworkTraceOutput zfish_network_trace_evaluate(const void* network,
                                                     const void* pos,
                                                     void*       accumulator_stack,
                                                     void*       cache);

ZfishByteView zfish_network_default_name(const void* network_ptr) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    return {reinterpret_cast<const unsigned char*>(NetworkBridgeAccess::evalFile(network).defaultName.data()),
            NetworkBridgeAccess::evalFile(network).defaultName.size()};
}

ZfishByteView zfish_network_current_name(const void* network_ptr) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    return {reinterpret_cast<const unsigned char*>(NetworkBridgeAccess::evalFile(network).current.data()),
            NetworkBridgeAccess::evalFile(network).current.size()};
}

void zfish_network_load_user_net(void*                network_ptr,
                                 const unsigned char* dir_ptr,
                                 std::size_t          dir_len,
                                 const unsigned char* path_ptr,
                                 std::size_t          path_len) {
    auto& network = *static_cast<Network*>(network_ptr);
    NetworkBridgeAccess::loadUserNet(network,
                                     std::string(reinterpret_cast<const char*>(dir_ptr), dir_len),
                                     std::string(reinterpret_cast<const char*>(path_ptr), path_len));
}

void zfish_network_load_internal(void* network_ptr) {
    auto& network = *static_cast<Network*>(network_ptr);
    NetworkBridgeAccess::loadInternal(network);
}

bool zfish_network_save_named(const void*          network_ptr,
                              const unsigned char* filename_ptr,
                              std::size_t          filename_len) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    const auto  actualFilename = std::string(reinterpret_cast<const char*>(filename_ptr), filename_len);
    std::ofstream stream(actualFilename, std::ios_base::binary);
    const auto& eval_file = NetworkBridgeAccess::evalFile(network);
    return NetworkBridgeAccess::saveNamed(network, stream, eval_file.current, eval_file.netDescription);
}

std::size_t zfish_network_piece_count(const void* pos_ptr) {
    return static_cast<const Position*>(pos_ptr)->count<ALL_PIECES>();
}

ZfishNetworkEvalOutput zfish_network_evaluate_bucket_raw(const void* network_ptr,
                                                         const void* pos_ptr,
                                                         void*       accumulator_stack_ptr,
                                                         void*       cache_ptr,
                                                         std::size_t bucket) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    const auto& pos = *static_cast<const Position*>(pos_ptr);
    auto&       accumulator_stack = *static_cast<AccumulatorStack*>(accumulator_stack_ptr);
    auto&       cache = *static_cast<AccumulatorCaches*>(cache_ptr);

    constexpr uint64_t alignment = CacheLineSize;
    alignas(alignment) TransformedFeatureType transformedFeatures[FeatureTransformer::BufferSize];

    ASSERT_ALIGNED(transformedFeatures, alignment);

    const auto psqt = NetworkBridgeAccess::featureTransformer(network).transform(pos,
                                                                                 accumulator_stack,
                                                                                 cache,
                                                                                 transformedFeatures,
                                                                                 bucket);
    const auto positional = NetworkBridgeAccess::layer(network, bucket).propagate(transformedFeatures);
    return {static_cast<int>(psqt), static_cast<int>(positional)};
}

ZfishNetworkVerifyInfo zfish_network_verify_info(const void* network_ptr) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    const auto& feature_transformer = NetworkBridgeAccess::featureTransformer(network);
    const auto& layer = NetworkBridgeAccess::layer(network, 0);
    return {sizeof(feature_transformer) + sizeof(NetworkArchitecture) * LayerStacks,
            feature_transformer.InputDimensions,
            layer.TransformedFeatureDimensions,
            layer.FC_0_OUTPUTS,
            layer.FC_1_OUTPUTS};
}
}

void Network::load(const std::string& rootDirectory, std::string evalfilePath) {
    zfish_network_load(this,
                       reinterpret_cast<const unsigned char*>(rootDirectory.data()),
                       rootDirectory.size(),
                       reinterpret_cast<const unsigned char*>(evalfilePath.data()),
                       evalfilePath.size());
}

bool Network::save(const std::optional<std::string>& filename) const {
    const std::string filenameText = filename.value_or(std::string{});
    const auto result = zfish_network_save(this,
                                           static_cast<std::uint8_t>(filename.has_value()),
                                           reinterpret_cast<const unsigned char*>(filenameText.data()),
                                           filenameText.size());

    if (result.message)
    {
        sync_cout << result.message << sync_endl;
        std::free(const_cast<char*>(result.message));
    }

    return result.saved != 0;
}

NetworkOutput Network::evaluate(const Position&    pos,
                                AccumulatorStack&  accumulatorStack,
                                AccumulatorCaches& cache) const {
    const auto output = zfish_network_evaluate(this, &pos, &accumulatorStack, &cache);
    return {static_cast<Value>(output.psqt), static_cast<Value>(output.positional)};
}

void Network::verify(std::string                                  evalfilePath,
                     const std::function<void(std::string_view)>& f) const {
    const auto result = zfish_network_verify(this,
                                             reinterpret_cast<const unsigned char*>(evalfilePath.data()),
                                             evalfilePath.size());

    if (f && result.message)
        f(result.message);

    if (result.message)
        std::free(const_cast<char*>(result.message));

    if (result.should_exit)
        exit(EXIT_FAILURE);
}

NnueEvalTrace Network::trace_evaluate(const Position&    pos,
                                      AccumulatorStack&  accumulatorStack,
                                      AccumulatorCaches& cache) const {
    const auto output = zfish_network_trace_evaluate(this, &pos, &accumulatorStack, &cache);

    NnueEvalTrace trace{};
    trace.correctBucket = output.correct_bucket;
    for (IndexType bucket = 0; bucket < LayerStacks; ++bucket)
    {
        trace.psqt[bucket] = output.psqt[bucket];
        trace.positional[bucket] = output.positional[bucket];
    }

    return trace;
}

void Network::load_user_net(const std::string& dir, const std::string& evalfilePath) {
    std::ifstream stream(dir + evalfilePath, std::ios::binary);
    auto          description = load(stream);

    if (description.has_value())
    {
        evalFile.current        = evalfilePath;
        evalFile.netDescription = description.value();
    }
}

void Network::load_internal() {
    class MemoryBuffer: public std::basic_streambuf<char> {
       public:
        MemoryBuffer(char* p, size_t n) {
            setg(p, p, p + n);
            setp(p, p + n);
        }
    };

    MemoryBuffer buffer(const_cast<char*>(reinterpret_cast<const char*>(gEmbeddedNNUEData)),
                        size_t(gEmbeddedNNUESize));

    std::istream stream(&buffer);
    auto         description = load(stream);

    if (description.has_value())
    {
        evalFile.current        = evalFile.defaultName;
        evalFile.netDescription = description.value();
    }
}

void Network::initialize() { initialized = true; }

bool Network::save(std::ostream&      stream,
                   const std::string& name,
                   const std::string& netDescription) const {
    if (name.empty() || name == "None")
        return false;

    return write_parameters(stream, netDescription);
}

std::optional<std::string> Network::load(std::istream& stream) {
    initialize();
    std::string description;

    return read_parameters(stream, description) ? std::make_optional(description) : std::nullopt;
}

std::size_t Network::get_content_hash() const {
    if (!initialized)
        return 0;

    std::size_t h = 0;
    hash_combine(h, featureTransformer);
    for (auto&& layerstack : network)
        hash_combine(h, layerstack);
    hash_combine(h, evalFile);
    return h;
}

bool Network::read_header(std::istream& stream, std::uint32_t* hashValue, std::string* desc) const {
    std::uint32_t version, size;

    version    = read_little_endian<std::uint32_t>(stream);
    *hashValue = read_little_endian<std::uint32_t>(stream);
    size       = read_little_endian<std::uint32_t>(stream);
    if (!stream || version != Version)
        return false;
    desc->resize(size);
    stream.read(&(*desc)[0], size);
    return !stream.fail();
}

bool Network::write_header(std::ostream&      stream,
                           std::uint32_t      hashValue,
                           const std::string& desc) const {
    write_little_endian<std::uint32_t>(stream, Version);
    write_little_endian<std::uint32_t>(stream, hashValue);
    write_little_endian<std::uint32_t>(stream, std::uint32_t(desc.size()));
    stream.write(&desc[0], desc.size());
    return !stream.fail();
}

bool Network::read_parameters(std::istream& stream, std::string& netDescription) {
    std::uint32_t hashValue;
    if (!read_header(stream, &hashValue, &netDescription))
        return false;
    if (hashValue != Network::hash)
        return false;
    if (!Detail::read_parameters(stream, featureTransformer))
        return false;
    for (std::size_t i = 0; i < LayerStacks; ++i)
    {
        if (!Detail::read_parameters(stream, network[i]))
            return false;
    }
    return stream && stream.peek() == std::ios::traits_type::eof();
}

bool Network::write_parameters(std::ostream& stream, const std::string& netDescription) const {
    if (!write_header(stream, Network::hash, netDescription))
        return false;
    if (!Detail::write_parameters(stream, featureTransformer))
        return false;
    for (std::size_t i = 0; i < LayerStacks; ++i)
    {
        if (!Detail::write_parameters(stream, network[i]))
            return false;
    }
    return bool(stream);
}

}  // namespace Eval::NNUE
}

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>

#include "tt.h"
#include "thread.h"

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

    struct ZfishMovegenSnapshot {
        std::uint8_t  side_to_move;
        std::uint64_t pieces_all;
        std::uint64_t pieces_by_color[2];
        std::uint64_t pieces_by_type[8];
        std::uint8_t  king_square[2];
        std::uint8_t  ep_square;
        std::uint8_t  castling_rights;
        std::uint8_t  castling_impeded[16];
        std::uint8_t  castling_rook_square[16];
        std::uint64_t checkers;
        std::uint64_t blockers_for_king[2];
    };

    struct ZfishTtEntry {
        std::uint16_t key16;
        std::uint8_t  depth8;
        std::uint8_t  gen_bound8;
        std::uint16_t move16;
        std::int16_t  value16;
        std::int16_t  eval16;
    };

    struct ZfishTtCluster {
        ZfishTtEntry entry[3];
        char         padding[2];
    };

    struct ZfishTtReadOutput {
        std::uint16_t move16;
        std::int16_t  value16;
        std::int16_t  eval16;
        int           depth;
        std::uint8_t  bound;
        std::uint8_t  is_pv;
    };

    struct ZfishTtProbeOutput {
        std::uint8_t      found;
        std::uint8_t      writer_index;
        ZfishTtReadOutput data;
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
    std::size_t zfish_movegen_generate_captures(const void* pos, std::uint16_t* move_list);
    std::size_t zfish_movegen_generate_quiets(const void* pos, std::uint16_t* move_list);
    std::size_t zfish_movegen_generate_evasions(const void* pos, std::uint16_t* move_list);
    std::size_t zfish_movegen_generate_non_evasions(const void* pos, std::uint16_t* move_list);
    void        zfish_movegen_fill_snapshot(const void* pos_ptr, ZfishMovegenSnapshot* out);
    std::uint64_t zfish_movegen_attacks(std::uint8_t piece_type,
                                                                            std::uint8_t square,
                                                                            std::uint64_t occupied);
    std::uint64_t zfish_movegen_between(std::uint8_t from, std::uint8_t to);
    void zfish_tt_entry_save(ZfishTtEntry* entry,
                                                     std::uint64_t key,
                                                     int           value,
                                                     std::uint8_t  pv,
                                                     std::uint8_t  bound,
                                                     int           depth,
                                                     int           depth_none,
                                                     std::uint16_t move16,
                                                     int           eval,
                                                     std::uint8_t  curr_generation);
    ZfishTtReadOutput zfish_tt_entry_read(const ZfishTtEntry* entry, int depth_none);
    std::uint8_t      zfish_tt_entry_relative_age(const ZfishTtEntry* entry,
                                                                                                std::uint8_t        curr_generation);
    std::uint8_t      zfish_tt_generation_next(std::uint8_t curr_generation);
    int               zfish_tt_hashfull(const ZfishTtCluster* clusters,
                                                                            std::size_t           cluster_count,
                                                                            std::uint8_t          generation,
                                                                            int                   max_age);
    std::size_t       zfish_tt_first_entry_index(std::uint64_t key, std::size_t cluster_count);
    ZfishTtProbeOutput zfish_tt_probe(const ZfishTtCluster* cluster,
                                                                        std::uint64_t         key,
                                                                        std::uint8_t          generation,
                                                                        int                   depth_none);

    struct ZfishThreadSummary {
        std::uint16_t pv0_raw;
        std::uint8_t  score_is_bound;
        std::uint8_t  pv_has_more_than_two;
        int           score;
        int           root_depth;
    };

    std::size_t zfish_thread_next_power_of_two(std::uint64_t count);
    std::size_t zfish_thread_pick_best_thread(const ZfishThreadSummary* summaries,
                                                                                        std::size_t               count);
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

    static_assert(sizeof(Move) == sizeof(std::uint16_t));

    extern "C" void zfish_movegen_fill_snapshot(const void* pos_ptr, ZfishMovegenSnapshot* out) {
        const auto& pos = *static_cast<const Position*>(pos_ptr);

        *out                     = {};
        out->side_to_move        = static_cast<std::uint8_t>(pos.side_to_move());
        out->pieces_all          = pos.pieces();
        out->pieces_by_color[WHITE] = pos.pieces(WHITE);
        out->pieces_by_color[BLACK] = pos.pieces(BLACK);
        out->pieces_by_type[ALL_PIECES] = pos.pieces();
        out->pieces_by_type[PAWN]   = pos.pieces(PAWN);
        out->pieces_by_type[KNIGHT] = pos.pieces(KNIGHT);
        out->pieces_by_type[BISHOP] = pos.pieces(BISHOP);
        out->pieces_by_type[ROOK]   = pos.pieces(ROOK);
        out->pieces_by_type[QUEEN]  = pos.pieces(QUEEN);
        out->pieces_by_type[KING]   = pos.pieces(KING);
        out->king_square[WHITE]     = static_cast<std::uint8_t>(pos.square<KING>(WHITE));
        out->king_square[BLACK]     = static_cast<std::uint8_t>(pos.square<KING>(BLACK));
        out->ep_square              = static_cast<std::uint8_t>(pos.ep_square());
        out->checkers               = pos.checkers();
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

    extern "C" std::uint64_t zfish_movegen_attacks(std::uint8_t piece_type,
                                                     std::uint8_t square,
                                                     std::uint64_t occupied) {
        return attacks_bb(static_cast<PieceType>(piece_type), static_cast<Square>(square), occupied);
    }

    extern "C" std::uint64_t zfish_movegen_between(std::uint8_t from, std::uint8_t to) {
        return between_bb(static_cast<Square>(from), static_cast<Square>(to));
    }

    template<>
    Move* generate<CAPTURES>(const Position& pos, Move* moveList) {
            const auto count = zfish_movegen_generate_captures(
                &pos, reinterpret_cast<std::uint16_t*>(moveList));
            return moveList + count;
    }

    template<>
    Move* generate<QUIETS>(const Position& pos, Move* moveList) {
            const auto count = zfish_movegen_generate_quiets(&pos, reinterpret_cast<std::uint16_t*>(moveList));
            return moveList + count;
    }

    template<>
    Move* generate<EVASIONS>(const Position& pos, Move* moveList) {
            const auto count = zfish_movegen_generate_evasions(
                &pos, reinterpret_cast<std::uint16_t*>(moveList));
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

        static constexpr int ClusterSize = 3;

        struct TTEntry {
            TTData read() const {
                const auto output = zfish_tt_entry_read(reinterpret_cast<const ZfishTtEntry*>(this), DEPTH_NONE);
                return TTData{Move(output.move16), Value(output.value16), Value(output.eval16),
                                Depth(output.depth), Bound(output.bound), output.is_pv != 0};
            }

            bool is_occupied() const { return bool(depth8); }
            void save(Key k, Value v, bool pv, Bound b, Depth d, Move m, Value ev, std::uint8_t curr_generation);
            std::uint8_t relative_age(std::uint8_t curr_generation) const;

             private:
            friend class TranspositionTable;

            std::uint16_t key16;
            std::uint8_t  depth8;
            std::uint8_t  gen_bound8;
            std::uint16_t move16;
            std::int16_t  value16;
            std::int16_t  eval16;
        };

        void TTEntry::save(
            Key k, Value v, bool pv, Bound b, Depth d, Move m, Value ev, std::uint8_t curr_generation) {
            zfish_tt_entry_save(reinterpret_cast<ZfishTtEntry*>(this), k, v,
                                static_cast<std::uint8_t>(pv ? 1 : 0), static_cast<std::uint8_t>(b), d,
                                DEPTH_NONE, m.raw(), ev, curr_generation);
        }

        std::uint8_t TTEntry::relative_age(std::uint8_t curr_generation) const {
            return zfish_tt_entry_relative_age(reinterpret_cast<const ZfishTtEntry*>(this), curr_generation);
        }

        TTWriter::TTWriter(TTEntry* tte) :
            entry(tte) {}

        void TTWriter::write(
            Key k, Value v, bool pv, Bound b, Depth d, Move m, Value ev, std::uint8_t curr_generation) {
            entry->save(k, v, pv, b, d, m, ev, curr_generation);
        }

        struct Cluster {
            TTEntry entry[ClusterSize];
            char    padding[2];
        };

        static_assert(sizeof(Cluster) == 32, "Suboptimal Cluster size");

        void TranspositionTable::resize(size_t mbSize, ThreadPool& threads) {
            aligned_large_pages_free(table);

            clusterCount = mbSize * 1024 * 1024 / sizeof(Cluster);

            table = static_cast<Cluster*>(aligned_large_pages_alloc(clusterCount * sizeof(Cluster)));

            if (!table)
            {
                std::cerr << "Failed to allocate " << mbSize << "MB for transposition table." << std::endl;
                exit(EXIT_FAILURE);
            }

            clear(threads);
        }

        void TranspositionTable::clear(ThreadPool& threads) {
            generation8              = 0;
            const size_t threadCount = threads.num_threads();

            for (size_t i = 0; i < threadCount; ++i)
            {
                threads.run_on_thread(i, [this, i, threadCount]() {
                    const size_t stride = clusterCount / threadCount;
                    const size_t start  = stride * i;
                    const size_t len    = i + 1 != threadCount ? stride : clusterCount - start;

                    std::memset(&table[start], 0, len * sizeof(Cluster));
                });
            }

            for (size_t i = 0; i < threadCount; ++i)
                threads.wait_on_thread(i);
        }

        int TranspositionTable::hashfull(int maxAge) const {
            return zfish_tt_hashfull(reinterpret_cast<const ZfishTtCluster*>(table), clusterCount,
                                     generation8, maxAge);
        }

        void TranspositionTable::new_search() { generation8 = zfish_tt_generation_next(generation8); }

        std::uint8_t TranspositionTable::generation() const { return generation8; }

        std::tuple<bool, TTData, TTWriter> TranspositionTable::probe(const Key key) const {
            TTEntry* const tte = first_entry(key);

            const auto output = zfish_tt_probe(reinterpret_cast<const ZfishTtCluster*>(
                                                 reinterpret_cast<const Cluster*>(tte)),
                                                 key, generation8, DEPTH_NONE);

            if (output.found != 0)
            {
                const auto& data = output.data;
                return {true,
                        TTData{Move(data.move16), Value(data.value16), Value(data.eval16), Depth(data.depth),
                                 Bound(data.bound), data.is_pv != 0},
                        TTWriter(&tte[output.writer_index])};
            }

            return {false, TTData{Move::none(), VALUE_NONE, VALUE_NONE, DEPTH_NONE, BOUND_NONE, false},
                    TTWriter(&tte[output.writer_index])};
        }

        TTEntry* TranspositionTable::first_entry(const Key key) const {
            const auto cluster_index = zfish_tt_first_entry_index(key, clusterCount);
            return &table[cluster_index].entry[0];
        }

        Thread::Thread(Search::SharedState&                    sharedState,
                                     std::unique_ptr<Search::ISearchManager> sm,
                                     size_t                                  n,
                                     size_t                                  numaN,
                                     size_t                                  totalNumaCount,
                                     OptionalThreadToNumaNodeBinder          binder) :
                idx(n),
                idxInNuma(numaN),
                totalNuma(totalNumaCount),
                nthreads(sharedState.options["Threads"]),
                stdThread(&Thread::idle_loop, this) {

            wait_for_search_finished();

            run_custom_job([this, &binder, &sharedState, &sm, n]() {
                this->numaAccessToken = binder();
                this->worker          = make_unique_large_page<Search::Worker>(
                    sharedState, std::move(sm), n, idxInNuma, totalNuma, this->numaAccessToken);
            });

            wait_for_search_finished();
        }

        Thread::~Thread() {

            assert(!searching);

            exit = true;
            start_searching();
            stdThread.join();
        }

        void Thread::start_searching() {
            assert(worker != nullptr);
            run_custom_job([this]() { worker->start_searching(); });
        }

        void Thread::clear_worker() {
            assert(worker != nullptr);
            run_custom_job([this]() { worker->clear(); });
        }

        void Thread::wait_for_search_finished() {

            std::unique_lock<std::mutex> lk(mutex);
            cv.wait(lk, [&] { return !searching; });
        }

        void Thread::run_custom_job(std::function<void()> f) {
            {
                std::unique_lock<std::mutex> lk(mutex);
                cv.wait(lk, [&] { return !searching; });
                jobFunc   = std::move(f);
                searching = true;
            }
            cv.notify_one();
        }

        void Thread::ensure_network_replicated() { worker->ensure_network_replicated(); }

        void Thread::idle_loop() {
            while (true)
            {
                std::unique_lock<std::mutex> lk(mutex);
                searching = false;
                cv.notify_one();
                cv.wait(lk, [&] { return searching; });

                if (exit)
                        return;

                std::function<void()> job = std::move(jobFunc);
                jobFunc                   = nullptr;

                lk.unlock();

                if (job)
                        job();
            }
        }

        Search::SearchManager* ThreadPool::main_manager() { return main_thread()->worker->main_manager(); }

        uint64_t ThreadPool::nodes_searched() const { return accumulate(&Search::Worker::nodes); }
        uint64_t ThreadPool::tb_hits() const { return accumulate(&Search::Worker::tbHits); }

        static size_t next_power_of_two(uint64_t count) {
            return zfish_thread_next_power_of_two(count);
        }

        void ThreadPool::set(const NumaConfig&                           numaConfig,
                                                 Search::SharedState                         sharedState,
                                                 const Search::SearchManager::UpdateContext& updateContext) {

            if (threads.size() > 0)
            {
                main_thread()->wait_for_search_finished();

                threads.clear();

                boundThreadToNumaNode.clear();
            }

            const size_t requested = sharedState.options["Threads"];

            if (requested > 0)
            {
                const std::string numaPolicy(sharedState.options["NumaPolicy"]);
                const bool        doBindThreads = [&]() {
                    if (numaPolicy == "none")
                            return false;

                    if (numaPolicy == "auto")
                            return numaConfig.suggests_binding_threads(requested);

                    return true;
                }();

                std::map<NumaIndex, size_t> counts;
                boundThreadToNumaNode = doBindThreads
                                                                ? numaConfig.distribute_threads_among_numa_nodes(requested)
                                                                : std::vector<NumaIndex>{};

                if (boundThreadToNumaNode.empty())
                        counts[0] = requested;
                else
                {
                    for (size_t i = 0; i < boundThreadToNumaNode.size(); ++i)
                            counts[boundThreadToNumaNode[i]]++;
                }

                sharedState.sharedHistories.clear();
                for (auto pair : counts)
                {
                    NumaIndex numaIndex = pair.first;
                    uint64_t  count     = pair.second;
                    auto      f         = [&]() {
                        sharedState.sharedHistories.try_emplace(numaIndex, next_power_of_two(count));
                    };
                    if (doBindThreads)
                            numaConfig.execute_on_numa_node(numaIndex, f);
                    else
                            f();
                }

                auto threadsPerNode = counts;
                counts.clear();

                while (threads.size() < requested)
                {
                    const size_t    threadId      = threads.size();
                    const NumaIndex numaId        = doBindThreads ? boundThreadToNumaNode[threadId] : 0;
                    auto            create_thread = [&]() {
                        auto manager = threadId == 0
                                                                            ? std::unique_ptr<Search::ISearchManager>(
                                                             std::make_unique<Search::SearchManager>(updateContext))
                                                                            : std::make_unique<Search::NullSearchManager>();

                        auto binder = doBindThreads ? OptionalThreadToNumaNodeBinder(numaConfig, numaId)
                                                                                                     : OptionalThreadToNumaNodeBinder(numaId);

                        threads.emplace_back(std::make_unique<Thread>(sharedState, std::move(manager),
                                                                                                                                         threadId, counts[numaId]++,
                                                                                                                                         threadsPerNode[numaId], binder));
                    };

                    if (doBindThreads)
                            numaConfig.execute_on_numa_node(numaId, create_thread);
                    else
                            create_thread();
                }

                clear();

                main_thread()->wait_for_search_finished();
            }
        }

        void ThreadPool::clear() {
            if (threads.size() == 0)
                    return;

            for (auto&& th : threads)
                    th->clear_worker();

            for (auto&& th : threads)
                    th->wait_for_search_finished();

            main_manager()->bestPreviousAverageScore = VALUE_INFINITE;
            main_manager()->previousTimeReduction    = 0.85;

            main_manager()->callsCnt           = 0;
            main_manager()->bestPreviousScore  = VALUE_INFINITE;
            main_manager()->originalTimeAdjust = -1;
            main_manager()->tm.clear();
        }

        void ThreadPool::run_on_thread(size_t threadId, std::function<void()> f) {
            assert(threads.size() > threadId);
            threads[threadId]->run_custom_job(std::move(f));
        }

        void ThreadPool::wait_on_thread(size_t threadId) {
            assert(threads.size() > threadId);
            threads[threadId]->wait_for_search_finished();
        }

        size_t ThreadPool::num_threads() const { return threads.size(); }

        void ThreadPool::start_thinking(const OptionsMap&  options,
                                                                        Position&          pos,
                                                                        StateListPtr&      states,
                                                                        Search::LimitsType limits) {

            main_thread()->wait_for_search_finished();

            main_manager()->stopOnPonderhit = stop = false;
            main_manager()->ponder                 = limits.ponderMode;

            increaseDepth = true;

            Search::RootMoves rootMoves;
            const auto        legalmoves = MoveList<LEGAL>(pos);

            for (const auto& uciMove : limits.searchmoves)
            {
                auto move = UCIEngine::to_move(pos, uciMove);

                if (std::find(legalmoves.begin(), legalmoves.end(), move) != legalmoves.end())
                        rootMoves.emplace_back(move);
            }

            if (rootMoves.empty())
                    for (const auto& m : legalmoves)
                            rootMoves.emplace_back(m);

            Tablebases::Config tbConfig = Tablebases::rank_root_moves(options, pos, rootMoves);

            assert(states.get() || setupStates.get());

            if (states.get())
                    setupStates = std::move(states);

            for (auto&& th : threads)
            {
                th->run_custom_job([&]() {
                    th->worker->limits = limits;
                    th->worker->nodes = th->worker->tbHits = th->worker->bestMoveChanges = 0;
                    th->worker->nmpMinPly                                                = 0;
                    th->worker->rootDepth                                                = 0;
                    th->worker->rootMoves                                                = rootMoves;
                    th->worker->rootPos.set(pos.fen(), pos.is_chess960(), &th->worker->rootState);
                    th->worker->rootState = setupStates->back();
                    th->worker->tbConfig  = tbConfig;
                });
            }

            for (auto&& th : threads)
                    th->wait_for_search_finished();

            main_thread()->start_searching();
        }

        Thread* ThreadPool::get_best_thread() const {

            ZfishThreadSummary summaries[1024]{};
            const auto count = threads.size();

            for (std::size_t i = 0; i < count; ++i)
            {
                const auto& rootMove = threads[i]->worker->rootMoves[0];
                summaries[i].pv0_raw = rootMove.pv[0].raw();
                summaries[i].score_is_bound = rootMove.score_is_bound();
                summaries[i].pv_has_more_than_two = rootMove.pv.size() > 2;
                summaries[i].score = rootMove.score;
                summaries[i].root_depth = int(threads[i]->worker->rootDepth);
            }

            return threads[zfish_thread_pick_best_thread(summaries, count)].get();
        }

        void ThreadPool::start_searching() {

            for (auto&& th : threads)
                    if (th != threads.front())
                            th->start_searching();
        }

        void ThreadPool::wait_for_search_finished() const {

            for (auto&& th : threads)
                    if (th != threads.front())
                            th->wait_for_search_finished();
        }

        std::vector<size_t> ThreadPool::get_bound_thread_count_by_numa_node() const {
            std::vector<size_t> counts;

            if (!boundThreadToNumaNode.empty())
            {
                NumaIndex highestNumaNode = 0;
                for (NumaIndex n : boundThreadToNumaNode)
                        if (n > highestNumaNode)
                                highestNumaNode = n;

                counts.resize(highestNumaNode + 1, 0);

                for (NumaIndex n : boundThreadToNumaNode)
                        counts[n] += 1;
            }

            return counts;
        }

        void ThreadPool::ensure_network_replicated() {
            for (auto&& th : threads)
                    th->ensure_network_replicated();
        }

    }  // namespace Stockfish

namespace Stockfish {

std::string build_nnue_trace(Stockfish::Position&                     pos,
                             const Stockfish::Eval::NNUE::Network&     network,
                             Stockfish::Eval::NNUE::AccumulatorCaches& caches);

constexpr std::string_view version = "dev";

std::string engine_version_info() {
    std::stringstream ss;
    ss << "Stockfish " << version << std::setfill('0');

    if constexpr (version == "dev")
    {
        ss << "-";
#ifdef GIT_DATE
        ss << stringify(GIT_DATE);
#else
        constexpr std::string_view months("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec");

        std::string       month, day, year;
        std::stringstream date(__DATE__);

        date >> month >> day >> year;
        ss << year << std::setw(2) << std::setfill('0') << (1 + months.find(month) / 4)
           << std::setw(2) << std::setfill('0') << day;
#endif

        ss << "-";

#ifdef GIT_SHA
        ss << stringify(GIT_SHA);
#else
        ss << "nogit";
#endif
    }

    return ss.str();
}

std::string engine_info(bool to_uci) {
    return engine_version_info() + (to_uci ? "\nid author " : " by ")
         + "the Stockfish developers (see AUTHORS file)";
}

extern "C" const char* zfish_misc_engine_info_text() {
    const auto value = engine_info();
    auto*      buffer = static_cast<char*>(std::malloc(value.size() + 1));
    if (!buffer)
        return nullptr;

    std::memcpy(buffer, value.c_str(), value.size() + 1);
    return buffer;
}

std::string compiler_info() {

#define make_version_string(major, minor, patch) \
    stringify(major) "." stringify(minor) "." stringify(patch)

    std::string compiler = "\nCompiled by                : ";

#if defined(__INTEL_LLVM_COMPILER)
    compiler += "ICX ";
    compiler += stringify(__INTEL_LLVM_COMPILER);
#elif defined(__clang__)
    compiler += "clang++ ";
    compiler += make_version_string(__clang_major__, __clang_minor__, __clang_patchlevel__);
#elif _MSC_VER
    compiler += "MSVC ";
    compiler += "(version ";
    compiler += stringify(_MSC_FULL_VER) "." stringify(_MSC_BUILD);
    compiler += ")";
#elif defined(__e2k__) && defined(__LCC__)
    #define dot_ver2(n) \
        compiler += char('.'); \
        compiler += char('0' + (n) / 10); \
        compiler += char('0' + (n) % 10);

    compiler += "MCST LCC ";
    compiler += "(version ";
    compiler += std::to_string(__LCC__ / 100);
    dot_ver2(__LCC__ % 100) dot_ver2(__LCC_MINOR__) compiler += ")";
#elif __GNUC__
    compiler += "g++ (GNUC) ";
    compiler += make_version_string(__GNUC__, __GNUC_MINOR__, __GNUC_PATCHLEVEL__);
#else
    compiler += "Unknown compiler ";
    compiler += "(unknown version)";
#endif

#if defined(__APPLE__)
    compiler += " on Apple";
#elif defined(__CYGWIN__)
    compiler += " on Cygwin";
#elif defined(__MINGW64__)
    compiler += " on MinGW64";
#elif defined(__MINGW32__)
    compiler += " on MinGW32";
#elif defined(__ANDROID__)
    compiler += " on Android";
#elif defined(__linux__)
    compiler += " on Linux";
#elif defined(_WIN64)
    compiler += " on Microsoft Windows 64-bit";
#elif defined(_WIN32)
    compiler += " on Microsoft Windows 32-bit";
#else
    compiler += " on unknown system";
#endif

    compiler += "\nCompilation architecture   : ";
#if defined(ARCH)
    compiler += stringify(ARCH);
#else
    compiler += "(undefined architecture)";
#endif

    compiler += "\nCompilation settings       : ";
    compiler += (Is64Bit ? "64bit" : "32bit");
#if defined(USE_AVX512ICL)
    compiler += " AVX512ICL";
#endif
#if defined(USE_VNNI)
    compiler += " VNNI";
#endif
#if defined(USE_AVX512)
    compiler += " AVX512";
#endif
    compiler += (HasPext ? " BMI2" : "");
#if defined(USE_AVX2)
    compiler += " AVX2";
#endif
#if defined(USE_SSE41)
    compiler += " SSE41";
#endif
#if defined(USE_SSSE3)
    compiler += " SSSE3";
#endif
#if defined(USE_SSE2)
    compiler += " SSE2";
#endif
#if defined(USE_NEON_DOTPROD)
    compiler += " NEON_DOTPROD";
#elif defined(USE_NEON)
    compiler += " NEON";
#endif
    compiler += (HasPopCnt ? " POPCNT" : "");

#if !defined(NDEBUG)
    compiler += " DEBUG";
#endif

    compiler += "\nCompiler __VERSION__ macro : ";
#ifdef __VERSION__
    compiler += __VERSION__;
#else
    compiler += "(undefined macro)";
#endif

    compiler += "\n";

    return compiler;
}

std::vector<std::pair<size_t, size_t>> Engine::get_bound_thread_count_by_numa_node() const {
    auto                                   counts = threads.get_bound_thread_count_by_numa_node();
    const NumaConfig&                      cfg    = numaContext.get_numa_config();
    std::vector<std::pair<size_t, size_t>> ratios;
    NumaIndex                              n = 0;
    for (; n < counts.size(); ++n)
        ratios.emplace_back(counts[n], cfg.num_cpus_in_numa_node(n));
    if (!counts.empty())
        for (; n < cfg.num_numa_nodes(); ++n)
            ratios.emplace_back(0, cfg.num_cpus_in_numa_node(n));
    return ratios;
}

std::string Engine::get_numa_config_as_string() const {
    return numaContext.get_numa_config().to_string();
}

std::string Engine::numa_config_information_as_string() const {
    auto cfgStr = get_numa_config_as_string();
    const char* rendered = zfish_engine_format_numa_info(
      reinterpret_cast<const unsigned char*>(cfgStr.data()), cfgStr.size());
    if (!rendered)
        std::abort();
    std::string result(rendered);
    std::free(const_cast<char*>(rendered));
    return result;
}

std::string Engine::thread_binding_information_as_string() const {
    auto boundThreadsByNode = get_bound_thread_count_by_numa_node();
    if (boundThreadsByNode.empty())
        return {};

    std::vector<ZfishCountPair> pairs;
    pairs.reserve(boundThreadsByNode.size());
    for (auto&& [current, total] : boundThreadsByNode)
        pairs.push_back(ZfishCountPair{current, total});

    const char* rendered = zfish_engine_format_thread_binding(pairs.data(), pairs.size());
    if (!rendered)
        std::abort();
    std::string result(rendered);
    std::free(const_cast<char*>(rendered));
    return result;
}

std::string Engine::thread_allocation_information_as_string() const {
    const size_t threadsSize = threads.size();
    const auto   binding = thread_binding_information_as_string();
    const char*  rendered = zfish_engine_format_thread_allocation(
      threadsSize, reinterpret_cast<const unsigned char*>(binding.data()), binding.size());
    if (!rendered)
        std::abort();
    std::string result(rendered);
    std::free(const_cast<char*>(rendered));
    return result;
}

const OptionsMap& Engine::get_options() const { return options; }
OptionsMap&       Engine::get_options() { return options; }

std::string Engine::fen() const { return pos.fen(); }

void Engine::flip() { pos.flip(); }

std::string Engine::visualize() const {
    std::stringstream ss;
    ss << pos;
    return ss.str();
}

int Engine::get_hashfull(int maxAge) const { return tt.hashfull(maxAge); }

void Engine::verify_network() const {
    network->verify(options["EvalFile"], onVerifyNetwork);

    auto statuses = network.get_status_and_errors();
    for (size_t i = 0; i < statuses.size(); ++i)
    {
        const auto [status, error] = statuses[i];
        const std::string error_text = error.value_or(std::string{});
        const char* message = zfish_engine_format_network_status(
          i + 1,
          static_cast<std::uint8_t>(status),
          reinterpret_cast<const unsigned char*>(error_text.data()),
          error_text.size());
        if (!message)
            std::abort();
        onVerifyNetwork(message);
        std::free(const_cast<char*>(message));
    }
}

std::unique_ptr<Eval::NNUE::Network> Engine::get_default_network() const {

    auto network_ = std::make_unique<NN::Network>(NN::EvalFile{EvalFileDefaultName, "None", ""});

    network_->load(binaryDirectory, "");

    return network_;
}

void Engine::load_network(const std::string& file) {
    network.modify_and_replicate(
      [this, &file](NN::Network& network_) { network_.load(binaryDirectory, file); });
    threads.clear();
    threads.ensure_network_replicated();
}

void Engine::save_network(const std::pair<std::optional<std::string>, std::string> file) {
    network.modify_and_replicate([&file](NN::Network& network_) { network_.save(file.first); });
}

void Engine::trace_eval() const {
    StateListPtr trace_states(new std::deque<StateInfo>(1));
    Position     p;
    p.set(pos.fen(), options["UCI_Chess960"], &trace_states->back());

    verify_network();

    sync_cout << "\n" << Eval::trace(p, *network) << sync_endl;
}

void Engine::set_numa_config_from_option(const std::string& o) {
    if (o == "auto" || o == "system")
    {
        numaContext.set_numa_config(NumaConfig::from_system(DefaultNumaPolicy));
    }
    else if (o == "hardware")
    {
        numaContext.set_numa_config(NumaConfig::from_system(DefaultNumaPolicy, false));
    }
    else if (o == "none")
    {
        numaContext.set_numa_config(NumaConfig{});
    }
    else
    {
        numaContext.set_numa_config(NumaConfig::from_string(o));
    }

    resize_threads();
    threads.ensure_network_replicated();
}

void Engine::resize_threads() {
    threads.wait_for_search_finished();
    threads.set(numaContext.get_numa_config(), {options, threads, tt, sharedHists, network},
                updateContext);

    set_tt_size(options["Hash"]);
    threads.ensure_network_replicated();
}

void Engine::set_tt_size(size_t mb) {
    wait_for_search_finished();
    tt.resize(mb, threads);
}

void Engine::set_ponderhit(bool b) { threads.main_manager()->ponder = b; }

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

std::string build_nnue_trace(Stockfish::Position&                     pos,
                             const Stockfish::Eval::NNUE::Network&     network,
                             Stockfish::Eval::NNUE::AccumulatorCaches& caches) {
    auto accumulators = std::make_unique<Stockfish::Eval::NNUE::AccumulatorStack>();
    accumulators->reset();

    const auto trace = network.trace_evaluate(pos, *accumulators, caches);

    int psqt_cp[Stockfish::Eval::NNUE::LayerStacks];
    int positional_cp[Stockfish::Eval::NNUE::LayerStacks];
    for (std::size_t bucket = 0; bucket < Stockfish::Eval::NNUE::LayerStacks; ++bucket)
    {
        psqt_cp[bucket] = Stockfish::UCIEngine::to_cp(trace.psqt[bucket], pos);
        positional_cp[bucket] = Stockfish::UCIEngine::to_cp(trace.positional[bucket], pos);
    }

    const ZfishNnueTraceInput input = {
      .side_to_move_white = static_cast<std::uint8_t>(pos.side_to_move() == Stockfish::WHITE ? 1 : 0),
      .bucket_count       = Stockfish::Eval::NNUE::LayerStacks,
      .correct_bucket     = trace.correctBucket,
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

constexpr int MaxDebugSlots = 32;

template<size_t N>
struct DebugInfo {
    std::array<std::atomic<int64_t>, N> data = {0};

    [[nodiscard]] constexpr std::atomic<int64_t>& operator[](size_t index) {
        assert(index < N);
        return data[index];
    }

    constexpr DebugInfo& operator=(const DebugInfo& other) {
        for (size_t i = 0; i < N; i++)
            data[i].store(other.data[i].load());
        return *this;
    }
};

struct DebugExtremes: public DebugInfo<3> {
    DebugExtremes() {
        data[1] = std::numeric_limits<int64_t>::min();
        data[2] = std::numeric_limits<int64_t>::max();
    }
};

std::array<DebugInfo<2>, MaxDebugSlots>  hit;
std::array<DebugInfo<2>, MaxDebugSlots>  mean;
std::array<DebugInfo<3>, MaxDebugSlots>  stdev;
std::array<DebugInfo<6>, MaxDebugSlots>  correl;
std::array<DebugExtremes, MaxDebugSlots> extremes;

void dbg_hit_on(bool cond, int slot) {
    ++hit.at(slot)[0];
    if (cond)
        ++hit.at(slot)[1];
}

void dbg_mean_of(int64_t value, int slot) {
    ++mean.at(slot)[0];
    mean.at(slot)[1] += value;
}

void dbg_stdev_of(int64_t value, int slot) {
    ++stdev.at(slot)[0];
    stdev.at(slot)[1] += value;
    stdev.at(slot)[2] += value * value;
}

void dbg_extremes_of(int64_t value, int slot) {
    ++extremes.at(slot)[0];

    int64_t current_max = extremes.at(slot)[1].load();
    while (current_max < value && !extremes.at(slot)[1].compare_exchange_weak(current_max, value))
    {}

    int64_t current_min = extremes.at(slot)[2].load();
    while (current_min > value && !extremes.at(slot)[2].compare_exchange_weak(current_min, value))
    {}
}

void dbg_correl_of(int64_t value1, int64_t value2, int slot) {
    ++correl.at(slot)[0];
    correl.at(slot)[1] += value1;
    correl.at(slot)[2] += value1 * value1;
    correl.at(slot)[3] += value2;
    correl.at(slot)[4] += value2 * value2;
    correl.at(slot)[5] += value1 * value2;
}

void dbg_print() {
    int64_t n;
    auto    E   = [&n](int64_t x) { return double(x) / n; };
    auto    sqr = [](double x) { return x * x; };

    for (int i = 0; i < MaxDebugSlots; ++i)
        if ((n = hit[i][0]))
            std::cerr << "Hit #" << i << ": Total " << n << " Hits " << hit[i][1]
                      << " Hit Rate (%) " << 100.0 * E(hit[i][1]) << std::endl;

    for (int i = 0; i < MaxDebugSlots; ++i)
        if ((n = mean[i][0]))
            std::cerr << "Mean #" << i << ": Total " << n << " Mean " << E(mean[i][1])
                      << std::endl;

    for (int i = 0; i < MaxDebugSlots; ++i)
        if ((n = stdev[i][0]))
        {
            double r = sqrt(E(stdev[i][2]) - sqr(E(stdev[i][1])));
            std::cerr << "Stdev #" << i << ": Total " << n << " Stdev " << r << std::endl;
        }

    for (int i = 0; i < MaxDebugSlots; ++i)
        if ((n = extremes[i][0]))
            std::cerr << "Extremity #" << i << ": Total " << n << " Min " << extremes[i][2]
                      << " Max " << extremes[i][1] << std::endl;

    for (int i = 0; i < MaxDebugSlots; ++i)
        if ((n = correl[i][0]))
        {
            double r = (E(correl[i][5]) - E(correl[i][1]) * E(correl[i][3]))
                     / (sqrt(E(correl[i][2]) - sqr(E(correl[i][1])))
                        * sqrt(E(correl[i][4]) - sqr(E(correl[i][3]))));
            std::cerr << "Correl. #" << i << ": Total " << n << " Coefficient " << r << std::endl;
        }
}

void dbg_clear() {
    hit.fill({});
    mean.fill({});
    stdev.fill({});
    correl.fill({});
    extremes.fill({});
}

std::string take_string_and_free_engine_required_uci(const char* rendered) {
    if (!rendered)
        std::abort();

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

std::uint64_t hash_bytes(const char* data, size_t size) {
    return zfish_misc_hash_bytes(reinterpret_cast<const unsigned char*>(data), size);
}

void start_logger(const std::string& fname) { Logger::start(fname); }

size_t str_to_size_t(const std::string& s) {
    return zfish_misc_str_to_size_t(reinterpret_cast<const unsigned char*>(s.data()), s.size());
}

std::optional<std::string> read_file_to_string(const std::string& path) {
    const char* rendered =
      zfish_misc_read_file_to_string(reinterpret_cast<const unsigned char*>(path.data()), path.size());
    if (!rendered)
        return std::nullopt;

    return take_string_and_free_engine_required_uci(rendered);
}

void remove_whitespace(std::string& s) {
    const char* rendered =
      zfish_misc_remove_whitespace(reinterpret_cast<const unsigned char*>(s.data()), s.size());
        s = take_string_and_free_engine_required_uci(rendered);
}

bool is_whitespace(std::string_view s) {
    return zfish_misc_is_whitespace(reinterpret_cast<const unsigned char*>(s.data()), s.size());
}

std::string CommandLine::get_binary_directory(std::string argv0) {
    const char* rendered = zfish_misc_get_binary_directory(
      reinterpret_cast<const unsigned char*>(argv0.data()), argv0.size());
    return take_string_and_free_engine_required_uci(rendered);
}

std::string CommandLine::get_working_directory() {
    return take_string_and_free_engine_required_uci(zfish_misc_get_working_directory());
}

std::ostream& operator<<(std::ostream& os, SyncCout sc) {
    static std::mutex m;

    if (sc == IO_LOCK)
        m.lock();

    if (sc == IO_UNLOCK)
        m.unlock();

    return os;
}

void sync_cout_start() { std::cout << IO_LOCK; }
void sync_cout_end() { std::cout << IO_UNLOCK; }

std::uint64_t Engine::perft(const std::string& fen, Depth depth, bool isChess960) {
    verify_network();

    return Benchmark::perft(fen, depth, isChess960);
}

void Engine::go(Search::LimitsType& limits) {
    assert(limits.perft == 0);
    verify_network();

    threads.start_thinking(options, pos, states, limits);
}

void Engine::stop() { threads.stop = true; }

void Engine::search_clear() {
    wait_for_search_finished();

    tt.clear(threads);
    threads.clear();

    Tablebases::init(options["SyzygyPath"]);
}

void Engine::set_on_update_no_moves(std::function<void(const Engine::InfoShort&)>&& f) {
    updateContext.onUpdateNoMoves = std::move(f);
}

void Engine::set_on_update_full(std::function<void(const Engine::InfoFull&)>&& f) {
    updateContext.onUpdateFull = std::move(f);
}

void Engine::set_on_iter(std::function<void(const Engine::InfoIter&)>&& f) {
    updateContext.onIter = std::move(f);
}

void Engine::set_on_bestmove(std::function<void(std::string_view, std::string_view)>&& f) {
    updateContext.onBestmove = std::move(f);
}

void Engine::set_on_verify_network(std::function<void(std::string_view)>&& f) {
    onVerifyNetwork = std::move(f);
}

void Engine::wait_for_search_finished() { threads.main_thread()->wait_for_search_finished(); }

std::optional<PositionSetError> Engine::set_position(const std::string&              fen,
                                                     const std::vector<std::string>& moves) {
    states   = StateListPtr(new std::deque<StateInfo>(1));
    auto err = pos.set(fen, options["UCI_Chess960"], &states->back());
    if (err.has_value())
        return err;

    for (const auto& move : moves)
    {
        auto m = UCIEngine::to_move(pos, move);

        if (m == Move::none())
            return PositionSetError("Illegal move: " + move);

        states->emplace_back();
        pos.do_move(m, states->back());
    }

    return std::nullopt;
}

Engine::Engine(std::optional<std::string> path) :
        binaryDirectory(path ? CommandLine::get_binary_directory(*path) : ""),
        numaContext(NumaConfig::from_system(DefaultNumaPolicy)),
        states(new std::deque<StateInfo>(1)),
        threads(),
        network(numaContext, get_default_network()) {

        pos.set(StartFEN, false, &states->back());

        options.add(
            "Debug Log File", Option("", [](const Option& o) {
                    start_logger(o);
                    return std::nullopt;
            }));

        options.add(
            "NumaPolicy", Option("auto", [this](const Option& o) {
                    set_numa_config_from_option(o);
                    return numa_config_information_as_string() + "\n"
                             + thread_allocation_information_as_string();
            }));

        options.add(
            "Threads", Option(1, 1, MaxThreads, [this](const Option&) {
                    resize_threads();
                    return thread_allocation_information_as_string();
            }));

        options.add(
            "Hash", Option(16, 1, MaxHashMB, [this](const Option& o) {
                    set_tt_size(o);
                    return std::nullopt;
            }));

        options.add(
            "Clear Hash", Option([this](const Option&) {
                    search_clear();
                    return std::nullopt;
            }));

        options.add("Ponder", Option(false));
        options.add("MultiPV", Option(1, 1, MAX_MOVES));
        options.add("Skill Level", Option(20, 0, 20));
        options.add("Move Overhead", Option(10, 0, 5000));
        options.add("nodestime", Option(0, 0, 10000));
        options.add("UCI_Chess960", Option(false));
        options.add("UCI_LimitStrength", Option(false));
        options.add("UCI_Elo",
                                Option(Stockfish::Search::Skill::LowestElo, Stockfish::Search::Skill::LowestElo,
                                             Stockfish::Search::Skill::HighestElo));
        options.add("UCI_ShowWDL", Option(false));

        options.add(
            "SyzygyPath", Option("", [](const Option& o) {
                    Tablebases::init(o);
                    return std::nullopt;
            }));

        options.add("SyzygyProbeDepth", Option(1, 1, 100));
        options.add("Syzygy50MoveRule", Option(true));
        options.add("SyzygyProbeLimit", Option(7, 0, 7));

        options.add(
            "EvalFile", Option(EvalFileDefaultName, [this](const Option& o) {
                    load_network(o);
                    return std::nullopt;
            }));

        threads.clear();
        threads.ensure_network_replicated();
        resize_threads();
}

constexpr auto BenchmarkCommand = "speedtest";

template<typename... Ts>
struct overload: Ts... {
    using Ts::operator()...;
};

template<typename... Ts>
overload(Ts...) -> overload<Ts...>;

extern "C" {
struct ZfishParsedLimits {
    std::int64_t wtime;
    std::int64_t btime;
    std::int64_t winc;
    std::int64_t binc;
    int          movestogo;
    int          depth;
    int          mate;
    int          perft;
    int          infinite;
    std::int64_t movetime;
    std::uint64_t nodes;
    std::uint8_t  ponder_mode;
    const char*   searchmoves;
};

struct ZfishParsedPosition {
    std::uint8_t ok;
    const char*  fen;
    const char*  moves;
};

struct ZfishScoreClass {
    int kind;
    int plies;
    int win;
};

struct ZfishTuneNextResult {
    const char* token;
    const char* remaining;
};

struct ZfishBenchmarkSetupOutput {
    int         tt_size;
    int         threads;
    const char* commands_ptr;
    const char* original_invocation_ptr;
    const char* filled_invocation_ptr;
};

struct ZfishParsedSetOption {
    const char* name;
    const char* value;
};

struct ZfishAssignmentResult {
    std::uint8_t accepted;
    const char*  normalized_value;
};

ZfishParsedLimits zfish_uci_parse_limits(const unsigned char* input_ptr, std::size_t input_len);
ZfishParsedPosition zfish_uci_parse_position(const unsigned char* input_ptr, std::size_t input_len);
ZfishScoreClass zfish_classify_score(int value,
                                     int value_tb_win_in_max_ply,
                                     int value_tb,
                                     int value_mate);
ZfishTuneNextResult zfish_tune_next(const unsigned char* names_ptr,
                                    std::size_t          names_len,
                                    std::uint8_t         pop);
bool zfish_tune_should_make_option(int min_value, int max_value);
bool zfish_option_case_insensitive_less(const unsigned char* left_ptr,
                                        std::size_t          left_len,
                                        const unsigned char* right_ptr,
                                        std::size_t          right_len);
ZfishParsedSetOption zfish_option_parse_setoption(const unsigned char* input_ptr,
                                                  std::size_t          input_len);
bool zfish_option_combo_equals(const unsigned char* current_ptr,
                               std::size_t          current_len,
                               const unsigned char* query_ptr,
                               std::size_t          query_len);
ZfishAssignmentResult zfish_option_validate_assignment(const unsigned char* type_ptr,
                                                       std::size_t          type_len,
                                                       const unsigned char* value_ptr,
                                                       std::size_t          value_len,
                                                       int                  min_value,
                                                       int                  max_value,
                                                       const unsigned char* default_ptr,
                                                       std::size_t          default_len);
const char* zfish_benchmark_setup_bench(const unsigned char* current_fen_ptr,
                                        std::size_t          current_fen_len,
                                        const unsigned char* args_ptr,
                                        std::size_t          args_len);
ZfishBenchmarkSetupOutput zfish_benchmark_setup_benchmark(const unsigned char* args_ptr,
                                                          std::size_t          args_len,
                                                          int                  hardware_concurrency);
const char* zfish_uci_format_info_string(const unsigned char* input_ptr, std::size_t input_len);
const char* zfish_uci_format_score(std::uint8_t kind, int value, int extra);
int         zfish_uci_to_cp(int value, int material);
const char* zfish_uci_wdl(int value, int material);
const char* zfish_uci_format_square(std::uint8_t file, std::uint8_t rank);
const char* zfish_uci_format_move(std::uint8_t from_file,
                                  std::uint8_t from_rank,
                                  std::uint8_t to_file,
                                  std::uint8_t to_rank,
                                  std::uint8_t promotion);
const char* zfish_uci_to_lower(const unsigned char* input_ptr, std::size_t input_len);
const char* zfish_uci_format_info_no_moves(int depth,
                                           const unsigned char* score_ptr,
                                           std::size_t          score_len);
const char* zfish_uci_format_info_full(int                   depth,
                                       int                   sel_depth,
                                       std::size_t           multi_pv,
                                       const unsigned char*  score_ptr,
                                       std::size_t           score_len,
                                       const unsigned char*  bound_ptr,
                                       std::size_t           bound_len,
                                       const unsigned char*  wdl_ptr,
                                       std::size_t           wdl_len,
                                       std::uint8_t          show_wdl,
                                       std::size_t           nodes,
                                       std::size_t           nps,
                                       int                   hashfull,
                                       std::size_t           tb_hits,
                                       std::size_t           time_ms,
                                       const unsigned char*  pv_ptr,
                                       std::size_t           pv_len);
const char* zfish_uci_format_info_iter(int                  depth,
                                       const unsigned char* currmove_ptr,
                                       std::size_t          currmove_len,
                                       int                  currmove_number);
const char* zfish_uci_format_bestmove(const unsigned char* bestmove_ptr,
                                      std::size_t          bestmove_len,
                                      const unsigned char* ponder_ptr,
                                      std::size_t          ponder_len);
const char* zfish_uci_help_text();
const char* zfish_uci_format_unknown_command(const unsigned char* command_ptr,
                                             std::size_t          command_len);
const char* zfish_uci_format_critical_error(const unsigned char* command_ptr,
                                            std::size_t          command_len,
                                            const unsigned char* message_ptr,
                                            std::size_t          message_len);
const char*   zfish_position_build_endgame_fen(const unsigned char* code_ptr,
                                               std::size_t          code_len,
                                               std::uint8_t         color);
const char*   zfish_position_format_fen(const unsigned char* board_ptr,
                                        std::uint8_t         side_to_move,
                                        std::uint8_t         chess960,
                                        std::uint8_t         castling_rights,
                                        std::uint8_t         white_oo_rook_square,
                                        std::uint8_t         white_ooo_rook_square,
                                        std::uint8_t         black_oo_rook_square,
                                        std::uint8_t         black_ooo_rook_square,
                                        std::uint8_t         ep_square,
                                        int                  rule50,
                                        int                  game_ply);
std::uint64_t zfish_position_compute_material_key(const int* piece_counts_ptr,
                                                  std::size_t piece_count_len);
void          zfish_position_init_runtime();
const char*   zfish_bitboard_pretty(Stockfish::Bitboard bitboard);
void          zfish_bitboards_init();
}

namespace {

std::string take_string_and_free(const char* rendered) {
    if (!rendered)
        return {};

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

std::string take_string_and_free_required(const char* rendered) {
    if (!rendered)
        std::abort();

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

std::vector<std::string> split_newlines(const std::string& text) {
    std::vector<std::string> result;
    if (text.empty())
        return result;

    std::istringstream is(text);
    std::string        line;
    while (std::getline(is, line))
        result.push_back(line);
    return result;
}

int material_count(const Position& pos) {
    return pos.count<PAWN>() + 3 * pos.count<KNIGHT>() + 3 * pos.count<BISHOP>()
         + 5 * pos.count<ROOK>() + 9 * pos.count<QUEEN>();
}

std::string read_remaining_args(std::istream& is) {
    std::string args;
    std::getline(is, args);
    return args;
}

std::map<std::string, int> TuneResults;
const Option*             LastOption = nullptr;

std::optional<std::string> on_tune(const Option& o) {
    if (!Tune::update_on_last || LastOption == &o)
        Tune::read_options();

    return std::nullopt;
}

}  // namespace

uint8_t PopCnt16[1 << 16];
uint8_t SquareDistance[SQUARE_NB][SQUARE_NB];

Bitboard LineBB[SQUARE_NB][SQUARE_NB];
Bitboard BetweenBB[SQUARE_NB][SQUARE_NB];
Bitboard RayPassBB[SQUARE_NB][SQUARE_NB];

alignas(64) Magic Magics[SQUARE_NB][2];

namespace {

using MagicMask = Bitboard;

[[maybe_unused]] constexpr Bitboard constexpr_pext(Bitboard b, Bitboard m) {
    Bitboard result = 0, bit = 0;
    while (m)
    {
        Bitboard last = m & -m;
        result |= bool(b & last) << bit++;
        m ^= last;
    }
    return result;
}

void init_magics(PieceType pt, MagicMask table[], Magic magics[][2], [[maybe_unused]] bool tableAlreadyInit) {
    tableAlreadyInit = false;

    int seeds[][RANK_NB] = {{8977, 44560, 54343, 38998, 5731, 95205, 104912, 17020},
                            {728, 10316, 55013, 32803, 12281, 15100, 16645, 255}};

    Bitboard occupancy[4096];
    int      epoch[4096] = {}, cnt = 0;
    Bitboard reference[4096] = {};
    int      size = 0;

    for (Square s = SQ_A1; s <= SQ_H8; ++s)
    {
        Bitboard edges = ((Rank1BB | Rank8BB) & ~rank_bb(s)) | ((FileABB | FileHBB) & ~file_bb(s));

        Magic&   m       = magics[s][pt - BISHOP];
        Bitboard attacks = Bitboards::sliding_attack(pt, s, 0);
        m.mask           = attacks & ~edges;
        m.shift          = (Is64Bit ? 64 : 32) - popcount(m.mask);

        m.attacks = s == SQ_A1 ? table : magics[s - 1][pt - BISHOP].attacks + size;
        size      = 0;

        Bitboard b = 0;
        do
        {
            occupancy[size] = b;
            reference[size] = Bitboards::sliding_attack(pt, s, b);

            size++;
            b = (b - m.mask) & m.mask;
        } while (b);

        PRNG rng(seeds[Is64Bit][rank_of(s)]);

        for (int i = 0; i < size;)
        {
            for (m.magic = 0; popcount((m.magic * m.mask) >> 56) < 6;)
                m.magic = rng.sparse_rand<Bitboard>();

            for (++cnt, i = 0; i < size; ++i)
            {
                unsigned idx = m.index(occupancy[i]);

                if (epoch[idx] < cnt)
                {
                    epoch[idx]     = cnt;
                    m.attacks[idx] = reference[i];
                }
                else if (m.attacks[idx] != reference[i])
                    break;
            }
        }
    }
}

std::array<Bitboard, 0x19000> RookTable;
std::array<Bitboard, 0x1480>  BishopTable;

}  // namespace

extern "C" {

std::uint64_t zfish_position_material_zobrist(std::uint8_t piece, std::size_t count_index) {
    return Stockfish::Zobrist::psq[piece][8 + count_index];
}

void zfish_position_init_runtime() {
    Stockfish::Position::init();
}

void zfish_bitboards_init() {
    Stockfish::Bitboards::init();
}

}

namespace Bitboards {

void init() {
    for (unsigned i = 0; i < (1 << 16); ++i)
        PopCnt16[i] = uint8_t(std::bitset<16>(i).count());

    for (Square s1 = SQ_A1; s1 <= SQ_H8; ++s1)
        for (Square s2 = SQ_A1; s2 <= SQ_H8; ++s2)
            SquareDistance[s1][s2] = std::max(distance<File>(s1, s2), distance<Rank>(s1, s2));

    init_magics(ROOK, const_cast<MagicMask*>(RookTable.data()), Magics, true);
    init_magics(BISHOP, const_cast<MagicMask*>(BishopTable.data()), Magics, true);

    for (Square s1 = SQ_A1; s1 <= SQ_H8; ++s1)
    {
        for (PieceType pt : {BISHOP, ROOK})
            for (Square s2 = SQ_A1; s2 <= SQ_H8; ++s2)
            {
                if (PseudoAttacks[pt][s1] & s2)
                {
                    LineBB[s1][s2] = (attacks_bb(pt, s1, 0) & attacks_bb(pt, s2, 0)) | s1 | s2;
                    BetweenBB[s1][s2] =
                      (attacks_bb(pt, s1, square_bb(s2)) & attacks_bb(pt, s2, square_bb(s1)));
                    RayPassBB[s1][s2] =
                      attacks_bb(pt, s1, 0) & (attacks_bb(pt, s2, square_bb(s1)) | s2);
                }
                BetweenBB[s1][s2] |= s2;
            }
    }
}

std::string pretty(Bitboard b) { return take_string_and_free(zfish_bitboard_pretty(b)); }

}  // namespace Bitboards

Key Position::compute_material_key() const {
    return zfish_position_compute_material_key(pieceCount, PIECE_NB);
}

std::optional<PositionSetError> Position::set(const string& code, Color c, StateInfo* si) {
    const auto fenStr = take_string_and_free_required(zfish_position_build_endgame_fen(
      reinterpret_cast<const unsigned char*>(code.data()), code.size(), static_cast<std::uint8_t>(c)));
    return set(fenStr, false, si);
}

string Position::fen() const {
    const auto whiteOoRook = can_castle(WHITE_OO) ? castling_rook_square(WHITE_OO) : SQ_NONE;
    const auto whiteOooRook = can_castle(WHITE_OOO) ? castling_rook_square(WHITE_OOO) : SQ_NONE;
    const auto blackOoRook = can_castle(BLACK_OO) ? castling_rook_square(BLACK_OO) : SQ_NONE;
    const auto blackOooRook = can_castle(BLACK_OOO) ? castling_rook_square(BLACK_OOO) : SQ_NONE;

    return take_string_and_free_required(zfish_position_format_fen(
      reinterpret_cast<const unsigned char*>(board.data()), static_cast<std::uint8_t>(sideToMove),
      static_cast<std::uint8_t>(chess960), static_cast<std::uint8_t>(st->castlingRights),
      static_cast<std::uint8_t>(whiteOoRook), static_cast<std::uint8_t>(whiteOooRook),
      static_cast<std::uint8_t>(blackOoRook), static_cast<std::uint8_t>(blackOooRook),
      static_cast<std::uint8_t>(ep_square()), st->rule50, gamePly));
}

void UCIEngine::print_info_string(std::string_view str) {
    const auto rendered = take_string_and_free(
      zfish_uci_format_info_string(reinterpret_cast<const unsigned char*>(str.data()), str.size()));
    if (rendered.empty())
        return;

    sync_cout_start();
    std::cout << rendered << '\n';
    sync_cout_end();
}

UCIEngine::UCIEngine(int argc, char** argv) :
    engine(argv[0]),
    cli(argc, argv) {

    engine.get_options().add_info_listener([](const std::optional<std::string>& str) {
        if (str.has_value())
            print_info_string(*str);
    });

    init_search_update_listeners();
}

void UCIEngine::init_search_update_listeners() {
    engine.set_on_iter([](const auto& i) { on_iter(i); });
    engine.set_on_update_no_moves([](const auto& i) { on_update_no_moves(i); });
    engine.set_on_update_full(
      [this](const auto& i) { on_update_full(i, engine.get_options()["UCI_ShowWDL"]); });
    engine.set_on_bestmove([](const auto& bm, const auto& p) { on_bestmove(bm, p); });
    engine.set_on_verify_network([](const auto& s) { print_info_string(s); });
}

void UCIEngine::loop() {
    std::string token, cmd;

    for (int i = 1; i < cli.argc; ++i)
        cmd += std::string(cli.argv[i]) + " ";

    do
    {
        if (cli.argc == 1 && !getline(std::cin, cmd))
            cmd = "quit";

        std::istringstream is(cmd);

        token.clear();
        is >> token;

        if (token == "quit" || token == "stop")
            engine.stop();
        else if (token == "ponderhit")
            engine.set_ponderhit(false);
        else if (token == "uci")
        {
            sync_cout << "id name " << engine_info(true) << "\n" << engine.get_options() << sync_endl;
            sync_cout << "uciok" << sync_endl;
        }
        else if (token == "setoption")
            setoption(is);
        else if (token == "go")
        {
            print_info_string(engine.numa_config_information_as_string());
            print_info_string(engine.thread_allocation_information_as_string());
            go(is);
        }
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
            engine.search_clear();
        else if (token == "isready")
            sync_cout << "readyok" << sync_endl;
        else if (token == "flip")
            engine.flip();
        else if (token == "bench")
            bench(is);
        else if (token == BenchmarkCommand)
            benchmark(is);
        else if (token == "d")
            sync_cout << engine.visualize() << sync_endl;
        else if (token == "eval")
            engine.trace_eval();
        else if (token == "compiler")
            sync_cout << compiler_info() << sync_endl;
        else if (token == "export_net")
        {
            std::pair<std::optional<std::string>, std::string> file;

            if (is >> file.second)
                file.first = file.second;

            engine.save_network(file);
        }
        else if (token == "--help" || token == "help" || token == "--license"
                 || token == "license")
            sync_cout << take_string_and_free(zfish_uci_help_text()) << sync_endl;
        else if (!token.empty() && token[0] != '#')
            sync_cout
              << take_string_and_free(zfish_uci_format_unknown_command(
                   reinterpret_cast<const unsigned char*>(cmd.data()), cmd.size()))
              << sync_endl;

    } while (token != "quit" && cli.argc == 1);
}

Search::LimitsType UCIEngine::parse_limits(std::istream& is) {
    Search::LimitsType limits;
    limits.startTime = now();

    std::string rest;
    std::getline(is, rest);
    const auto parsed = zfish_uci_parse_limits(reinterpret_cast<const unsigned char*>(rest.data()),
                                               rest.size());

    limits.time[WHITE] = parsed.wtime;
    limits.time[BLACK] = parsed.btime;
    limits.inc[WHITE] = parsed.winc;
    limits.inc[BLACK] = parsed.binc;
    limits.movestogo = parsed.movestogo;
    limits.depth = parsed.depth;
    limits.nodes = parsed.nodes;
    limits.movetime = parsed.movetime;
    limits.mate = parsed.mate;
    limits.perft = parsed.perft;
    limits.infinite = parsed.infinite;
    limits.ponderMode = parsed.ponder_mode != 0;

    for (const auto& move : split_newlines(take_string_and_free(parsed.searchmoves)))
        limits.searchmoves.push_back(move);

    return limits;
}

void UCIEngine::go(std::istringstream& is) {

    Search::LimitsType limits = parse_limits(is);

    if (limits.perft)
        perft(limits);
    else
        engine.go(limits);
}

void UCIEngine::bench(std::istream& args) {
    std::string token;
    uint64_t    num, nodes = 0, cnt = 1;
    uint64_t    nodesSearched = 0;
    const auto& options       = engine.get_options();

    engine.set_on_update_full([&](const auto& i) {
        nodesSearched = i.nodes;
        on_update_full(i, options["UCI_ShowWDL"]);
    });

        const std::string benchmarkArgs = read_remaining_args(args);
        const std::string currentFen = engine.fen();
        const char* rendered = zfish_benchmark_setup_bench(
            reinterpret_cast<const unsigned char*>(currentFen.data()), currentFen.size(),
            reinterpret_cast<const unsigned char*>(benchmarkArgs.data()), benchmarkArgs.size());
        std::vector<std::string> list = split_newlines(take_string_and_free(rendered));

    num = count_if(list.begin(), list.end(),
                   [](const std::string& s) { return s.find("go ") == 0 || s.find("eval") == 0; });

    TimePoint elapsed = now();

    for (const auto& cmd : list)
    {
        std::istringstream is(cmd);
        is >> token;

        if (token == "go" || token == "eval")
        {
            std::cerr << "\nPosition: " << cnt++ << '/' << num << " (" << engine.fen() << ")"
                      << std::endl;
            if (token == "go")
            {
                Search::LimitsType limits = parse_limits(is);

                if (limits.perft)
                    nodesSearched = perft(limits);
                else
                {
                    engine.go(limits);
                    engine.wait_for_search_finished();
                }

                nodes += nodesSearched;
                nodesSearched = 0;
            }
            else
                engine.trace_eval();
        }
        else if (token == "setoption")
            setoption(is);
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
        {
            engine.search_clear();
            elapsed = now();
        }
    }

    elapsed = now() - elapsed + 1;

    dbg_print();

    std::cerr << "\n==========================="
              << "\nTotal time (ms) : " << elapsed
              << "\nNodes searched  : " << nodes
              << "\nNodes/second    : " << 1000 * nodes / elapsed << std::endl;

    engine.set_on_update_full([&](const auto& i) { on_update_full(i, options["UCI_ShowWDL"]); });
}

void UCIEngine::benchmark(std::istream& args) {
    static constexpr int NUM_WARMUP_POSITIONS = 3;

    std::string token;
    uint64_t    nodes = 0, cnt = 1;
    uint64_t    nodesSearched = 0;

    engine.set_on_update_full([&](const Engine::InfoFull& i) { nodesSearched = i.nodes; });

    engine.set_on_iter([](const auto&) {});
    engine.set_on_update_no_moves([](const auto&) {});
    engine.set_on_bestmove([](const auto&, const auto&) {});
    engine.set_on_verify_network([](const auto&) {});

        const std::string benchmarkArgs = read_remaining_args(args);
        const auto setupOutput = zfish_benchmark_setup_benchmark(
            reinterpret_cast<const unsigned char*>(benchmarkArgs.data()), benchmarkArgs.size(),
            static_cast<int>(get_hardware_concurrency()));

        Benchmark::BenchmarkSetup setup{};
        setup.ttSize = setupOutput.tt_size;
        setup.threads = setupOutput.threads;
        setup.commands = split_newlines(take_string_and_free(setupOutput.commands_ptr));
        setup.originalInvocation = take_string_and_free(setupOutput.original_invocation_ptr);
        setup.filledInvocation = take_string_and_free(setupOutput.filled_invocation_ptr);

    const auto numGoCommands = count_if(setup.commands.begin(), setup.commands.end(),
                                        [](const std::string& s) { return s.find("go ") == 0; });

    TimePoint totalTime = 0;

    auto ss = std::istringstream("name Threads value " + std::to_string(setup.threads));
    setoption(ss);
    ss = std::istringstream("name Hash value " + std::to_string(setup.ttSize));
    setoption(ss);
    ss = std::istringstream("name UCI_Chess960 value false");
    setoption(ss);

    for (const auto& cmd : setup.commands)
    {
        std::istringstream is(cmd);
        is >> token;

        if (token == "go")
        {
            std::cerr << "\rWarmup position " << cnt++ << '/' << NUM_WARMUP_POSITIONS;

            Search::LimitsType limits = parse_limits(is);
            engine.go(limits);
            engine.wait_for_search_finished();
        }
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
        {
            engine.search_clear();
        }

        if (cnt > NUM_WARMUP_POSITIONS)
            break;
    }

    std::cerr << "\n";

    cnt   = 1;
    nodes = 0;

    int           numHashfullReadings = 0;
    constexpr int hashfullAges[]      = {0, 999};
    constexpr int hashfullAgeCount    = std::size(hashfullAges);
    int           totalHashfull[hashfullAgeCount] = {0};
    int           maxHashfull[hashfullAgeCount]   = {0};

    auto updateHashfullReadings = [&]() {
        numHashfullReadings += 1;

        for (int i = 0; i < hashfullAgeCount; ++i)
        {
            const int hashfull = engine.get_hashfull(hashfullAges[i]);
            maxHashfull[i]     = std::max(maxHashfull[i], hashfull);
            totalHashfull[i] += hashfull;
        }
    };

    engine.search_clear();

    for (const auto& cmd : setup.commands)
    {
        std::istringstream is(cmd);
        is >> token;

        if (token == "go")
        {
            std::cerr << "\rPosition " << cnt++ << '/' << numGoCommands;

            Search::LimitsType limits = parse_limits(is);

            nodesSearched     = 0;
            TimePoint elapsed = now();

            engine.go(limits);
            engine.wait_for_search_finished();

            totalTime += now() - elapsed;

            updateHashfullReadings();

            nodes += nodesSearched;
        }
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
        {
            engine.search_clear();
        }
    }

    totalTime = std::max<TimePoint>(totalTime, 1);

    dbg_print();

    std::cerr << "\n";

    static_assert(
      std::size(hashfullAges) == 2 && hashfullAges[0] == 0 && hashfullAges[1] == 999,
      "Hardcoded for display. Would complicate the code needlessly in the current state.");

    std::string threadBinding = engine.thread_binding_information_as_string();
    if (threadBinding.empty())
        threadBinding = "none";

    std::cerr << "==========================="
              << "\nVersion                    : "
              << engine_version_info() << compiler_info()
              << "Large pages                : " << (has_large_pages() ? "yes" : "no")
              << "\nUser invocation            : " << BenchmarkCommand << " "
              << setup.originalInvocation << "\nFilled invocation          : " << BenchmarkCommand
              << " " << setup.filledInvocation
              << "\nAvailable processors       : " << engine.get_numa_config_as_string()
              << "\nThread count               : " << setup.threads
              << "\nThread binding             : " << threadBinding
              << "\nTT size [MiB]              : " << setup.ttSize
              << "\nHash max, avg [per mille]  : "
              << "\n    single search          : " << maxHashfull[0] << ", "
              << totalHashfull[0] / numHashfullReadings
              << "\n    single game            : " << maxHashfull[1] << ", "
              << totalHashfull[1] / numHashfullReadings
              << "\nTotal nodes searched       : " << nodes
              << "\nTotal search time [s]      : " << totalTime / 1000.0
              << "\nNodes/second               : " << 1000 * nodes / totalTime << std::endl;

    init_search_update_listeners();
}

void UCIEngine::setoption(std::istringstream& is) {
    engine.wait_for_search_finished();
    engine.get_options().setoption(is);
}

std::uint64_t UCIEngine::perft(const Search::LimitsType& limits) {
    auto nodes = engine.perft(engine.fen(), limits.perft, engine.get_options()["UCI_Chess960"]);
    sync_cout << "\nNodes searched: " << nodes << "\n" << sync_endl;
    return nodes;
}

void UCIEngine::position(std::istringstream& is) {
    const std::string fullCommand = is.str();
    const auto parsed = zfish_uci_parse_position(
      reinterpret_cast<const unsigned char*>(fullCommand.data()), fullCommand.size());
    if (!parsed.ok)
        return;

    const auto fen = take_string_and_free(parsed.fen);
    std::vector<std::string> moves = split_newlines(take_string_and_free(parsed.moves));

    auto err = engine.set_position(fen, moves);
    if (err.has_value())
    {
        terminate_on_critical_error(fullCommand, err->what());
    }
}

std::string UCIEngine::format_score(const Score& s) {
    return s.visit(overload{[](Score::Mate mate) -> std::string {
                                return take_string_and_free(zfish_uci_format_score(0, mate.plies, 0));
                            },
                            [](Score::Tablebase tb) -> std::string {
                                return take_string_and_free(
                                  zfish_uci_format_score(1, tb.plies, tb.win ? 1 : 0));
                            },
                            [](Score::InternalUnits units) -> std::string {
                                return take_string_and_free(
                                  zfish_uci_format_score(2, units.value, 0));
                            }});
}

int UCIEngine::to_cp(Value v, const Position& pos) {
    return zfish_uci_to_cp(v, material_count(pos));
}

std::string UCIEngine::wdl(Value v, const Position& pos) {
    return take_string_and_free(zfish_uci_wdl(v, material_count(pos)));
}

std::string UCIEngine::square(Square s) {
    return take_string_and_free(
      zfish_uci_format_square(static_cast<std::uint8_t>(file_of(s)), static_cast<std::uint8_t>(rank_of(s))));
}

std::string UCIEngine::move(Move m, bool chess960) {
    if (m == Move::none())
        return "(none)";

    if (m == Move::null())
        return "0000";

    Square from = m.from_sq();
    Square to   = m.to_sq();

    if (m.type_of() == CASTLING && !chess960)
        to = make_square(to > from ? FILE_G : FILE_C, rank_of(from));

    const auto promotion = m.type_of() == PROMOTION ? static_cast<std::uint8_t>(" pnbrqk"[m.promotion_type()]) : 0;

    return take_string_and_free(zfish_uci_format_move(static_cast<std::uint8_t>(file_of(from)),
                                                      static_cast<std::uint8_t>(rank_of(from)),
                                                      static_cast<std::uint8_t>(file_of(to)),
                                                      static_cast<std::uint8_t>(rank_of(to)),
                                                      promotion));
}

std::string UCIEngine::to_lower(std::string str) {
    return take_string_and_free(
      zfish_uci_to_lower(reinterpret_cast<const unsigned char*>(str.data()), str.size()));
}

Move UCIEngine::to_move(const Position& pos, std::string str) {
    str = to_lower(str);

    for (const auto& m : MoveList<LEGAL>(pos))
        if (str == move(m, pos.is_chess960()))
            return m;

    return Move::none();
}

void UCIEngine::on_update_no_moves(const Engine::InfoShort& info) {
    const auto score = format_score(info.score);
    sync_cout << take_string_and_free(zfish_uci_format_info_no_moves(
                   info.depth, reinterpret_cast<const unsigned char*>(score.data()), score.size()))
              << sync_endl;
}

void UCIEngine::on_update_full(const Engine::InfoFull& info, bool showWDL) {
    const auto score = format_score(info.score);
    sync_cout << take_string_and_free(zfish_uci_format_info_full(
                   info.depth, info.selDepth, info.multiPV,
                   reinterpret_cast<const unsigned char*>(score.data()), score.size(),
                   reinterpret_cast<const unsigned char*>(info.bound.data()), info.bound.size(),
                   reinterpret_cast<const unsigned char*>(info.wdl.data()), info.wdl.size(),
                   static_cast<std::uint8_t>(showWDL ? 1 : 0), info.nodes, info.nps, info.hashfull,
                   info.tbHits, info.timeMs, reinterpret_cast<const unsigned char*>(info.pv.data()),
                   info.pv.size()))
              << sync_endl;
}

void UCIEngine::on_iter(const Engine::InfoIter& info) {
    sync_cout
      << take_string_and_free(zfish_uci_format_info_iter(
           info.depth, reinterpret_cast<const unsigned char*>(info.currmove.data()),
           info.currmove.size(), info.currmovenumber))
      << sync_endl;
}

void UCIEngine::on_bestmove(std::string_view bestmove, std::string_view ponder) {
    sync_cout << take_string_and_free(zfish_uci_format_bestmove(
                   reinterpret_cast<const unsigned char*>(bestmove.data()), bestmove.size(),
                   reinterpret_cast<const unsigned char*>(ponder.data()), ponder.size()))
              << sync_endl;
}

void UCIEngine::terminate_on_critical_error(const std::string& fullCommand,
                                            const std::string& message) {
    sync_cout << take_string_and_free(zfish_uci_format_critical_error(
                   reinterpret_cast<const unsigned char*>(fullCommand.data()), fullCommand.size(),
                   reinterpret_cast<const unsigned char*>(message.data()), message.size()))
              << sync_endl;
    std::exit(1);
}

bool Tune::update_on_last;
OptionsMap* Tune::options;

bool CaseInsensitiveLess::operator()(const std::string& left, const std::string& right) const {
    return zfish_option_case_insensitive_less(
      reinterpret_cast<const unsigned char*>(left.data()), left.size(),
      reinterpret_cast<const unsigned char*>(right.data()), right.size());
}

void OptionsMap::add_info_listener(InfoListener&& message_func) {
    info = std::move(message_func);
}

void OptionsMap::setoption(std::istringstream& is) {
    std::string rest;
    std::getline(is, rest);

    const auto parsed = zfish_option_parse_setoption(
      reinterpret_cast<const unsigned char*>(rest.data()), rest.size());
    const auto name  = take_string_and_free(parsed.name);
    const auto value = take_string_and_free(parsed.value);

    if (options_map.count(name))
        options_map[name] = value;
    else
        sync_cout << "No such option: " << name << sync_endl;
}

const Option& OptionsMap::operator[](const std::string& name) const {
    auto it = options_map.find(name);
    assert(it != options_map.end());
    return it->second;
}

void OptionsMap::add(const std::string& name, const Option& option) {
    if (!options_map.count(name))
    {
        static size_t insert_order = 0;

        options_map[name] = option;

        options_map[name].parent = this;
        options_map[name].idx    = insert_order++;
    }
    else
    {
        std::cerr << "Option \"" << name << "\" was already added!" << std::endl;
        std::exit(EXIT_FAILURE);
    }
}

std::size_t OptionsMap::count(const std::string& name) const { return options_map.count(name); }

Option::Option(const OptionsMap* map) :
    parent(map) {}

Option::Option(const char* value, OnChange onChange) :
    type("string"),
    min(0),
    max(0),
    on_change(std::move(onChange)) {
    defaultValue = currentValue = value;
}

Option::Option(bool value, OnChange onChange) :
    type("check"),
    min(0),
    max(0),
    on_change(std::move(onChange)) {
    defaultValue = currentValue = (value ? "true" : "false");
}

Option::Option(OnChange onChange) :
    type("button"),
    min(0),
    max(0),
    on_change(std::move(onChange)) {}

Option::Option(int value, int minv, int maxv, OnChange onChange) :
    type("spin"),
    min(minv),
    max(maxv),
    on_change(std::move(onChange)) {
    defaultValue = currentValue = std::to_string(value);
}

Option::Option(const char* value, const char* current, OnChange onChange) :
    type("combo"),
    min(0),
    max(0),
    on_change(std::move(onChange)) {
    defaultValue = value;
    currentValue = current;
}

Option::operator int() const {
    assert(type == "check" || type == "spin");
    return type == "spin" ? std::stoi(currentValue) : currentValue == "true";
}

Option::operator std::string() const {
    assert(type == "string");
    return currentValue;
}

bool Option::operator==(const char* value) const {
    assert(type == "combo");
    return zfish_option_combo_equals(
      reinterpret_cast<const unsigned char*>(currentValue.data()), currentValue.size(),
      reinterpret_cast<const unsigned char*>(value), std::char_traits<char>::length(value));
}

bool Option::operator!=(const char* value) const { return !(*this == value); }

Option& Option::operator=(const std::string& value) {
    assert(!type.empty());

    const auto result = zfish_option_validate_assignment(
      reinterpret_cast<const unsigned char*>(type.data()), type.size(),
      reinterpret_cast<const unsigned char*>(value.data()), value.size(), min, max,
      reinterpret_cast<const unsigned char*>(defaultValue.data()), defaultValue.size());

    if (!result.accepted)
        return *this;

    if (type != "button")
        currentValue = take_string_and_free(result.normalized_value);

    if (on_change)
    {
        const auto ret = on_change(*this);

        if (ret && parent != nullptr && parent->info != nullptr)
            parent->info(ret);
    }

    return *this;
}

std::ostream& operator<<(std::ostream& os, const OptionsMap& optionsMap) {
    for (size_t idx = 0; idx < optionsMap.options_map.size(); ++idx)
        for (const auto& it : optionsMap.options_map)
            if (it.second.idx == idx)
            {
                const Option& option = it.second;
                os << "\noption name " << it.first << " type " << option.type;

                if (option.type == "check" || option.type == "combo")
                    os << " default " << option.defaultValue;
                else if (option.type == "string")
                    os << " default "
                       << (option.defaultValue.empty() ? "<empty>" : option.defaultValue);
                else if (option.type == "spin")
                    os << " default " << stoi(option.defaultValue) << " min " << option.min
                       << " max " << option.max;

                break;
            }

    return os;
}

void Tune::make_option(OptionsMap* opts, const std::string& name, int value, const SetRange& range) {
    const auto bounds = range(value);
    if (!zfish_tune_should_make_option(bounds.first, bounds.second))
        return;

    if (TuneResults.count(name))
        value = TuneResults[name];

    opts->add(name, Option(value, bounds.first, bounds.second, on_tune));
    LastOption = &((*opts)[name]);

    std::cout << name << ","                                 \
              << value << ","                                \
              << bounds.first << ","                         \
              << bounds.second << ","                        \
              << (bounds.second - bounds.first) / 20.0 << "," \
              << "0.0020" << std::endl;
}

std::string Tune::next(std::string& names, bool pop) {
    const auto result = zfish_tune_next(reinterpret_cast<const unsigned char*>(names.data()),
                                        names.size(), static_cast<std::uint8_t>(pop ? 1 : 0));
    const auto token = take_string_and_free(result.token);
    names            = take_string_and_free(result.remaining);
    return token;
}

template<>
void Tune::Entry<int>::init_option() {
    make_option(options, name, value, range);
}

template<>
void Tune::Entry<int>::read_option() {
    if (options->count(name))
        value = int((*options)[name]);
}

template<>
void Tune::Entry<Tune::PostUpdate>::init_option() {}

template<>
void Tune::Entry<Tune::PostUpdate>::read_option() {
    value();
}

void Tune::read_results() { /* ...insert your values here... */ }

Score::Score(Value v, const Position& pos) {
        assert(-VALUE_INFINITE < v && v < VALUE_INFINITE);

        const auto score_class =
            zfish_classify_score(v, VALUE_TB_WIN_IN_MAX_PLY, VALUE_TB, VALUE_MATE);

        switch (score_class.kind)
        {
        case 0 : score = InternalUnits{UCIEngine::to_cp(v, pos)}; break;
        case 1 : score = Tablebase{score_class.plies, score_class.win != 0}; break;
        case 2 : score = Mate{score_class.plies}; break;
        default : std::abort();
        }
}

}  // namespace Stockfish

namespace {

struct ZfishUciRuntimeHandle {
    std::vector<std::string>      ownedArgv;
    std::vector<char*>            mutableArgv;
    std::unique_ptr<Stockfish::UCIEngine> uci;
};

}  // namespace

extern "C" {
void* zfish_uci_create_runtime(int argc, const char* const* argv) {
    auto runtime = std::make_unique<ZfishUciRuntimeHandle>();
    runtime->ownedArgv.reserve(static_cast<std::size_t>(argc));
    runtime->mutableArgv.reserve(static_cast<std::size_t>(argc));

    for (int i = 0; i < argc; ++i)
        runtime->ownedArgv.emplace_back(argv[i] ? argv[i] : "");

    for (auto& arg : runtime->ownedArgv)
        runtime->mutableArgv.push_back(arg.data());

    runtime->uci = std::make_unique<Stockfish::UCIEngine>(argc, runtime->mutableArgv.data());
    Stockfish::Tune::init(runtime->uci->engine_options());
    return runtime.release();
}

void zfish_uci_loop_runtime(void* runtime_ptr) {
    static_cast<ZfishUciRuntimeHandle*>(runtime_ptr)->uci->loop();
}

void zfish_uci_destroy_runtime(void* runtime_ptr) {
    delete static_cast<ZfishUciRuntimeHandle*>(runtime_ptr);
}
}
