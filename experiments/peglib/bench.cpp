// In-process parser benchmark: cpp-peglib on the translated DuckDB grammar, DuckDB's PEG parser and (optionally)
// the PostgreSQL-derived legacy parser, on the same input strings with the same timer.
//
// Variants are grouped by what they produce, because only variants at the same level are comparable:
//   recognize   accept/reject only            peglib, duckdb
//   tree        generic parse tree            peglib (enable_ast), duckdb (matcher parse results),
//                                             postgres (libpg_query node tree)
//   ast         DuckDB SQLStatement objects   duckdb (matcher + transformer), postgres (libpg_query + transformer)
//   tokenize    DuckDB tokenizer only, as a reference for how much of the token-based parsers is lexing
//
// Output: CSV on stdout (or --out), one row per (corpus, input, variant), plus grammar construction rows.
#include "peglib.h"

#include "duckdb.hpp"
#include "duckdb/parser/parser.hpp"
#ifdef DUCKDB_PARSER_PHASES
// Internal headers: these follow DuckDB's parser internals and may need adjusting when the submodule moves.
// Build with PHASES=0 to drop them and keep only the public Parser entry point.
#include "duckdb/parser/peg/compiled_grammar.hpp"
#include "duckdb/parser/peg/matcher.hpp"
#include "duckdb/parser/peg/parser_packrat.hpp"
#include "duckdb/parser/peg/tokenizer/parser_tokenizer.hpp"
#include "duckdb/parser/token_iterator.hpp"
#endif
#ifdef LEGACY_PG_QUERY
// libpg_query as vendored by the duckdb-legacy-parser extension, linked directly for the raw parse-tree level
#include "postgres_parser.hpp"
#endif

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;

static double ElapsedNs(Clock::time_point start) {
	return std::chrono::duration<double, std::nano>(Clock::now() - start).count();
}

static std::string ReadFile(const fs::path &path) {
	std::ifstream in(path, std::ios::binary);
	if (!in) {
		throw std::runtime_error("cannot open " + path.string());
	}
	std::stringstream buffer;
	buffer << in.rdbuf();
	return buffer.str();
}

static double Median(std::vector<double> values) {
	std::sort(values.begin(), values.end());
	auto n = values.size();
	return n % 2 ? values[n / 2] : (values[n / 2 - 1] + values[n / 2]) / 2;
}

struct Input {
	std::string corpus;
	std::string name;
	std::string sql;
	size_t tokens = 0;
};

struct Variant {
	std::string engine;
	std::string level;
	std::string config;
	//! Parse one input; returns whether it was accepted
	std::function<bool(const std::string &)> run;
};

struct Options {
	std::string grammar_path;
	std::string legacy_extension;
	std::string out_path;
	std::vector<std::pair<std::string, std::string>> corpora;
	int rounds = 7;
	//! Each timed sample repeats the parse until it lasted at least this long
	double min_sample_ms = 2;
	//! Inputs on which a variant needs longer than this for one parse are measured with a single repetition
	double slow_parse_ms = 250;
	int grammar_rounds = 5;
};

static Options ParseArguments(int argc, char **argv) {
	Options options;
	for (int i = 1; i < argc; i++) {
		std::string arg = argv[i];
		auto next = [&]() -> std::string {
			if (i + 1 >= argc) {
				throw std::runtime_error("missing value for " + arg);
			}
			return argv[++i];
		};
		if (arg == "--grammar") {
			options.grammar_path = next();
		} else if (arg == "--corpus") {
			// name=path, where path is a directory of .sql files (one input each) or a single file
			auto value = next();
			auto eq = value.find('=');
			if (eq == std::string::npos) {
				throw std::runtime_error("--corpus expects name=path");
			}
			options.corpora.emplace_back(value.substr(0, eq), value.substr(eq + 1));
		} else if (arg == "--legacy-extension") {
			options.legacy_extension = next();
		} else if (arg == "--rounds") {
			options.rounds = std::stoi(next());
		} else if (arg == "--min-sample-ms") {
			options.min_sample_ms = std::stod(next());
		} else if (arg == "--out") {
			options.out_path = next();
		} else {
			throw std::runtime_error("unknown argument " + arg);
		}
	}
	if (options.grammar_path.empty() || options.corpora.empty()) {
		throw std::runtime_error("usage: bench --grammar duckdb.peg --corpus name=path [--corpus ...] "
		                         "[--legacy-extension path] [--rounds N] [--min-sample-ms X] [--out file.csv]");
	}
	return options;
}

