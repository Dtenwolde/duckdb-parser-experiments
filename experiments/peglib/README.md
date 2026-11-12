# Parser-vs-parser benchmark: cpp-peglib, DuckDB PEG, PostgreSQL parser

Question: on the same grammar and the same queries, how does DuckDB's PEG parser compare with a general-purpose
PEG library (cpp-peglib, the engine of the CIDR 2025 prototype) and with the PostgreSQL-derived parser it replaced?

Run with `./run.sh`. Everything is generated from the checked-out `duckdb` submodule, so the benchmark follows a
moving DuckDB commit; results are written to `results/duckdb-<commit>.csv`.

## What is compared

| Engine | What runs | Grammar |
|---|---|---|
| `peglib` | cpp-peglib (pinned submodule `third_party/cpp-peglib`), scannerless | DuckDB's `.gram` rules, translated by `gram2peglib.py` |
| `duckdb` | DuckDB's tokenizer, matcher and transformer, from `duckdb/build/release/src/libduckdb.dylib` | `inlined_grammar.gram` as shipped |
| `postgres` | libpg_query (flex + bison) as vendored by the `legacy_parser` extension that the DuckDB commit pins | PostgreSQL-derived yacc grammar |

The engines do not produce the same thing, so variants are grouped by output level and only compared within a level:

| Level | peglib | duckdb | postgres |
|---|---|---|---|
| `recognize` (accept/reject) | no semantic actions, with and without packrat | matcher in `RECOGNIZE_ONLY` mode | n/a |
| `tree` (generic parse tree) | `enable_ast()`, packrat | matcher building parse results | `PostgresParser::Parse` (PG node tree), linked directly |
| `ast` (DuckDB `SQLStatement`s) | n/a | `Parser::ParseQuery` | `Parser::ParseQuery` in a database with `enable_legacy_parser` |
| `tokenize` | n/a (scannerless) | tokenizer only, for reference | n/a |

`report.py` gives ratios against DuckDB PEG at the same level. For `recognize` the reference is DuckDB's `tree`
path: `RECOGNIZE_ONLY` is the mode autocomplete uses and measures about 3.4x slower than building the parse tree,
so it is not DuckDB's fastest way to answer accept/reject.

## How the timing is kept fair

- **One process, one timer, the same strings.** `bench.cpp` links all three engines and times a call that takes the
  SQL text and returns when the output for that level exists. No binding, planning or execution, no CLI start-up.
- **Not the DuckDB profiler.** The profiler's `parser` metric is the right tool for parse share of end-to-end
  latency (`scripts/benchmark_parser.sh`), but cpp-peglib cannot be hosted behind it and it cannot split
  tokenizer / matcher / transformer.
- **Same build settings.** The harness is compiled with `-O3 -DNDEBUG`, as DuckDB's release build is, with the
  same compiler; libduckdb and libpg_query come from the same DuckDB build tree and commit. `run.sh` refuses to run
  if the build was made from a different commit than the submodule is on.
- **Interleaved rounds, medians.** Every input and variant is warmed up and checked for acceptance, then measured in
  7 rounds (default) that cycle through all variants; a sample repeats the parse until it lasted at least 2 ms. The
  CSV has the median and the minimum per (input, variant).
- **Grammar construction is separate.** Text-to-ready-parser time is reported once per engine and never included in
  parse times. This is the cost an extension pays when it changes the grammar.
- **No error bookkeeping in cpp-peglib.** The parsers run without a logger; with one installed cpp-peglib tracks
  expected tokens on every failed match, which costs it 15-20%.
- **Acceptance is checked, not assumed.** A variant that rejects an input shows up in the `accepted` column.

Known asymmetries that remain:

- The `postgres/ast` path goes through the parser-override hook (one setting lookup and a copy of the query string
  per call). The `postgres/tree` variant has no such overhead.
- cpp-peglib's generic AST and DuckDB's parse results are different data structures; `tree` compares "some tree
  that a transformer could consume", not identical output.
- Single-threaded, warm caches, default allocator on macOS.

## Translating the grammar (`gram2peglib.py`)

DuckDB's `.gram` syntax descends from cpp-peglib's, so rule bodies and the `List(D)` / `Parens(D)` macros carry over
unchanged (1,172 rules at d71c926). DuckDB matches tokens, cpp-peglib characters, so everything DuckDB does outside
the grammar text is re-expressed as PEG rules:

- **Keyword literals** become case-insensitive literals with a `%word` boundary.
- **Operator literals** become token rules that emulate the tokenizer's maximal munch, including the PostgreSQL rule
  that splits trailing `+`/`-` off an operator (`a<-1` is `<`, `-`).
- **Terminal rule overrides** (identifier classes, string, number and operator literals) are generated from
  `scripts/parser/grammar_types.yml`. The keyword masks of `IdentifierMatcher` become negative lookaheads over the
  excluded keywords, e.g. `Identifier <- QuotedIdentifier / < !KeywordsExcludedFromColName WordBody >`.
- **Whitespace and comments** go into `%whitespace`.
- **`Program`** is rewritten to `(Statement? ';'+)* Statement? EndOfInput`, because cpp-peglib rejects the
  zero-width repetition in `TopLevelStatement*`.
- Choices between keywords (the keyword category rules and the exclusion sets) use cpp-peglib's trie dictionaries
  (`'A'i | 'B'i`), which is the tuned form of the same language: 19.7 ms to 14.3 ms on TPC-H. `--no-dictionary`
  emits plain ordered choices.

Approximations: string continuation across newlines is accepted but dollar-quote tags are limited to ASCII;
numbers do not cover every tokenizer corner (`1.` followed by an identifier); `--` or `/*` directly after an
operator character. None of these occur in the corpora, and all engines agree on accept/reject for every input.

