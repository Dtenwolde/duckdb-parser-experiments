SET active_grammar_extensions = ['duckpgq', 'pipe_query_syntax'];
CREATE PROPERTY GRAPH g VERTEX TABLES (person) EDGE TABLES (knows SOURCE KEY (src) REFERENCES person (id) DESTINATION KEY (dst) REFERENCES person (id));
-- pipe alone
FROM person |> WHERE age > 25 |> SELECT name |> ORDER BY name;
-- pgq alone
SELECT * FROM GRAPH_TABLE (g MATCH (a:person)-[k:knows]->(b:person) COLUMNS (a.name AS a_name, b.name AS b_name)) ORDER BY 1,2;
-- mixed: pipe over a graph table
FROM GRAPH_TABLE (g MATCH (a:person)-[k:knows]->(b:person) COLUMNS (a.name AS a_name, b.age AS b_age))
  |> WHERE b_age > 40
  |> AGGREGATE count(*) AS n GROUP BY a_name
  |> ORDER BY a_name;
-- mixed: graph table inside a pipe source subquery
FROM (SELECT a_name FROM GRAPH_TABLE (g MATCH (a:person)-[k:knows]->(b:person) COLUMNS (a.name AS a_name))) |> DISTINCT |> ORDER BY a_name;
