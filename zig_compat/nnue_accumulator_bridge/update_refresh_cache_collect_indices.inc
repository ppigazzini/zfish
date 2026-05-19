#if defined(USE_AVX512ICL)
    PSQFeatureSet::write_indices(entry.pieces, pos.piece_array(), removedBB, addedBB, perspective,
                                 ksq, removed, added);
#else
    while (removedBB)
    {
        Square sq = pop_lsb(removedBB);
        removed.push_back(PSQFeatureSet::make_index(perspective, sq, entry.pieces[sq], ksq));
    }
    while (addedBB)
    {
        Square sq = pop_lsb(addedBB);
        added.push_back(PSQFeatureSet::make_index(perspective, sq, pos.piece_on(sq), ksq));
    }
#endif
