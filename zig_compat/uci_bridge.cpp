/*
  Stockfish, a UCI chess playing engine derived from Glaurung 2.1
  Copyright (C) 2004-2026 The Stockfish developers (see AUTHORS file)

  Stockfish is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  Stockfish is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

#include "uci.h"

#include <algorithm>
#include <array>
#include <bitset>
#include <cctype>
#include <cstdlib>
#include <initializer_list>
#include <iterator>
#include <map>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "benchmark.h"
#include "engine.h"
#include "memory.h"
#include "misc.h"
#include "movegen.h"
#include "numa.h"
#include "position.h"
#include "score.h"
#include "search.h"
#include "tune.h"
#include "types.h"
#include "ucioption.h"

#define ZFISH_POSITION_BRIDGE_SKIP_COMPUTE_MATERIAL_KEY
#define ZFISH_POSITION_BRIDGE_SKIP_ENDGAME_SET
#define ZFISH_POSITION_BRIDGE_SKIP_FEN
#include "../src/position.cpp"

#define PieceToChar engine_bridge_tbprobe_piece_to_char
#define take_string_and_free engine_bridge_take_string_and_free
#include "engine_bridge.cpp"
#undef take_string_and_free
#undef PieceToChar
#include "search_bridge.cpp"

namespace Stockfish {

constexpr auto BenchmarkCommand = "speedtest";

template<typename... Ts>
struct overload: Ts... {
    using Ts::operator()...;
};

template<typename... Ts>
overload(Ts...) -> overload<Ts...>;

extern "C" {
struct ZfishParsedLimits {
    std::int64_t wtime;
    std::int64_t btime;
    std::int64_t winc;
    std::int64_t binc;
    int          movestogo;
    int          depth;
    int          mate;
    int          perft;
    int          infinite;
    std::int64_t movetime;
    std::uint64_t nodes;
    std::uint8_t  ponder_mode;
    const char*   searchmoves;
};

struct ZfishParsedPosition {
    std::uint8_t ok;
    const char*  fen;
    const char*  moves;
};

struct ZfishScoreClass {
    int kind;
    int plies;
    int win;
};

struct ZfishTuneNextResult {
    const char* token;
    const char* remaining;
};

struct ZfishBenchmarkSetupOutput {
    int         tt_size;
    int         threads;
    const char* commands_ptr;
    const char* original_invocation_ptr;
    const char* filled_invocation_ptr;
};

struct ZfishParsedSetOption {
    const char* name;
    const char* value;
};

struct ZfishAssignmentResult {
    std::uint8_t accepted;
    const char*  normalized_value;
};

ZfishParsedLimits zfish_uci_parse_limits(const unsigned char* input_ptr, std::size_t input_len);
ZfishParsedPosition zfish_uci_parse_position(const unsigned char* input_ptr, std::size_t input_len);
ZfishScoreClass zfish_classify_score(int value,
                                     int value_tb_win_in_max_ply,
                                     int value_tb,
                                     int value_mate);
ZfishTuneNextResult zfish_tune_next(const unsigned char* names_ptr,
                                    std::size_t          names_len,
                                    std::uint8_t         pop);
bool zfish_tune_should_make_option(int min_value, int max_value);
bool zfish_option_case_insensitive_less(const unsigned char* left_ptr,
                                        std::size_t          left_len,
                                        const unsigned char* right_ptr,
                                        std::size_t          right_len);
ZfishParsedSetOption zfish_option_parse_setoption(const unsigned char* input_ptr,
                                                  std::size_t          input_len);
bool zfish_option_combo_equals(const unsigned char* current_ptr,
                               std::size_t          current_len,
                               const unsigned char* query_ptr,
                               std::size_t          query_len);
ZfishAssignmentResult zfish_option_validate_assignment(const unsigned char* type_ptr,
                                                       std::size_t          type_len,
                                                       const unsigned char* value_ptr,
                                                       std::size_t          value_len,
                                                       int                  min_value,
                                                       int                  max_value,
                                                       const unsigned char* default_ptr,
                                                       std::size_t          default_len);
const char* zfish_benchmark_setup_bench(const unsigned char* current_fen_ptr,
                                        std::size_t          current_fen_len,
                                        const unsigned char* args_ptr,
                                        std::size_t          args_len);
ZfishBenchmarkSetupOutput zfish_benchmark_setup_benchmark(const unsigned char* args_ptr,
                                                          std::size_t          args_len,
                                                          int                  hardware_concurrency);
const char* zfish_uci_format_info_string(const unsigned char* input_ptr, std::size_t input_len);
const char* zfish_uci_format_score(std::uint8_t kind, int value, int extra);
int         zfish_uci_to_cp(int value, int material);
const char* zfish_uci_wdl(int value, int material);
const char* zfish_uci_format_square(std::uint8_t file, std::uint8_t rank);
const char* zfish_uci_format_move(std::uint8_t from_file,
                                  std::uint8_t from_rank,
                                  std::uint8_t to_file,
                                  std::uint8_t to_rank,
                                  std::uint8_t promotion);
const char* zfish_uci_to_lower(const unsigned char* input_ptr, std::size_t input_len);
const char* zfish_uci_format_info_no_moves(int depth,
                                           const unsigned char* score_ptr,
                                           std::size_t          score_len);
const char* zfish_uci_format_info_full(int                   depth,
                                       int                   sel_depth,
                                       std::size_t           multi_pv,
                                       const unsigned char*  score_ptr,
                                       std::size_t           score_len,
                                       const unsigned char*  bound_ptr,
                                       std::size_t           bound_len,
                                       const unsigned char*  wdl_ptr,
                                       std::size_t           wdl_len,
                                       std::uint8_t          show_wdl,
                                       std::size_t           nodes,
                                       std::size_t           nps,
                                       int                   hashfull,
                                       std::size_t           tb_hits,
                                       std::size_t           time_ms,
                                       const unsigned char*  pv_ptr,
                                       std::size_t           pv_len);
const char* zfish_uci_format_info_iter(int                  depth,
                                       const unsigned char* currmove_ptr,
                                       std::size_t          currmove_len,
                                       int                  currmove_number);
const char* zfish_uci_format_bestmove(const unsigned char* bestmove_ptr,
                                      std::size_t          bestmove_len,
                                      const unsigned char* ponder_ptr,
                                      std::size_t          ponder_len);
const char* zfish_uci_help_text();
const char* zfish_uci_format_unknown_command(const unsigned char* command_ptr,
                                             std::size_t          command_len);
const char* zfish_uci_format_critical_error(const unsigned char* command_ptr,
                                            std::size_t          command_len,
                                            const unsigned char* message_ptr,
                                            std::size_t          message_len);
const char*   zfish_position_build_endgame_fen(const unsigned char* code_ptr,
                                               std::size_t          code_len,
                                               std::uint8_t         color);
const char*   zfish_position_format_fen(const unsigned char* board_ptr,
                                        std::uint8_t         side_to_move,
                                        std::uint8_t         chess960,
                                        std::uint8_t         castling_rights,
                                        std::uint8_t         white_oo_rook_square,
                                        std::uint8_t         white_ooo_rook_square,
                                        std::uint8_t         black_oo_rook_square,
                                        std::uint8_t         black_ooo_rook_square,
                                        std::uint8_t         ep_square,
                                        int                  rule50,
                                        int                  game_ply);
std::uint64_t zfish_position_compute_material_key(const int* piece_counts_ptr,
                                                  std::size_t piece_count_len);
void          zfish_position_init_runtime();
const char*   zfish_bitboard_pretty(Stockfish::Bitboard bitboard);
void          zfish_bitboards_init();
}

namespace {

std::string take_string_and_free(const char* rendered) {
    if (!rendered)
        return {};

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

std::string take_string_and_free_required(const char* rendered) {
    if (!rendered)
        std::abort();

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

std::vector<std::string> split_newlines(const std::string& text) {
    std::vector<std::string> result;
    if (text.empty())
        return result;

    std::istringstream is(text);
    std::string        line;
    while (std::getline(is, line))
        result.push_back(line);
    return result;
}

int material_count(const Position& pos) {
    return pos.count<PAWN>() + 3 * pos.count<KNIGHT>() + 3 * pos.count<BISHOP>()
         + 5 * pos.count<ROOK>() + 9 * pos.count<QUEEN>();
}

std::string read_remaining_args(std::istream& is) {
    std::string args;
    std::getline(is, args);
    return args;
}

std::map<std::string, int> TuneResults;
const Option*             LastOption = nullptr;

std::optional<std::string> on_tune(const Option& o) {
    if (!Tune::update_on_last || LastOption == &o)
        Tune::read_options();

    return std::nullopt;
}

}  // namespace

uint8_t PopCnt16[1 << 16];
uint8_t SquareDistance[SQUARE_NB][SQUARE_NB];

Bitboard LineBB[SQUARE_NB][SQUARE_NB];
Bitboard BetweenBB[SQUARE_NB][SQUARE_NB];
Bitboard RayPassBB[SQUARE_NB][SQUARE_NB];

alignas(64) Magic Magics[SQUARE_NB][2];

namespace {

using MagicMask = Bitboard;

[[maybe_unused]] constexpr Bitboard constexpr_pext(Bitboard b, Bitboard m) {
    Bitboard result = 0, bit = 0;
    while (m)
    {
        Bitboard last = m & -m;
        result |= bool(b & last) << bit++;
        m ^= last;
    }
    return result;
}

void init_magics(PieceType pt, MagicMask table[], Magic magics[][2], [[maybe_unused]] bool tableAlreadyInit) {
    tableAlreadyInit = false;

    int seeds[][RANK_NB] = {{8977, 44560, 54343, 38998, 5731, 95205, 104912, 17020},
                            {728, 10316, 55013, 32803, 12281, 15100, 16645, 255}};

    Bitboard occupancy[4096];
    int      epoch[4096] = {}, cnt = 0;
    Bitboard reference[4096] = {};
    int      size = 0;

    for (Square s = SQ_A1; s <= SQ_H8; ++s)
    {
        Bitboard edges = ((Rank1BB | Rank8BB) & ~rank_bb(s)) | ((FileABB | FileHBB) & ~file_bb(s));

        Magic&   m       = magics[s][pt - BISHOP];
        Bitboard attacks = Bitboards::sliding_attack(pt, s, 0);
        m.mask           = attacks & ~edges;
        m.shift          = (Is64Bit ? 64 : 32) - popcount(m.mask);

        m.attacks = s == SQ_A1 ? table : magics[s - 1][pt - BISHOP].attacks + size;
        size      = 0;

        Bitboard b = 0;
        do
        {
            occupancy[size] = b;
            reference[size] = Bitboards::sliding_attack(pt, s, b);

            size++;
            b = (b - m.mask) & m.mask;
        } while (b);

        PRNG rng(seeds[Is64Bit][rank_of(s)]);

        for (int i = 0; i < size;)
        {
            for (m.magic = 0; popcount((m.magic * m.mask) >> 56) < 6;)
                m.magic = rng.sparse_rand<Bitboard>();

            for (++cnt, i = 0; i < size; ++i)
            {
                unsigned idx = m.index(occupancy[i]);

                if (epoch[idx] < cnt)
                {
                    epoch[idx]     = cnt;
                    m.attacks[idx] = reference[i];
                }
                else if (m.attacks[idx] != reference[i])
                    break;
            }
        }
    }
}

std::array<Bitboard, 0x19000> RookTable;
std::array<Bitboard, 0x1480>  BishopTable;

}  // namespace

extern "C" {

std::uint64_t zfish_position_material_zobrist(std::uint8_t piece, std::size_t count_index) {
    return Stockfish::Zobrist::psq[piece][8 + count_index];
}

void zfish_position_init_runtime() {
    Stockfish::Position::init();
}

void zfish_bitboards_init() {
    Stockfish::Bitboards::init();
}

}

namespace Bitboards {

void init() {
    for (unsigned i = 0; i < (1 << 16); ++i)
        PopCnt16[i] = uint8_t(std::bitset<16>(i).count());

    for (Square s1 = SQ_A1; s1 <= SQ_H8; ++s1)
        for (Square s2 = SQ_A1; s2 <= SQ_H8; ++s2)
            SquareDistance[s1][s2] = std::max(distance<File>(s1, s2), distance<Rank>(s1, s2));

    init_magics(ROOK, const_cast<MagicMask*>(RookTable.data()), Magics, true);
    init_magics(BISHOP, const_cast<MagicMask*>(BishopTable.data()), Magics, true);

    for (Square s1 = SQ_A1; s1 <= SQ_H8; ++s1)
    {
        for (PieceType pt : {BISHOP, ROOK})
            for (Square s2 = SQ_A1; s2 <= SQ_H8; ++s2)
            {
                if (PseudoAttacks[pt][s1] & s2)
                {
                    LineBB[s1][s2] = (attacks_bb(pt, s1, 0) & attacks_bb(pt, s2, 0)) | s1 | s2;
                    BetweenBB[s1][s2] =
                      (attacks_bb(pt, s1, square_bb(s2)) & attacks_bb(pt, s2, square_bb(s1)));
                    RayPassBB[s1][s2] =
                      attacks_bb(pt, s1, 0) & (attacks_bb(pt, s2, square_bb(s1)) | s2);
                }
                BetweenBB[s1][s2] |= s2;
            }
    }
}

std::string pretty(Bitboard b) { return take_string_and_free(zfish_bitboard_pretty(b)); }

}  // namespace Bitboards

Key Position::compute_material_key() const {
    return zfish_position_compute_material_key(pieceCount, PIECE_NB);
}

std::optional<PositionSetError> Position::set(const string& code, Color c, StateInfo* si) {
    const auto fenStr = take_string_and_free_required(zfish_position_build_endgame_fen(
      reinterpret_cast<const unsigned char*>(code.data()), code.size(), static_cast<std::uint8_t>(c)));
    return set(fenStr, false, si);
}

string Position::fen() const {
    const auto whiteOoRook = can_castle(WHITE_OO) ? castling_rook_square(WHITE_OO) : SQ_NONE;
    const auto whiteOooRook = can_castle(WHITE_OOO) ? castling_rook_square(WHITE_OOO) : SQ_NONE;
    const auto blackOoRook = can_castle(BLACK_OO) ? castling_rook_square(BLACK_OO) : SQ_NONE;
    const auto blackOooRook = can_castle(BLACK_OOO) ? castling_rook_square(BLACK_OOO) : SQ_NONE;

    return take_string_and_free_required(zfish_position_format_fen(
      reinterpret_cast<const unsigned char*>(board.data()), static_cast<std::uint8_t>(sideToMove),
      static_cast<std::uint8_t>(chess960), static_cast<std::uint8_t>(st->castlingRights),
      static_cast<std::uint8_t>(whiteOoRook), static_cast<std::uint8_t>(whiteOooRook),
      static_cast<std::uint8_t>(blackOoRook), static_cast<std::uint8_t>(blackOooRook),
      static_cast<std::uint8_t>(ep_square()), st->rule50, gamePly));
}

void UCIEngine::print_info_string(std::string_view str) {
    const auto rendered = take_string_and_free(
      zfish_uci_format_info_string(reinterpret_cast<const unsigned char*>(str.data()), str.size()));
    if (rendered.empty())
        return;

    sync_cout_start();
    std::cout << rendered << '\n';
    sync_cout_end();
}

UCIEngine::UCIEngine(int argc, char** argv) :
    engine(argv[0]),
    cli(argc, argv) {

    engine.get_options().add_info_listener([](const std::optional<std::string>& str) {
        if (str.has_value())
            print_info_string(*str);
    });

    init_search_update_listeners();
}

void UCIEngine::init_search_update_listeners() {
    engine.set_on_iter([](const auto& i) { on_iter(i); });
    engine.set_on_update_no_moves([](const auto& i) { on_update_no_moves(i); });
    engine.set_on_update_full(
      [this](const auto& i) { on_update_full(i, engine.get_options()["UCI_ShowWDL"]); });
    engine.set_on_bestmove([](const auto& bm, const auto& p) { on_bestmove(bm, p); });
    engine.set_on_verify_network([](const auto& s) { print_info_string(s); });
}

void UCIEngine::loop() {
    std::string token, cmd;

    for (int i = 1; i < cli.argc; ++i)
        cmd += std::string(cli.argv[i]) + " ";

    do
    {
        if (cli.argc == 1 && !getline(std::cin, cmd))
            cmd = "quit";

        std::istringstream is(cmd);

        token.clear();
        is >> token;

        if (token == "quit" || token == "stop")
            engine.stop();
        else if (token == "ponderhit")
            engine.set_ponderhit(false);
        else if (token == "uci")
        {
            sync_cout << "id name " << engine_info(true) << "\n" << engine.get_options() << sync_endl;
            sync_cout << "uciok" << sync_endl;
        }
        else if (token == "setoption")
            setoption(is);
        else if (token == "go")
        {
            print_info_string(engine.numa_config_information_as_string());
            print_info_string(engine.thread_allocation_information_as_string());
            go(is);
        }
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
            engine.search_clear();
        else if (token == "isready")
            sync_cout << "readyok" << sync_endl;
        else if (token == "flip")
            engine.flip();
        else if (token == "bench")
            bench(is);
        else if (token == BenchmarkCommand)
            benchmark(is);
        else if (token == "d")
            sync_cout << engine.visualize() << sync_endl;
        else if (token == "eval")
            engine.trace_eval();
        else if (token == "compiler")
            sync_cout << compiler_info() << sync_endl;
        else if (token == "export_net")
        {
            std::pair<std::optional<std::string>, std::string> file;

            if (is >> file.second)
                file.first = file.second;

            engine.save_network(file);
        }
        else if (token == "--help" || token == "help" || token == "--license"
                 || token == "license")
            sync_cout << take_string_and_free(zfish_uci_help_text()) << sync_endl;
        else if (!token.empty() && token[0] != '#')
            sync_cout
              << take_string_and_free(zfish_uci_format_unknown_command(
                   reinterpret_cast<const unsigned char*>(cmd.data()), cmd.size()))
              << sync_endl;

    } while (token != "quit" && cli.argc == 1);
}

Search::LimitsType UCIEngine::parse_limits(std::istream& is) {
    Search::LimitsType limits;
    limits.startTime = now();

    std::string rest;
    std::getline(is, rest);
    const auto parsed = zfish_uci_parse_limits(reinterpret_cast<const unsigned char*>(rest.data()),
                                               rest.size());

    limits.time[WHITE] = parsed.wtime;
    limits.time[BLACK] = parsed.btime;
    limits.inc[WHITE] = parsed.winc;
    limits.inc[BLACK] = parsed.binc;
    limits.movestogo = parsed.movestogo;
    limits.depth = parsed.depth;
    limits.nodes = parsed.nodes;
    limits.movetime = parsed.movetime;
    limits.mate = parsed.mate;
    limits.perft = parsed.perft;
    limits.infinite = parsed.infinite;
    limits.ponderMode = parsed.ponder_mode != 0;

    for (const auto& move : split_newlines(take_string_and_free(parsed.searchmoves)))
        limits.searchmoves.push_back(move);

    return limits;
}

void UCIEngine::go(std::istringstream& is) {

    Search::LimitsType limits = parse_limits(is);

    if (limits.perft)
        perft(limits);
    else
        engine.go(limits);
}

void UCIEngine::bench(std::istream& args) {
    std::string token;
    uint64_t    num, nodes = 0, cnt = 1;
    uint64_t    nodesSearched = 0;
    const auto& options       = engine.get_options();

    engine.set_on_update_full([&](const auto& i) {
        nodesSearched = i.nodes;
        on_update_full(i, options["UCI_ShowWDL"]);
    });

        const std::string benchmarkArgs = read_remaining_args(args);
        const std::string currentFen = engine.fen();
        const char* rendered = zfish_benchmark_setup_bench(
            reinterpret_cast<const unsigned char*>(currentFen.data()), currentFen.size(),
            reinterpret_cast<const unsigned char*>(benchmarkArgs.data()), benchmarkArgs.size());
        std::vector<std::string> list = split_newlines(take_string_and_free(rendered));

    num = count_if(list.begin(), list.end(),
                   [](const std::string& s) { return s.find("go ") == 0 || s.find("eval") == 0; });

    TimePoint elapsed = now();

    for (const auto& cmd : list)
    {
        std::istringstream is(cmd);
        is >> token;

        if (token == "go" || token == "eval")
        {
            std::cerr << "\nPosition: " << cnt++ << '/' << num << " (" << engine.fen() << ")"
                      << std::endl;
            if (token == "go")
            {
                Search::LimitsType limits = parse_limits(is);

                if (limits.perft)
                    nodesSearched = perft(limits);
                else
                {
                    engine.go(limits);
                    engine.wait_for_search_finished();
                }

                nodes += nodesSearched;
                nodesSearched = 0;
            }
            else
                engine.trace_eval();
        }
        else if (token == "setoption")
            setoption(is);
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
        {
            engine.search_clear();
            elapsed = now();
        }
    }

    elapsed = now() - elapsed + 1;

    dbg_print();

    std::cerr << "\n==========================="
              << "\nTotal time (ms) : " << elapsed
              << "\nNodes searched  : " << nodes
              << "\nNodes/second    : " << 1000 * nodes / elapsed << std::endl;

    engine.set_on_update_full([&](const auto& i) { on_update_full(i, options["UCI_ShowWDL"]); });
}

void UCIEngine::benchmark(std::istream& args) {
    static constexpr int NUM_WARMUP_POSITIONS = 3;

    std::string token;
    uint64_t    nodes = 0, cnt = 1;
    uint64_t    nodesSearched = 0;

    engine.set_on_update_full([&](const Engine::InfoFull& i) { nodesSearched = i.nodes; });

    engine.set_on_iter([](const auto&) {});
    engine.set_on_update_no_moves([](const auto&) {});
    engine.set_on_bestmove([](const auto&, const auto&) {});
    engine.set_on_verify_network([](const auto&) {});

        const std::string benchmarkArgs = read_remaining_args(args);
        const auto setupOutput = zfish_benchmark_setup_benchmark(
            reinterpret_cast<const unsigned char*>(benchmarkArgs.data()), benchmarkArgs.size(),
            static_cast<int>(get_hardware_concurrency()));

        Benchmark::BenchmarkSetup setup{};
        setup.ttSize = setupOutput.tt_size;
        setup.threads = setupOutput.threads;
        setup.commands = split_newlines(take_string_and_free(setupOutput.commands_ptr));
        setup.originalInvocation = take_string_and_free(setupOutput.original_invocation_ptr);
        setup.filledInvocation = take_string_and_free(setupOutput.filled_invocation_ptr);

    const auto numGoCommands = count_if(setup.commands.begin(), setup.commands.end(),
                                        [](const std::string& s) { return s.find("go ") == 0; });

    TimePoint totalTime = 0;

    auto ss = std::istringstream("name Threads value " + std::to_string(setup.threads));
    setoption(ss);
    ss = std::istringstream("name Hash value " + std::to_string(setup.ttSize));
    setoption(ss);
    ss = std::istringstream("name UCI_Chess960 value false");
    setoption(ss);

    for (const auto& cmd : setup.commands)
    {
        std::istringstream is(cmd);
        is >> token;

        if (token == "go")
        {
            std::cerr << "\rWarmup position " << cnt++ << '/' << NUM_WARMUP_POSITIONS;

            Search::LimitsType limits = parse_limits(is);
            engine.go(limits);
            engine.wait_for_search_finished();
        }
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
        {
            engine.search_clear();
        }

        if (cnt > NUM_WARMUP_POSITIONS)
            break;
    }

    std::cerr << "\n";

    cnt   = 1;
    nodes = 0;

    int           numHashfullReadings = 0;
    constexpr int hashfullAges[]      = {0, 999};
    constexpr int hashfullAgeCount    = std::size(hashfullAges);
    int           totalHashfull[hashfullAgeCount] = {0};
    int           maxHashfull[hashfullAgeCount]   = {0};

    auto updateHashfullReadings = [&]() {
        numHashfullReadings += 1;

        for (int i = 0; i < hashfullAgeCount; ++i)
        {
            const int hashfull = engine.get_hashfull(hashfullAges[i]);
            maxHashfull[i]     = std::max(maxHashfull[i], hashfull);
            totalHashfull[i] += hashfull;
        }
    };

    engine.search_clear();

    for (const auto& cmd : setup.commands)
    {
        std::istringstream is(cmd);
        is >> token;

        if (token == "go")
        {
            std::cerr << "\rPosition " << cnt++ << '/' << numGoCommands;

            Search::LimitsType limits = parse_limits(is);

            nodesSearched     = 0;
            TimePoint elapsed = now();

            engine.go(limits);
            engine.wait_for_search_finished();

            totalTime += now() - elapsed;

            updateHashfullReadings();

            nodes += nodesSearched;
        }
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
        {
            engine.search_clear();
        }
    }

    totalTime = std::max<TimePoint>(totalTime, 1);

    dbg_print();

    std::cerr << "\n";

    static_assert(
      std::size(hashfullAges) == 2 && hashfullAges[0] == 0 && hashfullAges[1] == 999,
      "Hardcoded for display. Would complicate the code needlessly in the current state.");

    std::string threadBinding = engine.thread_binding_information_as_string();
    if (threadBinding.empty())
        threadBinding = "none";

    std::cerr << "==========================="
              << "\nVersion                    : "
              << engine_version_info() << compiler_info()
              << "Large pages                : " << (has_large_pages() ? "yes" : "no")
              << "\nUser invocation            : " << BenchmarkCommand << " "
              << setup.originalInvocation << "\nFilled invocation          : " << BenchmarkCommand
              << " " << setup.filledInvocation
              << "\nAvailable processors       : " << engine.get_numa_config_as_string()
              << "\nThread count               : " << setup.threads
              << "\nThread binding             : " << threadBinding
              << "\nTT size [MiB]              : " << setup.ttSize
              << "\nHash max, avg [per mille]  : "
              << "\n    single search          : " << maxHashfull[0] << ", "
              << totalHashfull[0] / numHashfullReadings
              << "\n    single game            : " << maxHashfull[1] << ", "
              << totalHashfull[1] / numHashfullReadings
              << "\nTotal nodes searched       : " << nodes
              << "\nTotal search time [s]      : " << totalTime / 1000.0
              << "\nNodes/second               : " << 1000 * nodes / totalTime << std::endl;

    init_search_update_listeners();
}

void UCIEngine::setoption(std::istringstream& is) {
    engine.wait_for_search_finished();
    engine.get_options().setoption(is);
}

std::uint64_t UCIEngine::perft(const Search::LimitsType& limits) {
    auto nodes = engine.perft(engine.fen(), limits.perft, engine.get_options()["UCI_Chess960"]);
    sync_cout << "\nNodes searched: " << nodes << "\n" << sync_endl;
    return nodes;
}

void UCIEngine::position(std::istringstream& is) {
    const std::string fullCommand = is.str();
    const auto parsed = zfish_uci_parse_position(
      reinterpret_cast<const unsigned char*>(fullCommand.data()), fullCommand.size());
    if (!parsed.ok)
        return;

    const auto fen = take_string_and_free(parsed.fen);
    std::vector<std::string> moves = split_newlines(take_string_and_free(parsed.moves));

    auto err = engine.set_position(fen, moves);
    if (err.has_value())
    {
        terminate_on_critical_error(fullCommand, err->what());
    }
}

std::string UCIEngine::format_score(const Score& s) {
    return s.visit(overload{[](Score::Mate mate) -> std::string {
                                return take_string_and_free(zfish_uci_format_score(0, mate.plies, 0));
                            },
                            [](Score::Tablebase tb) -> std::string {
                                return take_string_and_free(
                                  zfish_uci_format_score(1, tb.plies, tb.win ? 1 : 0));
                            },
                            [](Score::InternalUnits units) -> std::string {
                                return take_string_and_free(
                                  zfish_uci_format_score(2, units.value, 0));
                            }});
}

int UCIEngine::to_cp(Value v, const Position& pos) {
    return zfish_uci_to_cp(v, material_count(pos));
}

std::string UCIEngine::wdl(Value v, const Position& pos) {
    return take_string_and_free(zfish_uci_wdl(v, material_count(pos)));
}

std::string UCIEngine::square(Square s) {
    return take_string_and_free(
      zfish_uci_format_square(static_cast<std::uint8_t>(file_of(s)), static_cast<std::uint8_t>(rank_of(s))));
}

std::string UCIEngine::move(Move m, bool chess960) {
    if (m == Move::none())
        return "(none)";

    if (m == Move::null())
        return "0000";

    Square from = m.from_sq();
    Square to   = m.to_sq();

    if (m.type_of() == CASTLING && !chess960)
        to = make_square(to > from ? FILE_G : FILE_C, rank_of(from));

    const auto promotion = m.type_of() == PROMOTION ? static_cast<std::uint8_t>(" pnbrqk"[m.promotion_type()]) : 0;

    return take_string_and_free(zfish_uci_format_move(static_cast<std::uint8_t>(file_of(from)),
                                                      static_cast<std::uint8_t>(rank_of(from)),
                                                      static_cast<std::uint8_t>(file_of(to)),
                                                      static_cast<std::uint8_t>(rank_of(to)),
                                                      promotion));
}

std::string UCIEngine::to_lower(std::string str) {
    return take_string_and_free(
      zfish_uci_to_lower(reinterpret_cast<const unsigned char*>(str.data()), str.size()));
}

Move UCIEngine::to_move(const Position& pos, std::string str) {
    str = to_lower(str);

    for (const auto& m : MoveList<LEGAL>(pos))
        if (str == move(m, pos.is_chess960()))
            return m;

    return Move::none();
}

void UCIEngine::on_update_no_moves(const Engine::InfoShort& info) {
    const auto score = format_score(info.score);
    sync_cout << take_string_and_free(zfish_uci_format_info_no_moves(
                   info.depth, reinterpret_cast<const unsigned char*>(score.data()), score.size()))
              << sync_endl;
}

void UCIEngine::on_update_full(const Engine::InfoFull& info, bool showWDL) {
    const auto score = format_score(info.score);
    sync_cout << take_string_and_free(zfish_uci_format_info_full(
                   info.depth, info.selDepth, info.multiPV,
                   reinterpret_cast<const unsigned char*>(score.data()), score.size(),
                   reinterpret_cast<const unsigned char*>(info.bound.data()), info.bound.size(),
                   reinterpret_cast<const unsigned char*>(info.wdl.data()), info.wdl.size(),
                   static_cast<std::uint8_t>(showWDL ? 1 : 0), info.nodes, info.nps, info.hashfull,
                   info.tbHits, info.timeMs, reinterpret_cast<const unsigned char*>(info.pv.data()),
                   info.pv.size()))
              << sync_endl;
}

void UCIEngine::on_iter(const Engine::InfoIter& info) {
    sync_cout
      << take_string_and_free(zfish_uci_format_info_iter(
           info.depth, reinterpret_cast<const unsigned char*>(info.currmove.data()),
           info.currmove.size(), info.currmovenumber))
      << sync_endl;
}

void UCIEngine::on_bestmove(std::string_view bestmove, std::string_view ponder) {
    sync_cout << take_string_and_free(zfish_uci_format_bestmove(
                   reinterpret_cast<const unsigned char*>(bestmove.data()), bestmove.size(),
                   reinterpret_cast<const unsigned char*>(ponder.data()), ponder.size()))
              << sync_endl;
}

void UCIEngine::terminate_on_critical_error(const std::string& fullCommand,
                                            const std::string& message) {
    sync_cout << take_string_and_free(zfish_uci_format_critical_error(
                   reinterpret_cast<const unsigned char*>(fullCommand.data()), fullCommand.size(),
                   reinterpret_cast<const unsigned char*>(message.data()), message.size()))
              << sync_endl;
    std::exit(1);
}

bool Tune::update_on_last;
OptionsMap* Tune::options;

bool CaseInsensitiveLess::operator()(const std::string& left, const std::string& right) const {
    return zfish_option_case_insensitive_less(
      reinterpret_cast<const unsigned char*>(left.data()), left.size(),
      reinterpret_cast<const unsigned char*>(right.data()), right.size());
}

void OptionsMap::add_info_listener(InfoListener&& message_func) {
    info = std::move(message_func);
}

void OptionsMap::setoption(std::istringstream& is) {
    std::string rest;
    std::getline(is, rest);

    const auto parsed = zfish_option_parse_setoption(
      reinterpret_cast<const unsigned char*>(rest.data()), rest.size());
    const auto name  = take_string_and_free(parsed.name);
    const auto value = take_string_and_free(parsed.value);

    if (options_map.count(name))
        options_map[name] = value;
    else
        sync_cout << "No such option: " << name << sync_endl;
}

const Option& OptionsMap::operator[](const std::string& name) const {
    auto it = options_map.find(name);
    assert(it != options_map.end());
    return it->second;
}

void OptionsMap::add(const std::string& name, const Option& option) {
    if (!options_map.count(name))
    {
        static size_t insert_order = 0;

        options_map[name] = option;

        options_map[name].parent = this;
        options_map[name].idx    = insert_order++;
    }
    else
    {
        std::cerr << "Option \"" << name << "\" was already added!" << std::endl;
        std::exit(EXIT_FAILURE);
    }
}

std::size_t OptionsMap::count(const std::string& name) const { return options_map.count(name); }

Option::Option(const OptionsMap* map) :
    parent(map) {}

Option::Option(const char* value, OnChange onChange) :
    type("string"),
    min(0),
    max(0),
    on_change(std::move(onChange)) {
    defaultValue = currentValue = value;
}

Option::Option(bool value, OnChange onChange) :
    type("check"),
    min(0),
    max(0),
    on_change(std::move(onChange)) {
    defaultValue = currentValue = (value ? "true" : "false");
}

Option::Option(OnChange onChange) :
    type("button"),
    min(0),
    max(0),
    on_change(std::move(onChange)) {}

Option::Option(int value, int minv, int maxv, OnChange onChange) :
    type("spin"),
    min(minv),
    max(maxv),
    on_change(std::move(onChange)) {
    defaultValue = currentValue = std::to_string(value);
}

Option::Option(const char* value, const char* current, OnChange onChange) :
    type("combo"),
    min(0),
    max(0),
    on_change(std::move(onChange)) {
    defaultValue = value;
    currentValue = current;
}

Option::operator int() const {
    assert(type == "check" || type == "spin");
    return type == "spin" ? std::stoi(currentValue) : currentValue == "true";
}

Option::operator std::string() const {
    assert(type == "string");
    return currentValue;
}

bool Option::operator==(const char* value) const {
    assert(type == "combo");
    return zfish_option_combo_equals(
      reinterpret_cast<const unsigned char*>(currentValue.data()), currentValue.size(),
      reinterpret_cast<const unsigned char*>(value), std::char_traits<char>::length(value));
}

bool Option::operator!=(const char* value) const { return !(*this == value); }

Option& Option::operator=(const std::string& value) {
    assert(!type.empty());

    const auto result = zfish_option_validate_assignment(
      reinterpret_cast<const unsigned char*>(type.data()), type.size(),
      reinterpret_cast<const unsigned char*>(value.data()), value.size(), min, max,
      reinterpret_cast<const unsigned char*>(defaultValue.data()), defaultValue.size());

    if (!result.accepted)
        return *this;

    if (type != "button")
        currentValue = take_string_and_free(result.normalized_value);

    if (on_change)
    {
        const auto ret = on_change(*this);

        if (ret && parent != nullptr && parent->info != nullptr)
            parent->info(ret);
    }

    return *this;
}

std::ostream& operator<<(std::ostream& os, const OptionsMap& optionsMap) {
    for (size_t idx = 0; idx < optionsMap.options_map.size(); ++idx)
        for (const auto& it : optionsMap.options_map)
            if (it.second.idx == idx)
            {
                const Option& option = it.second;
                os << "\noption name " << it.first << " type " << option.type;

                if (option.type == "check" || option.type == "combo")
                    os << " default " << option.defaultValue;
                else if (option.type == "string")
                    os << " default "
                       << (option.defaultValue.empty() ? "<empty>" : option.defaultValue);
                else if (option.type == "spin")
                    os << " default " << stoi(option.defaultValue) << " min " << option.min
                       << " max " << option.max;

                break;
            }

    return os;
}

void Tune::make_option(OptionsMap* opts, const std::string& name, int value, const SetRange& range) {
    const auto bounds = range(value);
    if (!zfish_tune_should_make_option(bounds.first, bounds.second))
        return;

    if (TuneResults.count(name))
        value = TuneResults[name];

    opts->add(name, Option(value, bounds.first, bounds.second, on_tune));
    LastOption = &((*opts)[name]);

    std::cout << name << ","                                 \
              << value << ","                                \
              << bounds.first << ","                         \
              << bounds.second << ","                        \
              << (bounds.second - bounds.first) / 20.0 << "," \
              << "0.0020" << std::endl;
}

std::string Tune::next(std::string& names, bool pop) {
    const auto result = zfish_tune_next(reinterpret_cast<const unsigned char*>(names.data()),
                                        names.size(), static_cast<std::uint8_t>(pop ? 1 : 0));
    const auto token = take_string_and_free(result.token);
    names            = take_string_and_free(result.remaining);
    return token;
}

template<>
void Tune::Entry<int>::init_option() {
    make_option(options, name, value, range);
}

template<>
void Tune::Entry<int>::read_option() {
    if (options->count(name))
        value = int((*options)[name]);
}

template<>
void Tune::Entry<Tune::PostUpdate>::init_option() {}

template<>
void Tune::Entry<Tune::PostUpdate>::read_option() {
    value();
}

void Tune::read_results() { /* ...insert your values here... */ }

