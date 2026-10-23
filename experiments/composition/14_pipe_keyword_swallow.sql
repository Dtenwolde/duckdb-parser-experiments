SET active_grammar_extensions = ['pipe_query_syntax'];
-- 1 exact demo form (uppercase) after WHERE
FROM person |> WHERE age > 25 |> AGGREGATE COUNT(*) AS n GROUP BY name;
-- 2 parenthesised WHERE expression
FROM person |> WHERE (age > 25) |> AGGREGATE count(*) AS n GROUP BY name;
-- 3 unreserved-word operator after WHERE: EXTEND
FROM person |> WHERE age > 25 |> EXTEND age * 2 AS d |> SELECT name, d;
-- 4 reserved-word operator after WHERE: DISTINCT, LIMIT
FROM person |> WHERE age > 25 |> DISTINCT |> LIMIT 2;
-- 5 is '|>' a binary operator in plain SQL expressions?
SELECT 1 |> 2;
-- 6 WHERE ending in an identifier instead of a literal
FROM person |> WHERE age > id |> AGGREGATE count(*) AS n;
