    static void refreshThreat(AccumulatorStack&         stack,
                              Color                     perspective,
                              const Position&           pos,
                              const FeatureTransformer& featureTransformer,
                              AccumulatorCaches&        cache) {
        (void) cache;
        update_threats_accumulator_full(
          perspective, featureTransformer, pos, stack.mut_latest<ThreatFeatureSet>());
    }
