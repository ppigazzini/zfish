void AccumulatorStack::reset() noexcept {
    psq_accumulators[0].reset({});
    threat_accumulators[0].reset({});
    size = 1;
}
