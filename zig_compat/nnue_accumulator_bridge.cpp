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

#include "nnue_accumulator_bridge/stack_latest.inc"

#include "nnue_accumulator_bridge/stack_latest_instantiations.inc"

#include "nnue_accumulator_bridge/stack_mut_latest.inc"

#include "nnue_accumulator_bridge/stack_accumulators.inc"

#include "nnue_accumulator_bridge/stack_mut_accumulators.inc"

#include "nnue_accumulator_bridge/stack_reset.inc"

#include "nnue_accumulator_bridge/stack_push.inc"

#include "nnue_accumulator_bridge/stack_pop.inc"

struct AccumulatorBridgeAccess {
#include "nnue_accumulator_bridge/bridge_access_incremental_psq.inc"

#include "nnue_accumulator_bridge/bridge_access_incremental_threat.inc"

#include "nnue_accumulator_bridge/bridge_access_refresh_psq.inc"

#include "nnue_accumulator_bridge/bridge_access_refresh_threat.inc"
};

extern "C" {
#include "nnue_accumulator_bridge/dirty_threat_raw.inc"

#include "nnue_accumulator_bridge/accumulator_evaluate_decl.inc"

void zfish_accumulator_incremental_step(void*         stack_ptr,
                                        std::uint8_t  feature_kind,
                                        bool          forward,
                                        std::uint8_t  perspective,
                                        const void*   pos_ptr,
                                        const void*   feature_transformer_ptr,
                                        std::size_t   target_index,
                                        std::size_t   computed_index) {
#include "nnue_accumulator_bridge/accumulator_incremental_step_prelude.inc"

        switch (feature_kind)
        {
        case ZfishAccumulatorPsqFeature:
    #include "nnue_accumulator_bridge/accumulator_incremental_step_psq_case.inc"
        case ZfishAccumulatorThreatFeature:
     #include "nnue_accumulator_bridge/accumulator_incremental_step_threat_case.inc"
        default:
    #include "nnue_accumulator_bridge/accumulator_incremental_step_default_case.inc"
        }
}

void zfish_accumulator_refresh_latest(void*          stack_ptr,
                                      std::uint8_t   feature_kind,
                                      std::uint8_t   perspective,
                                      const void*    pos_ptr,
                                      const void*    feature_transformer_ptr,
                                      void*          cache_ptr) {
#include "nnue_accumulator_bridge/accumulator_refresh_latest_prelude.inc"

    switch (feature_kind)
    {
    case ZfishAccumulatorPsqFeature:
#include "nnue_accumulator_bridge/accumulator_refresh_latest_psq_case.inc"
    case ZfishAccumulatorThreatFeature:
#include "nnue_accumulator_bridge/accumulator_refresh_latest_threat_case.inc"
    default:
#include "nnue_accumulator_bridge/accumulator_refresh_latest_default_case.inc"
    }
}
}

namespace {

template<typename VectorWrapper,
         IndexType Width,
         UpdateOperation... ops,
         typename ElementType,
         typename... Ts,
         std::enable_if_t<is_all_same_v<ElementType, Ts...>, bool> = true>
#include "nnue_accumulator_bridge/fused_row_reduce.inc"

template<typename FeatureSet>
struct AccumulatorUpdateContext {
    Color                               perspective;
    const FeatureTransformer&           featureTransformer;
    const AccumulatorState<FeatureSet>& from;
    AccumulatorState<FeatureSet>&       to;

#include "nnue_accumulator_bridge/update_context_ctor.inc"

#include "nnue_accumulator_bridge/update_context_apply_indices.inc"

