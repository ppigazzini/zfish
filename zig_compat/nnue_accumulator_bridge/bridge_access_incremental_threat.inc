        template<bool Forward>
        static void incrementalThreatStep(AccumulatorStack&         stack,
                                                                            Color                     perspective,
                                                                            const Position&           pos,
                                                                            const FeatureTransformer& featureTransformer,
                                                                            std::size_t               target_index,
                                                                            std::size_t               computed_index) {
                update_accumulator_incremental<Forward, ThreatFeatureSet>(
                    perspective, featureTransformer, pos.square<KING>(perspective),
                    stack.mut_accumulators<ThreatFeatureSet>()[target_index],
                    stack.accumulators<ThreatFeatureSet>()[computed_index]);
        }
