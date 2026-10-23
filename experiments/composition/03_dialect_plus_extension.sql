SET active_grammar_extensions = ['duckpgq'];
CREATE PROPERTY GRAPH g VERTEX TABLES (person) EDGE TABLES (knows SOURCE KEY (src) REFERENCES person (id) DESTINATION KEY (dst) REFERENCES person (id));
SET current_dialect = 'saneql';
-- A: plain SQL still parses under the dialect?
SELECT count(*) FROM person;
-- B: PGQ under dialect + grammar extension
SELECT * FROM GRAPH_TABLE (g MATCH (a:person)-[k:knows]->(b:person) COLUMNS (a.name AS a_name, b.name AS b_name)) ORDER BY 1,2;
-- C: three languages in one statement
SELECT a_name FROM GRAPH_TABLE (g MATCH (a:person)-[k:knows]->(b:person) COLUMNS (a.name AS a_name, b.age AS b_age)) WHERE b_age IN (SELECT age FROM (person.filter(age > 40).project(age))) ORDER BY 1;
