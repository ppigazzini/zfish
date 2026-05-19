std::vector<std::pair<size_t, size_t>> Engine::get_bound_thread_count_by_numa_node() const {
    auto                                   counts = threads.get_bound_thread_count_by_numa_node();
    const NumaConfig&                      cfg    = numaContext.get_numa_config();
    std::vector<std::pair<size_t, size_t>> ratios;
    NumaIndex                              n = 0;
    for (; n < counts.size(); ++n)
        ratios.emplace_back(counts[n], cfg.num_cpus_in_numa_node(n));
    if (!counts.empty())
        for (; n < cfg.num_numa_nodes(); ++n)
            ratios.emplace_back(0, cfg.num_cpus_in_numa_node(n));
    return ratios;
}

std::string Engine::get_numa_config_as_string() const {
    return numaContext.get_numa_config().to_string();
}

std::string Engine::numa_config_information_as_string() const {
    auto cfgStr = get_numa_config_as_string();
    const char* rendered = zfish_engine_format_numa_info(
      reinterpret_cast<const unsigned char*>(cfgStr.data()), cfgStr.size());
    if (!rendered)
        std::abort();
    std::string result(rendered);
    std::free(const_cast<char*>(rendered));
    return result;
}

std::string Engine::thread_binding_information_as_string() const {
    auto boundThreadsByNode = get_bound_thread_count_by_numa_node();
    if (boundThreadsByNode.empty())
        return {};

    std::vector<ZfishCountPair> pairs;
    pairs.reserve(boundThreadsByNode.size());
    for (auto&& [current, total] : boundThreadsByNode)
        pairs.push_back(ZfishCountPair{current, total});

    const char* rendered = zfish_engine_format_thread_binding(pairs.data(), pairs.size());
    if (!rendered)
        std::abort();
    std::string result(rendered);
    std::free(const_cast<char*>(rendered));
    return result;
}

std::string Engine::thread_allocation_information_as_string() const {
    const size_t threadsSize = threads.size();
    const auto   binding = thread_binding_information_as_string();
    const char*  rendered = zfish_engine_format_thread_allocation(
      threadsSize, reinterpret_cast<const unsigned char*>(binding.data()), binding.size());
    if (!rendered)
        std::abort();
    std::string result(rendered);
    std::free(const_cast<char*>(rendered));
    return result;
}
