    TBFile file(code + ".rtbw");

    if (!file.is_open())
        return;

    file.close();
