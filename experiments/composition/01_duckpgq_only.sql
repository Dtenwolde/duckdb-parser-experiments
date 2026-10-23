SET active_grammar_extensions = ['duckpgq'];
CREATE PROPERTY GRAPH g VERTEX TABLES (person) EDGE TABLES (knows SOURCE KEY (src) REFERENCES person (id) DESTINATION KEY (dst) REFERENCES person (id));
SELECT * FROM GRAPH_TABLE (g MATCH (a:person)-[k:knows]->(b:person) COLUMNS (a.name AS a_name, b.name AS b_name)) ORDER BY 1,2;