    void apply(const typename FeatureSet::IndexList& added,
               const typename FeatureSet::IndexList& removed) {
    #include "nnue_accumulator_bridge/update_context_apply_delta_prelude.inc"

#ifdef VECTOR
        using Tiling = SIMDTiling<Dimensions, Dimensions, PSQTBuckets>;

        vec_t      acc[Tiling::NumRegs];
        psqt_vec_t psqt[Tiling::NumPsqtRegs];

        const auto* threatWeights = &featureTransformer.threatWeights[0];

#include "nnue_accumulator_bridge/update_context_apply_delta_vector_acc.inc"

#include "nnue_accumulator_bridge/update_context_apply_delta_vector_psqt.inc"

#else
#include "nnue_accumulator_bridge/update_context_apply_delta_scalar.inc"

#endif
    }
};

#include "nnue_accumulator_bridge/make_update_context.inc"

template<bool Forward, typename FeatureSet>
void update_accumulator_incremental(Color                               perspective,
                                    const FeatureTransformer&           featureTransformer,
                                    const Square                        ksq,
                                    AccumulatorState<FeatureSet>&       target_state,
                                    const AccumulatorState<FeatureSet>& computed) {

#include "nnue_accumulator_bridge/update_incremental_changed_indices.inc"

#include "nnue_accumulator_bridge/update_incremental_context_and_threat.inc"
    else
    {
#include "nnue_accumulator_bridge/update_incremental_size_guards.inc"

        if ((Forward && removedSize == 1) || (!Forward && addedSize == 1))
        {
#include "nnue_accumulator_bridge/update_incremental_apply_case_1_1.inc"
        }
        else if (Forward && addedSize == 1)
        {
    #include "nnue_accumulator_bridge/update_incremental_apply_case_1_2.inc"
        }
        else if (!Forward && removedSize == 1)
        {
    #include "nnue_accumulator_bridge/update_incremental_apply_case_2_1.inc"
        }
        else
        {
    #include "nnue_accumulator_bridge/update_incremental_apply_case_2_2.inc"
        }
    }
}

Bitboard get_changed_pieces(const std::array<Piece, SQUARE_NB>& oldPieces,
                            const std::array<Piece, SQUARE_NB>& newPieces) {
#if defined(USE_AVX2)
#include "nnue_accumulator_bridge/get_changed_pieces_avx2.inc"
#elif defined(USE_NEON)
#include "nnue_accumulator_bridge/get_changed_pieces_neon.inc"
#else
#include "nnue_accumulator_bridge/get_changed_pieces_scalar.inc"
#endif
}

void update_accumulator_refresh_cache(Color                            perspective,
                                      const FeatureTransformer&        featureTransformer,
                                      const Position&                  pos,
                                      AccumulatorState<PSQFeatureSet>& accumulator,
                                      AccumulatorCaches&               cache) {
#include "nnue_accumulator_bridge/update_refresh_cache_prelude.inc"

#include "nnue_accumulator_bridge/update_refresh_cache_changed_bitboards.inc"

#include "nnue_accumulator_bridge/update_refresh_cache_collect_indices.inc"

#include "nnue_accumulator_bridge/update_refresh_cache_sync_entry.inc"

#ifdef VECTOR
    vec_t      acc[Tiling::NumRegs];
    psqt_vec_t psqt[Tiling::NumPsqtRegs];

    const auto* weights = &featureTransformer.weights[0];

#include "nnue_accumulator_bridge/update_refresh_cache_vector_acc.inc"

#include "nnue_accumulator_bridge/update_refresh_cache_vector_psqt.inc"

#else

    #include "nnue_accumulator_bridge/update_refresh_cache_scalar_removed.inc"
    #include "nnue_accumulator_bridge/update_refresh_cache_scalar_added.inc"

    #include "nnue_accumulator_bridge/update_refresh_cache_scalar_copyback.inc"
#endif
}

void update_threats_accumulator_full(Color                               perspective,
                                     const FeatureTransformer&           featureTransformer,
                                     const Position&                     pos,
                                     AccumulatorState<ThreatFeatureSet>& accumulator) {
#include "nnue_accumulator_bridge/update_threats_full_prelude.inc"

#ifdef VECTOR
    vec_t      acc[Tiling::NumRegs];
    psqt_vec_t psqt[Tiling::NumPsqtRegs];

    const auto* threatWeights = &featureTransformer.threatWeights[0];

#include "nnue_accumulator_bridge/update_threats_full_vector_acc.inc"

#include "nnue_accumulator_bridge/update_threats_full_vector_psqt.inc"

#else

    #include "nnue_accumulator_bridge/update_threats_full_scalar.inc"

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

void FullThreats::append_active_indices(Color perspective, const Position& pos, IndexList& active) {
    const Square   ksq      = pos.square<KING>(perspective);
    const Bitboard occupied = pos.pieces();
    const Bitboard pawns    = pos.pieces(PAWN);

    for (Color color : {WHITE, BLACK})
    {
        const Color c = Color(perspective ^ color);

#include "nnue_accumulator_bridge/full_threats_pawn_attacks.inc"

#include "nnue_accumulator_bridge/full_threats_piece_attacks.inc"
    }
}

}  // namespace Features

}  // namespace Stockfish::Eval::NNUE
