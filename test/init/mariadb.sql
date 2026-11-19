CREATE DATABASE app;
CREATE TABLE app.t (x int);
INSERT INTO app.t VALUES (42);
-- Password: ' p#a\ss"w'd ' (edge spaces, '#', backslash, both quotes);
-- run.sh writes the same value to a secret file.
CREATE USER 'u'@'%' IDENTIFIED BY ' p#a\\ss"w''d ';
GRANT ALL ON app.* TO 'u'@'%';