static std::vector<Input> LoadCorpora(const Options &options) {
	std::vector<Input> inputs;
	for (auto &corpus : options.corpora) {
		std::vector<fs::path> files;
		if (fs::is_directory(corpus.second)) {
			for (auto &entry : fs::directory_iterator(corpus.second)) {
				if (entry.path().extension() == ".sql") {
					files.push_back(entry.path());
				}
			}
			std::sort(files.begin(), files.end());
		} else {
			files.push_back(corpus.second);
		}
		for (auto &file : files) {
			auto sql = ReadFile(file);
			if (sql.find_first_not_of(" \t\r\n") == std::string::npos) {
				continue;
			}
			inputs.push_back({corpus.first, file.stem().string(), std::move(sql)});
		}
	}
	return inputs;
}

//===--------------------------------------------------------------------===//
// cpp-peglib
//===--------------------------------------------------------------------===//
static std::unique_ptr<peg::parser> LoadPeglib(const std::string &grammar, bool packrat, bool ast) {
	auto parser = std::make_unique<peg::parser>();
	std::string errors;
	parser->set_logger([&](size_t line, size_t col, const std::string &msg, const std::string &rule) {
		if (msg.find("is not referenced") == std::string::npos) {
			errors += std::to_string(line) + ":" + std::to_string(col) + ": " + msg + " " + rule + "\n";
		}
	});
	if (!parser->load_grammar(grammar.data(), grammar.size())) {
		throw std::runtime_error("cpp-peglib rejected the grammar:\n" + errors);
	}
	// parse errors are expected to be silent while benchmarking
	parser->set_logger([](size_t, size_t, const std::string &, const std::string &) {});
	if (packrat) {
		parser->enable_packrat_parsing();
	}
	if (ast) {
		parser->enable_ast();
	}
	return parser;
}

//===--------------------------------------------------------------------===//
// DuckDB
//===--------------------------------------------------------------------===//
static bool DuckDBParse(duckdb::ClientContext &context, const std::string &sql) {
	try {
		duckdb::Parser parser(context);
		parser.ParseQuery(sql);
		return !parser.statements.empty();
	} catch (std::exception &) {
		return false;
	}
}

#ifdef DUCKDB_PARSER_PHASES
static size_t DuckDBTokenize(const duckdb::CompiledGrammar &grammar, const std::string &sql) {
	duckdb::vector<duckdb::MatcherToken> tokens;
	duckdb::ParserTokenizerBehavior behavior(sql, tokens);
	grammar.GetTokenizer().TokenizeInput(behavior);
	return tokens.size();
}

//! Tokenizer + matcher, without the transformer; mirrors PEGTransformerFactory::TransformTopLevelStatement
static bool DuckDBMatch(const duckdb::CompiledGrammar &grammar, const std::string &sql, duckdb::MatchMode mode) {
	using namespace duckdb;
	try {
		auto owned_tokens = make_uniq<vector<MatcherToken>>();
		ParserTokenizerBehavior behavior(sql, *owned_tokens);
		grammar.GetTokenizer().TokenizeInput(behavior);
		TokenIterator token_iterator(std::move(owned_tokens));
		while (token_iterator.Current()) {
			vector<MatcherSuggestion> suggestions;
			ParseResultAllocator parse_result_allocator;
			idx_t max_token_index = token_iterator.Position();
			ArenaAllocator process_allocator(Allocator::DefaultAllocator());
			ArenaAllocator packrat_allocator(Allocator::DefaultAllocator());
			ParserPackratCache packrat_cache(packrat_allocator, token_iterator.Position(), token_iterator.Size());
			MatchContext match_context(suggestions, parse_result_allocator, process_allocator, max_token_index, mode,
			                           IdentifierCaseMode::PRESERVE_CASE, &packrat_cache);
			MatchState state(token_iterator, match_context);
			auto match_result = grammar.TopLevelStatementMatcher().MatchParseResult(state);
			if (!match_result.IsSuccess()) {
				return false;
			}
			token_iterator.SetPosition(state.token_iterator);
		}
		return true;
	} catch (std::exception &) {
		return false;
	}
}
#endif

