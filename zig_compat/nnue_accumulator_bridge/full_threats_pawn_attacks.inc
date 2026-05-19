        {
            const Piece    attacker = make_piece(c, PAWN);
            const Bitboard cPawns   = pos.pieces(c, PAWN);
            const Bitboard pushers  = pawn_single_push_bb(~c, pawns) & cPawns;

            auto process_pawn_attacks = [&](Bitboard attacks, Direction attkDir) {
                while (attacks)
                {
                    Square to        = pop_lsb(attacks);
                    Square from      = to - attkDir;
                    Piece  attackedP = pos.piece_on(to);
                    IndexType index  = make_index(perspective, attacker, from, to, attackedP, ksq);
                    active.push_back_if_lt(index, Dimensions);
                }
            };

            if (c == WHITE)
            {
                process_pawn_attacks(shift<NORTH_EAST>(cPawns) & occupied, NORTH_EAST);
                process_pawn_attacks(shift<NORTH_WEST>(cPawns) & occupied, NORTH_WEST);
                process_pawn_attacks(shift<NORTH>(pushers), NORTH);
            }
            else
            {
                process_pawn_attacks(shift<SOUTH_WEST>(cPawns) & occupied, SOUTH_WEST);
                process_pawn_attacks(shift<SOUTH_EAST>(cPawns) & occupied, SOUTH_EAST);
                process_pawn_attacks(shift<SOUTH>(pushers), SOUTH);
            }
        }
