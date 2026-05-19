    auto updateContext =
      make_accumulator_update_context(perspective, featureTransformer, computed, target_state);

    if constexpr (std::is_same_v<FeatureSet, ThreatFeatureSet>)
        updateContext.apply(added, removed);
