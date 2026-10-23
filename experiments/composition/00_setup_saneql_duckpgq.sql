LOAD '${SANEQL_BUILD}/extension/saneql/saneql.duckdb_extension';
LOAD '${DUCKPGQ_BUILD}/extension/duckpgq/duckpgq.duckdb_extension';
CREATE TABLE person(id INT, name VARCHAR, age INT);
INSERT INTO person VALUES (1,'ann',30),(2,'bob',45),(3,'cid',50),(4,'dee',20);
CREATE TABLE knows(src INT, dst INT);
INSERT INTO knows VALUES (1,2),(2,3),(3,4),(1,3);
SELECT dialect_name FROM duckdb_dialects();
