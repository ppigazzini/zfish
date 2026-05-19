            assert(addedSize == 2);
            updateContext.template apply<Add, Add, Sub>(added[0], added[1], removed[0]);
