# Parser-vs-parser benchmark: cpp-peglib, DuckDB PEG, PostgreSQL parser

Question: on the same grammar and the same queries, how does DuckDB's PEG parser compare with a general-purpose
PEG library (cpp-peglib, the engine of the CIDR 2025 prototype) and with the PostgreSQL-derived parser it replaced?

Run with `./run.sh`. Everything is generated from the DuckDB source trees it is pointed at, so the benchmark follows
a moving DuckDB commit; results are written to `results/<date>.csv`.

Several DuckDB builds can be compared in one run: the `duckdb` submodule (`main`) and every worktree under
`builds/duckdb-<label>` that has a release build, or the list in `DUCKDB_VARIANTS`. The header of `run.sh` shows how
to add a branch as a worktree. Each build gets its own bench binary, because two libduckdb cannot share a process;
the binaries run in alternating passes, and cpp-peglib and the PostgreSQL parser, which are measured in every
binary, show how comparable the passes were.

## What is compared

| Engine | What runs | Grammar |
|---|---|---|
| `peglib` | cpp-peglib (pinned submodule `third_party/cpp-peglib`), scannerless | DuckDB's `.gram` rules, translated by `gram2peglib.py` |
| `duckdb` | DuckDB's tokenizer, matcher and transformer, from `<source tree>/build/release/src/libduckdb.dylib` | `inlined_grammar.gram` as shipped |
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
- **Interleaved rounds and passes, medians.** Every input and variant is warmed up and checked for acceptance, then measured in
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

Apple M5 Pro, macOS 26.7, 2026-11-12, cpp-peglib v1.9.1, legacy_parser as pinned by each DuckDB commit. Totals over
all inputs of a corpus; per input the median of 3 alternating passes of 7 rounds each. These are provisional: the
evaluation commit is not pinned yet. Raw data: `results/2026-11-12.csv`.

Three DuckDB builds:

- `main`: the `duckdb` submodule, upstream main of 2026-10-23 (`d71c926`).
- `upstream-main`: upstream main of 2026-11-12 (`b4ce456`).
- `parser-performance`: branch `parser-performance` of Dtenwolde/duckdb (`977e23c`, 65 commits on upstream main of
  2026-10-22), plus `patches/parser-performance-977e23c-macos-build.patch`, without which it does not compile on
  macOS.

DuckDB builds: main = d71c926f43, upstream-main = b4ce456542, parser-performance = 977e23c3fc+local

