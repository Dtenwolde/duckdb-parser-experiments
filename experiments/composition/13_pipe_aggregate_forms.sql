SET active_grammar_extensions = ['pipe_query_syntax'];
FROM person |> AGGREGATE count(*) AS n GROUP BY age > 40;
FROM person |> AGGREGATE count(*) AS n;
FROM person |> AGGREGATE COUNT(*) AS n, SUM(age) AS s GROUP BY age > 40 AS old;
FROM person |> WHERE age > 25 |> AGGREGATE count(*) AS n GROUP BY name;
FROM person |> AGGREGATE count(*) AS n GROUP BY name |> ORDER BY name;
