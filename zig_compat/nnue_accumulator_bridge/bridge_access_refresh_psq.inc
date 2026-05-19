    static void refreshPsq(AccumulatorStack&         stack,
                           Color                     perspective,
                           const Position&           pos,
                           const FeatureTransformer& featureTransformer,
                           AccumulatorCaches&        cache) {
        update_accumulator_refresh_cache(
          perspective, featureTransformer, pos, stack.mut_latest<PSQFeatureSet>(), cache);
    }
