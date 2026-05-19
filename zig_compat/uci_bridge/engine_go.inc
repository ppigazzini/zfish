void Engine::go(Search::LimitsType& limits) {
    assert(limits.perft == 0);
    verify_network();

    threads.start_thinking(options, pos, states, limits);
}