Score::Score(Value v, const Position& pos) {
        assert(-VALUE_INFINITE < v && v < VALUE_INFINITE);

        const auto score_class =
            zfish_classify_score(v, VALUE_TB_WIN_IN_MAX_PLY, VALUE_TB, VALUE_MATE);

        switch (score_class.kind)
        {
        case 0 : score = InternalUnits{UCIEngine::to_cp(v, pos)}; break;
        case 1 : score = Tablebase{score_class.plies, score_class.win != 0}; break;
        case 2 : score = Mate{score_class.plies}; break;
        default : std::abort();
        }
}

}  // namespace Stockfish

namespace {

struct ZfishUciRuntimeHandle {
    std::vector<std::string>      ownedArgv;
    std::vector<char*>            mutableArgv;
    std::unique_ptr<Stockfish::UCIEngine> uci;
};

}  // namespace

extern "C" {
void* zfish_uci_create_runtime(int argc, const char* const* argv) {
    auto runtime = std::make_unique<ZfishUciRuntimeHandle>();
    runtime->ownedArgv.reserve(static_cast<std::size_t>(argc));
    runtime->mutableArgv.reserve(static_cast<std::size_t>(argc));

    for (int i = 0; i < argc; ++i)
        runtime->ownedArgv.emplace_back(argv[i] ? argv[i] : "");

    for (auto& arg : runtime->ownedArgv)
        runtime->mutableArgv.push_back(arg.data());

    runtime->uci = std::make_unique<Stockfish::UCIEngine>(argc, runtime->mutableArgv.data());
    Stockfish::Tune::init(runtime->uci->engine_options());
    return runtime.release();
}

void zfish_uci_loop_runtime(void* runtime_ptr) {
    static_cast<ZfishUciRuntimeHandle*>(runtime_ptr)->uci->loop();
}

void zfish_uci_destroy_runtime(void* runtime_ptr) {
    delete static_cast<ZfishUciRuntimeHandle*>(runtime_ptr);
}
}
