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

#include <array>
#include <cassert>
#include <cstdint>
#include <type_traits>

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
struct ZfishDirtyThreatRaw {
    std::uint32_t data;
};

struct ZfishFullDiff {
    std::uint8_t us;
    std::uint8_t prev_ksq;
    std::uint8_t ksq;
};

struct ZfishFullThreatParams {
    std::uint8_t perspective;
    std::uint8_t attacker;
    std::uint8_t from_sq;
    std::uint8_t to_sq;
    std::uint8_t attacked;
    std::uint8_t king_square;
};

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
    auto&       cache = *static_cast<AccumulatorCaches*>(cache_ptr);
    const auto  side  = static_cast<Color>(perspective);

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
