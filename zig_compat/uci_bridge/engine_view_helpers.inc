const OptionsMap& Engine::get_options() const { return options; }
OptionsMap&       Engine::get_options() { return options; }

std::string Engine::fen() const { return pos.fen(); }

void Engine::flip() { pos.flip(); }

std::string Engine::visualize() const {
    std::stringstream ss;
    ss << pos;
    return ss.str();
}

int Engine::get_hashfull(int maxAge) const { return tt.hashfull(maxAge); }
