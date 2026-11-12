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
  (`'A'i | 'B'i`), which is the tuned form of the same language: 24.5 ms to 17.5 ms on TPC-H. `--no-dictionary`
  emits plain ordered choices.

Approximations: string continuation across newlines is accepted but dollar-quote tags are limited to ASCII;
numbers do not cover every tokenizer corner (`1.` followed by an identifier); `--` or `/*` directly after an
operator character. None of these occur in the corpora, and all engines agree on accept/reject for every input.

## Results

Apple M5 Pro, macOS 26.7, 2026-11-12, DuckDB `d71c926f43` (moving; performance work is ongoing), cpp-peglib v1.9.1,
legacy_parser `bcdf276`. Totals over all inputs of a corpus, median of 7 rounds.

| corpus | engine | output | config | accepted | total ms | ns/token | vs DuckDB PEG |
|---|---|---|---|---|---|---|---|
| tpch | peglib | recognize | no packrat | 22/22 | 36.536 | 18397 | 30.66x |
| tpch | peglib | recognize | packrat | 22/22 | 17.530 | 8827 | 14.71x |
| tpch | peglib | tree | packrat | 22/22 | 20.992 | 10570 | 17.61x |
| tpch | duckdb | tokenize |  | 22/22 | 0.075 | 38 |  |
| tpch | duckdb | recognize |  | 22/22 | 4.048 | 2038 | 3.40x |
| tpch | duckdb | tree |  | 22/22 | 1.192 | 600 | 1.00x |
| tpch | duckdb | ast |  | 22/22 | 1.560 | 785 | 1.00x |
| tpch | postgres | tree | libpg_query | 22/22 | 0.137 | 69 | 0.12x |
| tpch | postgres | ast | legacy_parser extension | 22/22 | 0.296 | 149 | 0.19x |
| tpcds | peglib | recognize | no packrat | 99/99 | 632.827 | 26535 | 47.72x |
| tpcds | peglib | recognize | packrat | 99/99 | 244.623 | 10257 | 18.45x |
| tpcds | peglib | tree | packrat | 99/99 | 283.545 | 11889 | 21.38x |
| tpcds | duckdb | tokenize |  | 99/99 | 0.924 | 39 |  |
| tpcds | duckdb | recognize |  | 99/99 | 45.697 | 1916 | 3.45x |
| tpcds | duckdb | tree |  | 99/99 | 13.260 | 556 | 1.00x |
| tpcds | duckdb | ast |  | 99/99 | 17.065 | 716 | 1.00x |
| tpcds | postgres | tree | libpg_query | 99/99 | 1.723 | 72 | 0.13x |
| tpcds | postgres | ast | legacy_parser extension | 99/99 | 3.606 | 151 | 0.21x |
| short | peglib | recognize | no packrat | 6/6 | 0.969 | 10763 | 21.17x |
| short | peglib | recognize | packrat | 6/6 | 0.566 | 6286 | 12.37x |
| short | peglib | tree | packrat | 6/6 | 0.682 | 7583 | 14.92x |
| short | duckdb | tokenize |  | 6/6 | 0.003 | 33 |  |
| short | duckdb | recognize |  | 6/6 | 0.167 | 1854 | 3.65x |
| short | duckdb | tree |  | 6/6 | 0.046 | 508 | 1.00x |
| short | duckdb | ast |  | 6/6 | 0.064 | 710 | 1.00x |
| short | postgres | tree | libpg_query | 6/6 | 0.005 | 60 | 0.12x |
| short | postgres | ast | legacy_parser extension | 6/6 | 0.015 | 167 | 0.24x |
| (grammar) | peglib | construction | text to parser |  | 59.355 |  |  |
| (grammar) | duckdb | construction | CompiledGrammar::Create |  | 2.102 |  |  |

Reading:

- **Against cpp-peglib**, on the same grammar, DuckDB's PEG parser builds its parse tree 15-21x faster and constructs
  the grammar 28x faster (2.1 ms against 59 ms). Packrat memoisation halves cpp-peglib's time and it is still more
  than an order of magnitude behind.
- **Against the PostgreSQL parser**, DuckDB's PEG parser is 4-5x slower to a DuckDB AST and 8-9x slower to a
  parse tree. This is the price of the runtime-extensible design at this commit.
- The ratios hold from short statements to TPC-DS: time per token varies by less than 1.6x within each engine.

## Files

- `gram2peglib.py`: grammar translation; `build/duckdb.peg` is the result.
- `bench.cpp`: the harness. The tokenizer/matcher variants use DuckDB-internal headers (`-DDUCKDB_PARSER_PHASES`);
  if those move, `make PHASES=0` keeps the public `Parser` entry point only.
- `report.py`: summary table from a result CSV (`--markdown` for the table above).
- `corpora/short/`: six short statements; TPC-H and TPC-DS come from the `duckdb` submodule.
