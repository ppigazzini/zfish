    foundWDLFiles++;

    MaxCardinality = std::max(int(pieces.size()), MaxCardinality);

    wdlTable.emplace_back(code);
    dtzTable.emplace_back(wdlTable.back());

    insert(wdlTable.back().key, &wdlTable.back(), &dtzTable.back());
    insert(wdlTable.back().key2, &wdlTable.back(), &dtzTable.back());
