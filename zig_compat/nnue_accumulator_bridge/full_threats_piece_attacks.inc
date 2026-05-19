        for (PieceType pt = KNIGHT; pt < KING; ++pt)
        {
            Piece    attacker = make_piece(c, pt);
            Bitboard bb       = pos.pieces(c, pt);
            while (bb)
            {
                Square   from    = pop_lsb(bb);
                Bitboard attacks = attacks_bb(pt, from, occupied) & occupied;
                while (attacks)
                {
                    Square    to        = pop_lsb(attacks);
                    Piece     attackedP = pos.piece_on(to);
                    IndexType index     = make_index(perspective, attacker, from, to, attackedP, ksq);
                    active.push_back_if_lt(index, Dimensions);
                }
            }
        }
