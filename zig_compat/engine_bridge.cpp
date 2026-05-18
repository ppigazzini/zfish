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
