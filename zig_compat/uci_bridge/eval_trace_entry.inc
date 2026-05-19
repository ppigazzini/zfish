std::string Eval::trace(Position& pos, const Eval::NNUE::Network& network) {
    if (pos.checkers())
        return "Final evaluation: none (in check)";

    auto accumulators = std::make_unique<Eval::NNUE::AccumulatorStack>();
    auto caches       = std::make_unique<Eval::NNUE::AccumulatorCaches>(network);

    const auto inner_trace = build_nnue_trace(pos, network, *caches);
    const auto [psqt, positional] = network.evaluate(pos, *accumulators, *caches);

    Value nnue = psqt + positional;
    Value nnue_white_side = pos.side_to_move() == WHITE ? nnue : -nnue;

    Value final_value = evaluate(network, pos, *accumulators, *caches, VALUE_ZERO);
    Value final_white_side = pos.side_to_move() == WHITE ? final_value : -final_value;

    const ZfishEvalTraceInput input = {
      .inner_trace_ptr     = reinterpret_cast<const unsigned char*>(inner_trace.data()),
      .inner_trace_len     = inner_trace.size(),
      .nnue_internal_value = nnue,
      .nnue_white_cp       = UCIEngine::to_cp(nnue_white_side, pos),
      .final_white_cp      = UCIEngine::to_cp(final_white_side, pos),
    };

    const char* rendered = zfish_eval_format_trace(input);
    if (!rendered)
        std::abort();

    std::string result(rendered);
    std::free(const_cast<char*>(rendered));
    return result;
}
