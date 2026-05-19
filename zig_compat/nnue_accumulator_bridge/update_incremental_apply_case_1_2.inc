            assert(removedSize == 2);
            updateContext.template apply<Add, Sub, Sub>(added[0], removed[0], removed[1]);
