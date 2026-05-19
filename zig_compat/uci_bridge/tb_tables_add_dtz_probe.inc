    TBFile file_dtz(code + ".rtbz");
    if (file_dtz.is_open())
    {
        file_dtz.close();
        foundDTZFiles++;
    }
