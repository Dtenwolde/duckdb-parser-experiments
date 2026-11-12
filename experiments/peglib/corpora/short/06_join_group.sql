SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.id GROUP BY t1.k ORDER BY 1 DESC;
