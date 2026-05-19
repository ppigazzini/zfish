std::pair<DirtyPiece&, DirtyThreats&> AccumulatorStack::push() noexcept {
    assert(size < MaxSize);
    auto& dp  = psq_accumulators[size].reset();
    auto& dts = threat_accumulators[size].reset();
    new (&dts) DirtyThreats;
    size++;
    return {dp, dts};
}
