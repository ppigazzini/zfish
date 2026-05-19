std::string take_string_and_free(const char* rendered) {
    if (!rendered)
        return {};

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

std::string take_string_and_free_required(const char* rendered) {
    if (!rendered)
        std::abort();

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}