| corpus | engine | build | output | config | accepted | total ms | ns/token | vs DuckDB PEG (main) |
|---|---|---|---|---|---|---|---|---|
| (grammar) | peglib | all | construction | text to parser |  | 62.333 |  |  |
| (grammar) | duckdb | main | construction | CompiledGrammar::Create |  | 2.194 |  |  |
| (grammar) | duckdb | upstream-main | construction | CompiledGrammar::Create |  | 2.286 |  |  |
| (grammar) | duckdb | parser-performance | construction | CompiledGrammar::Create |  | 4.401 |  |  |
| tpch | peglib | all | recognize | no packrat | 22/22 | 33.886 | 17062 | 27.38x |
| tpch | peglib | all | recognize | packrat | 22/22 | 14.978 | 7542 | 12.10x |
| tpch | peglib | all | tree | packrat | 22/22 | 18.640 | 9386 | 15.06x |
| tpch | duckdb | main | tokenize |  | 22/22 | 0.079 | 40 |  |
| tpch | duckdb | upstream-main | tokenize |  | 22/22 | 0.078 | 39 |  |
| tpch | duckdb | parser-performance | tokenize |  | 22/22 | 0.047 | 24 |  |
| tpch | duckdb | main | recognize |  | 22/22 | 4.265 | 2147 | 3.45x |
| tpch | duckdb | upstream-main | recognize |  | 22/22 | 5.336 | 2687 | 4.31x |
| tpch | duckdb | parser-performance | recognize |  | 22/22 | 4.496 | 2264 | 3.63x |
| tpch | duckdb | main | tree |  | 22/22 | 1.238 | 623 | 1.00x |
| tpch | duckdb | upstream-main | tree |  | 22/22 | 0.990 | 498 | 0.80x |
| tpch | duckdb | parser-performance | tree |  | 22/22 | 0.338 | 170 | 0.27x |
| tpch | duckdb | main | ast |  | 22/22 | 1.616 | 814 | 1.00x |
| tpch | duckdb | upstream-main | ast |  | 22/22 | 1.362 | 686 | 0.84x |
| tpch | duckdb | parser-performance | ast |  | 22/22 | 0.509 | 256 | 0.31x |
| tpch | postgres | all | tree | libpg_query | 22/22 | 0.148 | 75 | 0.12x |
| tpch | postgres | all | ast | legacy_parser extension | 22/22 | 0.309 | 155 | 0.19x |
| tpcds | peglib | all | recognize | no packrat | 99/99 | 588.051 | 24657 | 42.66x |
| tpcds | peglib | all | recognize | packrat | 99/99 | 211.728 | 8878 | 15.36x |
| tpcds | peglib | all | tree | packrat | 99/99 | 253.458 | 10628 | 18.39x |
| tpcds | duckdb | main | tokenize |  | 99/99 | 0.966 | 41 |  |
| tpcds | duckdb | upstream-main | tokenize |  | 99/99 | 0.954 | 40 |  |
| tpcds | duckdb | parser-performance | tokenize |  | 99/99 | 0.566 | 24 |  |
| tpcds | duckdb | main | recognize |  | 99/99 | 48.215 | 2022 | 3.50x |
| tpcds | duckdb | upstream-main | recognize |  | 99/99 | 59.538 | 2496 | 4.32x |
| tpcds | duckdb | parser-performance | recognize |  | 99/99 | 50.298 | 2109 | 3.65x |
| tpcds | duckdb | main | tree |  | 99/99 | 13.786 | 578 | 1.00x |
| tpcds | duckdb | upstream-main | tree |  | 99/99 | 11.017 | 462 | 0.80x |
| tpcds | duckdb | parser-performance | tree |  | 99/99 | 3.809 | 160 | 0.28x |
| tpcds | duckdb | main | ast |  | 99/99 | 17.789 | 746 | 1.00x |
| tpcds | duckdb | upstream-main | ast |  | 99/99 | 14.917 | 625 | 0.84x |
| tpcds | duckdb | parser-performance | ast |  | 99/99 | 5.550 | 233 | 0.31x |
| tpcds | postgres | all | tree | libpg_query | 99/99 | 1.853 | 78 | 0.13x |
| tpcds | postgres | all | ast | legacy_parser extension | 99/99 | 3.759 | 158 | 0.21x |
| short | peglib | all | recognize | no packrat | 6/6 | 0.898 | 9975 | 18.73x |
| short | peglib | all | recognize | packrat | 6/6 | 0.505 | 5615 | 10.54x |
| short | peglib | all | tree | packrat | 6/6 | 0.626 | 6961 | 13.07x |
| short | duckdb | main | tokenize |  | 6/6 | 0.003 | 34 |  |
| short | duckdb | upstream-main | tokenize |  | 6/6 | 0.003 | 35 |  |
| short | duckdb | parser-performance | tokenize |  | 6/6 | 0.002 | 23 |  |
| short | duckdb | main | recognize |  | 6/6 | 0.175 | 1945 | 3.65x |
| short | duckdb | upstream-main | recognize |  | 6/6 | 0.218 | 2425 | 4.55x |
| short | duckdb | parser-performance | recognize |  | 6/6 | 0.181 | 2013 | 3.78x |
| short | duckdb | main | tree |  | 6/6 | 0.048 | 533 | 1.00x |
| short | duckdb | upstream-main | tree |  | 6/6 | 0.037 | 406 | 0.76x |
| short | duckdb | parser-performance | tree |  | 6/6 | 0.015 | 170 | 0.32x |
| short | duckdb | main | ast |  | 6/6 | 0.066 | 739 | 1.00x |
| short | duckdb | upstream-main | ast |  | 6/6 | 0.055 | 609 | 0.82x |
| short | duckdb | parser-performance | ast |  | 6/6 | 0.024 | 265 | 0.36x |
| short | postgres | all | tree | libpg_query | 6/6 | 0.006 | 65 | 0.12x |
| short | postgres | all | ast | legacy_parser extension | 6/6 | 0.015 | 170 | 0.23x |

Anchor check: cpp-peglib and PostgreSQL totals differ by at most 7.6% between the bench binaries (tpch postgres ast legacy_parser extension).

Reading:

- **parser-performance** produces a DuckDB AST 3.2x faster than the pinned main commit and 2.7x faster than current
  upstream main on TPC-H and TPC-DS (2.8x and 2.3x on the short statements); the parse tree alone is 3.6x faster. Its tokenizer is 1.7x faster. Grammar construction doubles
  (4.4 ms against 2.2 ms), and the `recognize` mode does not benefit.
- **Against the PostgreSQL parser**, the branch is 1.5-1.7x slower to a DuckDB AST (main: 4.4-5.2x) and 2.1-2.5x
  slower to a parse tree (main: 7.4-8.4x).
- **Against cpp-peglib** on the same grammar, DuckDB's parse tree is 13-18x faster on main and 42-67x faster on the
  branch; grammar construction is 14-28x faster.
- Upstream main has become 16-18% faster to an AST since the pinned commit, independently of the branch.
- cpp-peglib and the PostgreSQL parser are measured in all three bench binaries; their totals differ by at most
  7.6% between binaries, so differences between DuckDB builds below that are not meaningful.

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
- `bench.cpp`: the harness. The tokenizer/matcher variants use DuckDB-internal headers (`-DDUCKDB_PARSER_PHASES`).
  Three shapes of that internal API are supported so far and the Makefile picks one by looking at the headers; if
  they move again, `make PHASES=0` keeps the public `Parser` entry point only.
- `patches/`: local changes a build needed, applied in its worktree and never committed to the branch.
- `report.py`: summary table from a result CSV (`--markdown` for the table above).
- `corpora/short/`: six short statements; TPC-H and TPC-DS come from the `duckdb` submodule.
