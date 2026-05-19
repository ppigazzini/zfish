            assert(addedSize == 1 && removedSize == 1);
            updateContext.template apply<Add, Sub>(added[0], removed[0]);
