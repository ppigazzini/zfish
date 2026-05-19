void Engine::verify_network() const {
    network->verify(options["EvalFile"], onVerifyNetwork);

    auto statuses = network.get_status_and_errors();
    for (size_t i = 0; i < statuses.size(); ++i)
    {
        const auto [status, error] = statuses[i];
        const std::string error_text = error.value_or(std::string{});
        const char* message = zfish_engine_format_network_status(
          i + 1,
          static_cast<std::uint8_t>(status),
          reinterpret_cast<const unsigned char*>(error_text.data()),
          error_text.size());
        if (!message)
            std::abort();
        onVerifyNetwork(message);
        std::free(const_cast<char*>(message));
    }
}

std::unique_ptr<Eval::NNUE::Network> Engine::get_default_network() const {

    auto network_ = std::make_unique<NN::Network>(NN::EvalFile{EvalFileDefaultName, "None", ""});

    network_->load(binaryDirectory, "");

    return network_;
}

void Engine::load_network(const std::string& file) {
    network.modify_and_replicate(
      [this, &file](NN::Network& network_) { network_.load(binaryDirectory, file); });
    threads.clear();
    threads.ensure_network_replicated();
}

void Engine::save_network(const std::pair<std::optional<std::string>, std::string> file) {
    network.modify_and_replicate([&file](NN::Network& network_) { network_.save(file.first); });
}