## Results

Apple M5 Pro, macOS 26.7, 2026-11-12, DuckDB `d71c926f43` (moving; performance work is ongoing), cpp-peglib v1.9.1,
legacy_parser `bcdf276`. Totals over all inputs of a corpus, median of 7 rounds.

| corpus | engine | output | config | accepted | total ms | ns/token | vs DuckDB PEG |
|---|---|---|---|---|---|---|---|
| tpch | peglib | recognize | no packrat | 22/22 | 32.137 | 16182 | 26.53x |
| tpch | peglib | recognize | packrat | 22/22 | 14.310 | 7205 | 11.81x |
| tpch | peglib | tree | packrat | 22/22 | 17.806 | 8966 | 14.70x |
| tpch | duckdb | tokenize |  | 22/22 | 0.074 | 37 |  |
| tpch | duckdb | recognize |  | 22/22 | 4.108 | 2069 | 3.39x |
| tpch | duckdb | tree |  | 22/22 | 1.212 | 610 | 1.00x |
| tpch | duckdb | ast |  | 22/22 | 1.579 | 795 | 1.00x |
| tpch | postgres | tree | libpg_query | 22/22 | 0.138 | 70 | 0.11x |
| tpch | postgres | ast | legacy_parser extension | 22/22 | 0.298 | 150 | 0.19x |
| tpcds | peglib | recognize | no packrat | 99/99 | 567.533 | 23797 | 41.77x |
| tpcds | peglib | recognize | packrat | 99/99 | 204.276 | 8565 | 15.03x |
| tpcds | peglib | tree | packrat | 99/99 | 245.772 | 10305 | 18.09x |
| tpcds | duckdb | tokenize |  | 99/99 | 0.930 | 39 |  |
| tpcds | duckdb | recognize |  | 99/99 | 46.837 | 1964 | 3.45x |
| tpcds | duckdb | tree |  | 99/99 | 13.588 | 570 | 1.00x |
| tpcds | duckdb | ast |  | 99/99 | 17.416 | 730 | 1.00x |
| tpcds | postgres | tree | libpg_query | 99/99 | 1.736 | 73 | 0.13x |
| tpcds | postgres | ast | legacy_parser extension | 99/99 | 3.628 | 152 | 0.21x |
| short | peglib | recognize | no packrat | 6/6 | 0.859 | 9550 | 18.41x |
| short | peglib | recognize | packrat | 6/6 | 0.481 | 5341 | 10.29x |
| short | peglib | tree | packrat | 6/6 | 0.603 | 6703 | 12.92x |
| short | duckdb | tokenize |  | 6/6 | 0.003 | 32 |  |
| short | duckdb | recognize |  | 6/6 | 0.171 | 1898 | 3.66x |
| short | duckdb | tree |  | 6/6 | 0.047 | 519 | 1.00x |
| short | duckdb | ast |  | 6/6 | 0.065 | 719 | 1.00x |
| short | postgres | tree | libpg_query | 6/6 | 0.005 | 61 | 0.12x |
| short | postgres | ast | legacy_parser extension | 6/6 | 0.015 | 168 | 0.23x |
| (grammar) | peglib | construction | text to parser |  | 58.393 |  |  |
| (grammar) | duckdb | construction | CompiledGrammar::Create |  | 1.983 |  |  |

Reading:

- **Against cpp-peglib**, on the same grammar, DuckDB's PEG parser builds its parse tree 13-18x faster and constructs
  the grammar 29x faster (2.0 ms against 58 ms). Packrat memoisation halves cpp-peglib's time and it is still more
  than an order of magnitude behind.
- **Against the PostgreSQL parser**, DuckDB's PEG parser is 4-5x slower to a DuckDB AST and 8-9x slower to a
  parse tree. This is the price of the runtime-extensible design at this commit.
- The ratios hold from short statements to TPC-DS: time per token varies by less than 1.6x within each engine.

## Where the cpp-peglib gap comes from

Measured with cpp-peglib's tracer and a sampling profile on TPC-H (1,986 tokens, packrat on):

- cpp-peglib enters 391k operators (176k of them named rules), 197 per token, and 80% of them fail. At 14.3 ms
  that is about 37 ns per operator, so the individual steps are not slow; there are many of them.
- The profile is flat. The top entries are the packrat lookup, rule entry, semantic-value scopes, reference
  dispatch and case-insensitive literal comparison (`tolower`/`strcmp`, about 13% of samples); nothing exceeds 10%.
- The attempts are alternatives that the next token already rules out. Each of the 35 `Statement` alternatives
  is tried for every query; at every expression operand about 30 type rules, `CASE`, `CAST` and the other special
  forms are tried; each of the 33 operator rules is entered about 600 times; `QuotedIdentifier` is tried 4,169
  times for a few hundred identifiers.

DuckDB's parser avoids this work by design: the tokenizer classifies each token once (38 ns/token), and FIRST sets
over token classes and literal ids let a choice skip alternatives without entering them. An October profile of an
earlier DuckDB commit counted about 5 matcher steps per token; that figure has not been re-measured here.

## Files

- `gram2peglib.py`: grammar translation; `build/duckdb.peg` is the result.
- `bench.cpp`: the harness. The tokenizer/matcher variants use DuckDB-internal headers (`-DDUCKDB_PARSER_PHASES`);
  if those move, `make PHASES=0` keeps the public `Parser` entry point only.
- `report.py`: summary table from a result CSV (`--markdown` for the table above).
- `corpora/short/`: six short statements; TPC-H and TPC-DS come from the `duckdb` submodule.
