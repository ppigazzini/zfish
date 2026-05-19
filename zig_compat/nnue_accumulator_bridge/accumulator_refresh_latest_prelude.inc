    auto&       stack              = *static_cast<AccumulatorStack*>(stack_ptr);
    const auto& pos                = *static_cast<const Position*>(pos_ptr);
    const auto& featureTransformer =
      *static_cast<const FeatureTransformer*>(feature_transformer_ptr);
    auto&       cache = *static_cast<AccumulatorCaches*>(cache_ptr);
    const auto  side  = static_cast<Color>(perspective);
