SELECT "weird column", 'it''s ok', `backtick`
FROM users
WHERE name -- comment
  AND 'not -- comment' = 'x'
LIMIT 10;
/* block
   comment */
INSERT INTO t (a) VALUES ('a;b');
