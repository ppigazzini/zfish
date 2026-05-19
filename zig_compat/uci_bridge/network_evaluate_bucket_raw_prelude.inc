    const auto& network = *static_cast<const Network*>(network_ptr);
    const auto& pos = *static_cast<const Position*>(pos_ptr);
    auto&       accumulator_stack = *static_cast<AccumulatorStack*>(accumulator_stack_ptr);
    auto&       cache = *static_cast<AccumulatorCaches*>(cache_ptr);

    constexpr uint64_t alignment = CacheLineSize;
    alignas(alignment) TransformedFeatureType transformedFeatures[FeatureTransformer::BufferSize];

    ASSERT_ALIGNED(transformedFeatures, alignment);
