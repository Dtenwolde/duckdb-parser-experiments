#!/usr/bin/env python3
"""Translate DuckDB's PEG grammar into a grammar that cpp-peglib can load.

DuckDB's parser runs its matcher over a token stream; cpp-peglib is scannerless and matches characters.
The rule bodies carry over unchanged. What has to be re-expressed is everything DuckDB does outside the
grammar text:

  * the tokenizer (whitespace, comments, operator maximal munch, compound ':' tokens),
  * keyword literals (case-insensitive, whole-word),
  * the terminal rule overrides (identifier classes with keyword masks, string / number / operator literals),
    which are read from scripts/parser/grammar_types.yml so that the translation follows the checked-out commit.

Usage: gram2peglib.py <duckdb source dir> [--no-dictionary] > duckdb.peg
"""
import argparse
import re
import sys
from pathlib import Path

OP_CHARS = set("+-*/%^<>=~!@&|")
# PostgreSQL rule kept by DuckDB's tokenizer: an operator may only end in '+' or '-' if it contains one of these
OP_SPECIAL = set("~!@%^&|")
# OperatorMatcher::HasSpecialPrecedence
SPECIAL_PRECEDENCE = ["=", "<", ">", "~", "->", "<=", ">=", "!=", "==", "<>", "~~", "~*", "!~",
                      "~~*", "~~~", "!~~", "!~*", "!~~*"]

TOKEN_RE = re.compile(r"""
    (?P<comment>\#[^\n]*)
  | (?P<literal>'(?:\\.|[^'\\])*')
  | (?P<cls>\[(?:\\.|[^\]\\])*\]i?)
  | (?P<arrow><-)
  | (?P<name>%?[A-Za-z_][A-Za-z0-9_]*)
  | (?P<ws>\s+)
  | (?P<punct>.)
""", re.X | re.S)


def tokenize(text):
    """Return (kind, text) pairs. A '(' written directly after a name is a macro call and gets kind 'call'."""
    tokens, previous_end, previous_kind = [], -1, None
    for m in TOKEN_RE.finditer(text):
        kind = m.lastgroup
        if kind in ("comment", "ws"):
            continue
        if m.group() == "(" and previous_kind == "name" and previous_end == m.start():
            kind = "call"
        tokens.append((kind, m.group()))
        previous_end, previous_kind = m.end(), kind
    return tokens


def split_rules(tokens):
    """Yield (name, params, body tokens). A rule starts at `Name <-` or `Name(Params) <-`."""
    starts = []
    for i, (kind, text) in enumerate(tokens):
        if kind != "arrow":
            continue
        j = i - 1
        if tokens[j][1] == ")":
            while tokens[j][1] != "(":
                j -= 1
            j -= 1
        starts.append((j, i))
    rules = []
    for n, (name_idx, arrow_idx) in enumerate(starts):
        end = starts[n + 1][0] if n + 1 < len(starts) else len(tokens)
        params = "".join(t for _, t in tokens[name_idx + 1:arrow_idx])
        rules.append((tokens[name_idx][1], params, tokens[arrow_idx + 1:end]))
    return rules


def read_keywords(path):
    return [line.strip() for line in path.read_text().splitlines() if line.strip() and not line.startswith("#")]


def read_matcher_overrides(path):
    """Minimal reader for the `matcher_rule_overrides:` block (rule -> {matcher, suggestion})."""
    overrides, current, inside = {}, None, False
    for line in path.read_text().splitlines():
        if line.startswith("matcher_rule_overrides:"):
            inside = True
            continue
        if not inside or not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):
            break
        indent = len(line) - len(line.lstrip())
        key, _, value = line.strip().partition(":")
        if indent == 2:
            current = overrides.setdefault(key, {})
        else:
            current[key] = value.strip()
    return overrides


def peg_literal(text):
    return "'" + text.replace("\\", "\\\\").replace("'", "\\'") + "'"


