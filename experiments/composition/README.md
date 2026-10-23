# Grammar composition experiments

Question: can more than one syntax extension be active in a single connection,
and do statements that mix them parse and execute? Run with `./run.sh` (see
header for build requirements). Results below were obtained 2026-10-23 with
both extensions built against DuckDB `d54cbbe3df` (v2.0-cyanoptera head);
the relevant parser code is unchanged on upstream main `d71c926`.

## Findings

| # | Setup | Result |
|---|---|---|
| 01 | DuckPGQ alone (`active_grammar_extensions`) | works |
| 02 | SaneQL alone (`current_dialect`), incl. SaneQL inside a SQL subquery | works |
| 03 | SaneQL dialect **and** DuckPGQ extension | plain SQL parses; `GRAPH_TABLE` fails at `MATCH` |
| 11 | DuckPGQ + pipe syntax, activated in that order | works, incl. `FROM GRAPH_TABLE(...) \|> WHERE ...` and a graph query as pipe source |
| 12 | same, reverse activation order | identical results: order-independent for these two |
| 13 | pipe `AGGREGATE` forms, pipe alone | `... \|> WHERE expr \|> AGGREGATE` fails; `AGGREGATE` directly after `FROM` works |
| 14 | cause of 13 | `\|>` is a legal infix operator in host expressions (`SELECT 1 \|> 2` reaches the binder); `AGGREGATE` is unreserved, so `expr \|> AGGREGATE` parses as an expression. The demo reserves `EXTEND` for exactly this reason but not `AGGREGATE`. |

Interpretation for the paper:

- **Grammar extensions compose** (11/12): two independently written extensions,
  loaded as separate shared libraries, combine in one grammar and in one
  statement with a shared binder. No ordering effects observed for this pair.
- **Dialects do not compose with grammar extensions** (03), by design:
  `CompiledGrammar::Get` returns the dialect grammar and ignores
  `active_grammar_extensions`; `DialectExtension::GetCompiledGrammar` applies only
  the dialect's own changes. Also, the dialect path skips `ComputeFirstSets` and
  grammar validation that the extension path runs.
- **Extension keywords vs the host expression grammar** (13/14): an extension that
  introduces a separator token must also reserve the keywords that follow it, or the
  host's generic operator rule swallows them. One-line fix in the demo
  (`AddChoice("ReservedKeyword", "'AGGREGATE'")`), but a general lesson about
  composing with an open operator grammar.
