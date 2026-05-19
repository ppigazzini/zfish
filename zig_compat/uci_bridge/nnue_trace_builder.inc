std::string build_nnue_trace(Stockfish::Position&                     pos,
                             const Stockfish::Eval::NNUE::Network&     network,
                             Stockfish::Eval::NNUE::AccumulatorCaches& caches) {
    auto accumulators = std::make_unique<Stockfish::Eval::NNUE::AccumulatorStack>();
    accumulators->reset();

    const auto trace = network.trace_evaluate(pos, *accumulators, caches);

    int psqt_cp[Stockfish::Eval::NNUE::LayerStacks];
    int positional_cp[Stockfish::Eval::NNUE::LayerStacks];
    for (std::size_t bucket = 0; bucket < Stockfish::Eval::NNUE::LayerStacks; ++bucket)
    {
        psqt_cp[bucket] = Stockfish::UCIEngine::to_cp(trace.psqt[bucket], pos);
        positional_cp[bucket] = Stockfish::UCIEngine::to_cp(trace.positional[bucket], pos);
    }

    const ZfishNnueTraceInput input = {
      .side_to_move_white = static_cast<std::uint8_t>(pos.side_to_move() == Stockfish::WHITE ? 1 : 0),
      .bucket_count       = Stockfish::Eval::NNUE::LayerStacks,
      .correct_bucket     = trace.correctBucket,
      .psqt_cp            = psqt_cp,
      .positional_cp      = positional_cp,
    };

    const char* rendered = zfish_nnue_format_trace(input);
    if (!rendered)
        std::abort();

    std::string result(rendered);
    std::free(const_cast<char*>(rendered));
    return result;
}
