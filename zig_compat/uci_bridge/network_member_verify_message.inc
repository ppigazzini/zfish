    if (f && result.message)
        f(result.message);

    if (result.message)
        std::free(const_cast<char*>(result.message));
