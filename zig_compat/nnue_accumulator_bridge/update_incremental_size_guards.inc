        [[maybe_unused]] const int addedSize   = added.ssize();
        [[maybe_unused]] const int removedSize = removed.ssize();

        assert(addedSize == 1 || addedSize == 2);
        assert(removedSize == 1 || removedSize == 2);
        assert((Forward && addedSize <= removedSize) || (!Forward && addedSize >= removedSize));

        sf_assume(addedSize == 1 || addedSize == 2);
        sf_assume(removedSize == 1 || removedSize == 2);

        if (!(removedSize == 1 || removedSize == 2) || !(addedSize == 1 || addedSize == 2))
            sf_unreachable();
