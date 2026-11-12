# Builds the in-process parser benchmark against the DuckDB submodule's release build.
#   make                 build bench and generate duckdb.peg
#   make PHASES=0        only use DuckDB's public Parser entry point (if internal parser headers moved)
#   make LEGACY=0        build without the libpg_query parse-tree variant
ROOT := $(abspath ../..)
DUCKDB := $(ROOT)/duckdb
DUCKDB_BUILD ?= $(DUCKDB)/build/release
PEGLIB := $(ROOT)/third_party/cpp-peglib
LEGACY_SRC := $(DUCKDB)/extension/external/legacy_parser
LEGACY_LIB := $(DUCKDB_BUILD)/extension/legacy_parser/third_party/libpg_query/libduckdb_pg_query.a
BUILD := build

PHASES ?= 1
LEGACY ?= $(if $(wildcard $(LEGACY_LIB)),1,0)

CXX ?= c++
# same optimisation level as DuckDB's release build
CXXFLAGS := -std=c++17 -O3 -DNDEBUG -I$(PEGLIB) -I$(DUCKDB)/src/include -I$(DUCKDB)/third_party/utf8proc/include
LDFLAGS := -L$(DUCKDB_BUILD)/src -lduckdb -Wl,-rpath,$(DUCKDB_BUILD)/src

ifeq ($(PHASES),1)
CXXFLAGS += -DDUCKDB_PARSER_PHASES
endif
ifeq ($(LEGACY),1)
CXXFLAGS += -DLEGACY_PG_QUERY -I$(LEGACY_SRC)/third_party/libpg_query/include
LDFLAGS += $(LEGACY_LIB)
endif

all: $(BUILD)/bench $(BUILD)/duckdb.peg

$(BUILD)/bench: bench.cpp $(PEGLIB)/peglib.h $(DUCKDB_BUILD)/src/libduckdb.dylib | $(BUILD)
	$(CXX) $(CXXFLAGS) bench.cpp -o $@ $(LDFLAGS)

# regenerated whenever the grammar inputs of the checked-out DuckDB commit change
$(BUILD)/duckdb.peg: gram2peglib.py $(DUCKDB)/src/include/duckdb/parser/peg/inlined_grammar.gram \
		$(DUCKDB)/scripts/parser/grammar_types.yml $(wildcard $(DUCKDB)/src/parser/peg/grammar/keywords/*.list) | $(BUILD)
	python3 gram2peglib.py $(DUCKDB) > $@

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)

.PHONY: all clean
