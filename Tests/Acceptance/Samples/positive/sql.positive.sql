SELECT id, name, email
FROM users
WHERE active = TRUE
  AND created_at >= '2026-01-01'
ORDER BY name ASC
LIMIT 100;