//! Load the legacy_parser extension and make it the parser of this database (the setting is database-wide,
//! which is why the legacy variant runs in its own DuckDB instance)
static void EnableLegacyParser(duckdb::Connection &con, const std::string &extension_path) {
	for (auto &query : {"LOAD '" + extension_path + "'", std::string("SET GLOBAL enable_legacy_parser = true")}) {
		auto result = con.Query(query);
		if (result->HasError()) {
			throw std::runtime_error(query + ": " + result->GetError());
		}
	}
}

//===--------------------------------------------------------------------===//
// Measurement
//===--------------------------------------------------------------------===//
struct Measurement {
	bool accepted = false;
	int repetitions = 0;
	std::vector<double> samples_ns;
};

int main(int argc, char **argv) {
	try {
		auto options = ParseArguments(argc, argv);
		auto inputs = LoadCorpora(options);
		auto peg_grammar = ReadFile(options.grammar_path);

		FILE *out = options.out_path.empty() ? stdout : fopen(options.out_path.c_str(), "w");
		if (!out) {
			throw std::runtime_error("cannot write " + options.out_path);
		}
		fprintf(out, "corpus,input,bytes,tokens,engine,level,config,accepted,repetitions,median_ns,min_ns\n");

		//===--------------------------------------------------------------------===//
		// Grammar construction (what a grammar change costs at load time)
		//===--------------------------------------------------------------------===//
		{
			std::vector<double> samples;
			for (int i = 0; i < options.grammar_rounds; i++) {
				auto start = Clock::now();
				auto parser = LoadPeglib(peg_grammar, false, false);
				samples.push_back(ElapsedNs(start));
			}
			fprintf(out, "__grammar__,construct,%zu,0,peglib,grammar,text to parser,1,1,%.0f,%.0f\n",
			        peg_grammar.size(), Median(samples), *std::min_element(samples.begin(), samples.end()));
		}
#ifdef DUCKDB_PARSER_PHASES
		{
			std::vector<double> samples;
			for (int i = 0; i < options.grammar_rounds; i++) {
				auto start = Clock::now();
				auto grammar = duckdb::CompiledGrammar::Create();
				samples.push_back(ElapsedNs(start));
			}
			fprintf(out, "__grammar__,construct,0,0,duckdb,grammar,CompiledGrammar::Create,1,1,%.0f,%.0f\n",
			        Median(samples), *std::min_element(samples.begin(), samples.end()));
		}
#endif

		//===--------------------------------------------------------------------===//
		// Variants
		//===--------------------------------------------------------------------===//
		auto peglib_plain = LoadPeglib(peg_grammar, false, false);
		auto peglib_packrat = LoadPeglib(peg_grammar, true, false);
		auto peglib_ast = LoadPeglib(peg_grammar, true, true);

		duckdb::DBConfig config;
		config.SetOptionByName("allow_unsigned_extensions", duckdb::Value::BOOLEAN(true));
		duckdb::DuckDB db(nullptr, &config);
		duckdb::Connection peg_con(db);
		// warm up: the connection compiles/caches its grammar on first use
		DuckDBParse(*peg_con.context, "SELECT 1");

		std::vector<Variant> variants;
		variants.push_back({"peglib", "recognize", "no packrat", [&](const std::string &sql) {
			                    return peglib_plain->parse_n(sql.data(), sql.size());
		                    }});
		variants.push_back({"peglib", "recognize", "packrat", [&](const std::string &sql) {
			                    return peglib_packrat->parse_n(sql.data(), sql.size());
		                    }});
		variants.push_back({"peglib", "tree", "packrat", [&](const std::string &sql) {
			                    std::shared_ptr<peg::Ast> ast;
			                    return peglib_ast->parse_n(sql.data(), sql.size(), ast);
		                    }});
#ifdef DUCKDB_PARSER_PHASES
		auto duckdb_grammar = duckdb::CompiledGrammar::DefaultGrammar();
		for (auto &input : inputs) {
			input.tokens = DuckDBTokenize(*duckdb_grammar, input.sql);
		}
		variants.push_back({"duckdb", "tokenize", "", [&](const std::string &sql) {
			                    return DuckDBTokenize(*duckdb_grammar, sql) > 0;
		                    }});
		variants.push_back({"duckdb", "recognize", "", [&](const std::string &sql) {
			                    return DuckDBMatch(*duckdb_grammar, sql, duckdb::MatchMode::RECOGNIZE_ONLY);
		                    }});
		variants.push_back({"duckdb", "tree", "", [&](const std::string &sql) {
			                    return DuckDBMatch(*duckdb_grammar, sql, duckdb::MatchMode::BUILD_PARSE_RESULT);
		                    }});
#endif
		variants.push_back(
		    {"duckdb", "ast", "", [&](const std::string &sql) { return DuckDBParse(*peg_con.context, sql); }});

#ifdef LEGACY_PG_QUERY
		variants.push_back({"postgres", "tree", "libpg_query", [&](const std::string &sql) {
			                    duckdb::PostgresParser parser;
			                    parser.Parse(sql);
			                    return parser.success;
		                    }});
#endif
		std::unique_ptr<duckdb::DuckDB> legacy_db;
		std::unique_ptr<duckdb::Connection> legacy_con;
		if (!options.legacy_extension.empty()) {
			legacy_db = std::make_unique<duckdb::DuckDB>(nullptr, &config);
			legacy_con = std::make_unique<duckdb::Connection>(*legacy_db);
			EnableLegacyParser(*legacy_con, options.legacy_extension);
			variants.push_back({"postgres", "ast", "legacy_parser extension", [&](const std::string &sql) {
				                    return DuckDBParse(*legacy_con->context, sql);
			                    }});
		}

		//===--------------------------------------------------------------------===//
		// Calibrate, then measure in interleaved rounds
		//===--------------------------------------------------------------------===//
		std::vector<std::vector<Measurement>> results(inputs.size(), std::vector<Measurement>(variants.size()));
		for (size_t i = 0; i < inputs.size(); i++) {
			for (size_t v = 0; v < variants.size(); v++) {
				auto &m = results[i][v];
				// first call doubles as warm-up and acceptance check
				m.accepted = variants[v].run(inputs[i].sql);
				auto start = Clock::now();
				variants[v].run(inputs[i].sql);
				auto single_ns = std::max(ElapsedNs(start), 1.0);
				if (single_ns > options.slow_parse_ms * 1e6) {
					m.repetitions = 1;
				} else {
					m.repetitions = std::max(1, static_cast<int>(options.min_sample_ms * 1e6 / single_ns));
				}
			}
		}
		for (int round = 0; round < options.rounds; round++) {
			for (size_t i = 0; i < inputs.size(); i++) {
				for (size_t v = 0; v < variants.size(); v++) {
					auto &m = results[i][v];
					auto &sql = inputs[i].sql;
					auto &run = variants[v].run;
					auto start = Clock::now();
					for (int r = 0; r < m.repetitions; r++) {
						run(sql);
					}
					m.samples_ns.push_back(ElapsedNs(start) / m.repetitions);
				}
			}
			fprintf(stderr, "round %d/%d done\n", round + 1, options.rounds);
		}

		for (size_t i = 0; i < inputs.size(); i++) {
			for (size_t v = 0; v < variants.size(); v++) {
				auto &m = results[i][v];
				fprintf(out, "%s,%s,%zu,%zu,%s,%s,%s,%d,%d,%.0f,%.0f\n", inputs[i].corpus.c_str(),
				        inputs[i].name.c_str(), inputs[i].sql.size(), inputs[i].tokens, variants[v].engine.c_str(),
				        variants[v].level.c_str(), variants[v].config.c_str(), m.accepted ? 1 : 0, m.repetitions,
				        Median(m.samples_ns), *std::min_element(m.samples_ns.begin(), m.samples_ns.end()));
			}
		}
		if (out != stdout) {
			fclose(out);
		}
		return 0;
	} catch (std::exception &e) {
		std::cerr << "error: " << e.what() << "\n";
		return 1;
	}
}
