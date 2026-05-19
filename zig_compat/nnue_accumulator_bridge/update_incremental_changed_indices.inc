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
