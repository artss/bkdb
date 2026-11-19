CREATE ROLE approle LOGIN PASSWORD 'approle';
CREATE DATABASE app OWNER approle;
\connect app
CREATE TABLE t (x int);
INSERT INTO t VALUES (42);
