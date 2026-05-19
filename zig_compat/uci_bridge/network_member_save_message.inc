    if (result.message)
    {
        sync_cout << result.message << sync_endl;
        std::free(const_cast<char*>(result.message));
    }
