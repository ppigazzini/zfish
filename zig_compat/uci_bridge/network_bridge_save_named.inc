    static bool saveNamed(const Network& network,
                          std::ostream&  stream,
                          const std::string& name,
                          const std::string& netDescription) {
        return network.save(stream, name, netDescription);
    }