class Translator:
    def __init__(self, duckdb_dir, use_dictionary):
        peg_dir = duckdb_dir / "src/parser/peg/grammar"
        self.use_dictionary = use_dictionary
        self.grammar_text = (duckdb_dir / "src/include/duckdb/parser/peg/inlined_grammar.gram").read_text()
        self.overrides = read_matcher_overrides(duckdb_dir / "scripts/parser/grammar_types.yml")
        kw = {name: read_keywords(peg_dir / "keywords" / f"{name}_keyword.list")
              for name in ("reserved", "unreserved", "column_name", "func_name", "type_name", "bare_label")}
        self.kw = {name: {w.upper() for w in words} for name, words in kw.items()}
        self.all_keywords = set().union(*(self.kw[c] for c in ("reserved", "unreserved", "column_name",
                                                               "func_name", "type_name")))
        self.op_rules = {}
        self.helper_rules = []
        self.notes = []

    # --- literals -------------------------------------------------------------------------------------------
    def op_rule(self, op):
        """A rule matching exactly the operator token `op`, emulating the tokenizer's maximal munch."""
        if op not in self.op_rules:
            name = "OP_" + "_".join(f"{ord(c):02X}" for c in op)
            if set(op) & OP_SPECIAL:
                tail = "!OpChar"
            else:
                # the rest of the run may only be '+'/'-' characters, which the tokenizer splits off
                tail = "&([-+]* !OpChar)"
            self.op_rules[op] = (name, f"{name} <- < {peg_literal(op)} {tail} >")
        return self.op_rules[op][0]

    def translate_literal(self, token):
        text = re.sub(r"\\(.)", r"\1", token[1:-1])
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", text):
            return peg_literal(text) + "i"
        if set(text) <= OP_CHARS:
            return self.op_rule(text)
        if text == ":":
            return "COLON"
        return peg_literal(text)

    @staticmethod
    def is_keyword_set(body):
        """True for `'A' / 'B' / ...` with at least two alternatives that are all word literals."""
        if len(body) < 3 or len(body) % 2 == 0:
            return False
        for i, (kind, text) in enumerate(body):
            if i % 2 == 0:
                if kind != "literal" or not re.fullmatch(r"'[A-Za-z_][A-Za-z0-9_]*'", text):
                    return False
            elif text != "/":
                return False
        return True

    # --- terminals ------------------------------------------------------------------------------------------
    def keyword_set_rule(self, name, words):
        words = sorted(words)
        if not words:
            return f"{name} <- !."
        sep = " | " if self.use_dictionary else " / "
        if not self.use_dictionary:
            # ordered choice: longer words first so that a prefix never shadows a longer keyword
            words.sort(key=lambda w: (-len(w), w))
        return f"{name} <- " + sep.join(peg_literal(w) + "i" for w in words)

    def identifier_rule(self, rule, config):
        matcher, suggestion = config["matcher"], config.get("suggestion", "SUGGEST_VARIABLE")
        # IdentifierMatcher::SupportsStringLiteral
        path_literal = "SingleQuotedString / " if suggestion in ("SUGGEST_TABLE_NAME", "SUGGEST_FILE_NAME") else ""
        if matcher in ("reserved_identifier", "identifier_string"):
            return f"{rule} <- QuotedIdentifier / {path_literal}AnyWord"
        # DefaultKeywordMaps::GetIdentifierMask
        if suggestion == "SUGGEST_BARE_LABEL":
            allowed, mask = self.kw["bare_label"], "BareLabel"
        elif suggestion == "SUGGEST_TYPE_NAME":
            allowed, mask = self.kw["unreserved"] | self.kw["type_name"], "TypeName"
        elif suggestion in ("SUGGEST_SCALAR_FUNCTION_NAME", "SUGGEST_TABLE_FUNCTION_NAME"):
            allowed, mask = self.kw["unreserved"] | self.kw["func_name"], "FuncName"
        else:
            allowed, mask = self.kw["unreserved"] | self.kw["column_name"], "ColName"
        excluded = f"KeywordsExcludedFrom{mask}"
        word = f"WordFor{mask}"
        if not any(r.startswith(excluded + " ") for r in self.helper_rules):
            self.helper_rules.append(self.keyword_set_rule(excluded, self.all_keywords - allowed))
            self.helper_rules.append(f"{word} <- < !{excluded} WordBody >")
        return f"{rule} <- QuotedIdentifier / {path_literal}{word}"

    def terminal_rule(self, rule, config):
        matcher = config["matcher"]
        if matcher in ("identifier", "reserved_identifier", "identifier_string"):
            return self.identifier_rule(rule, config)
        if matcher == "number_literal":
            return f"{rule} <- NumberToken"
        if matcher == "string_literal":
            return f"{rule} <- StringToken"
        if matcher == "operator":
            return f"{rule} <- < !(SpecialPrecedenceOp OpEnd) OpToken >"
        if matcher == "all_operators":
            return f"{rule} <- < OpToken >"
        raise SystemExit(f"unknown matcher kind '{matcher}' for rule {rule}: extend gram2peglib.py")

    # --- output ---------------------------------------------------------------------------------------------
    def translate(self):
        rules = split_rules(tokenize(self.grammar_text))
        # rules DuckDB defines in the grammar text but implements outside it
        dropped = set(self.overrides) | {"Program", "TopLevelStatement", "PlainIdentifier", "QuotedIdentifier",
                                         "%whitespace", "EndOfInput"}
        out = ["# Generated by gram2peglib.py from DuckDB's inlined_grammar.gram. Do not edit.",
               "Program <- (Statement? ';'+)* Statement? EndOfInput", ""]
        seen = set()
        for name, params, body in rules:
            if name in dropped:
                continue
            if name in seen:
                self.notes.append(f"duplicate rule {name}: kept the first definition")
                continue
            seen.add(name)
            if self.use_dictionary and self.is_keyword_set(body):
                # a choice between whole-word keywords is order-independent, so cpp-peglib can use a trie for it
                out.append(f"{name}{params} <- " + " | ".join(self.translate_literal(t) for k, t in body
                                                              if k == "literal"))
                continue
            parts = []
            for kind, text in body:
                if kind == "literal":
                    parts.append(self.translate_literal(text))
                elif kind == "cls" or (kind == "punct" and text in "<>"):
                    raise SystemExit(f"rule {name} uses a character class or token boundary: extend gram2peglib.py")
                elif kind == "call":
                    # cpp-peglib only reads `Name(` as a macro call when the two are adjacent
                    parts[-1] += text
                else:
                    parts.append(text)
            out.append(f"{name}{params} <- " + " ".join(parts))

        out += ["", "# --- terminal rule overrides (scripts/parser/grammar_types.yml: matcher_rule_overrides) ---"]
        for rule, config in self.overrides.items():
            out.append(self.terminal_rule(rule, config))
        out += self.helper_rules

        special = sorted(SPECIAL_PRECEDENCE, key=lambda op: (-len(op), op))
        out += ["", "# --- tokenizer ---",
                "EndOfInput <- !.",
                "COLON <- < ':' ![:=] >",
                *[definition for _, definition in self.op_rules.values()],
                "OpChar <- [-+*/%^<>=~!@&|]",
                "OpEnd <- &([-+]* !OpChar) / !OpChar",
                # an operator run; without a 'special' character trailing '+'/'-' are split off as separate tokens
                "OpToken <- &([-+*/<>=]* [~!@%^&|]) OpChar+ / ([-+]* [*/<>=])+ &([-+]* !OpChar) / [-+]",
                "SpecialPrecedenceOp <- " + " / ".join(peg_literal(op) for op in special),
                # Tokenizer::CharacterIsKeyword: anything that is not an operator, space, quote, '.', ';' or bracket
                "WordChar <- [^- \\t\\n\\r\\x0b\\x0c'\";.(){}\\[\\],:?$#`+*/%^<>=~!@&|]",
                "WordBody <- ![0-9] !([eExXbBnN] ['] ) WordChar+",
                "AnyWord <- < WordBody >",
                "QuotedIdentifier <- < '\"' ('\"\"' / [^\"])+ '\"' / '`' ('``' / [^`])+ '`' >",
                "NumberToken <- < ([0-9] [0-9_]* ('.' [0-9_]*)? / '.' [0-9] [0-9_]*) ([eE] [-+]? [0-9]+)? >",
                "SingleQuotedString <- < [eExXbBnN]? ['] (\"''\" / [^'])* ['] >",
                # adjacent single-quoted strings separated by a newline are one literal
                "StringToken <- < [eExXbBnN]? ['] (\"''\" / [^'])* ['] "
                "([ \\t\\r]* '\\n' [ \\t\\r\\n]* ['] (\"''\" / [^'])* ['])* > / DollarQuotedString",
                "DollarQuotedString <- < '$' $tag< [A-Za-z_]* > '$' (!('$' $tag '$') .)* '$' $tag '$' >",
                "%whitespace <- ([ \\t\\n\\r\\x0b\\x0c] / '--' [^\\n]* / '/*' (!'*/' .)* '*/')*",
                "%word <- WordChar+",
                ""]
        return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("duckdb_dir", type=Path)
    parser.add_argument("--no-dictionary", action="store_true",
                        help="emit keyword sets as ordered choices instead of cpp-peglib trie dictionaries")
    args = parser.parse_args()
    translator = Translator(args.duckdb_dir, not args.no_dictionary)
    sys.stdout.write(translator.translate())
    for note in translator.notes:
        print("note:", note, file=sys.stderr)


if __name__ == "__main__":
    main()
