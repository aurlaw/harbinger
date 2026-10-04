-- Pick log (W9). Source: phase-w9-pick-outcomes.md.
-- The first recommendation of each film. Like decisions, it survives
-- conversation deletion; it holds no conversation content.
CREATE TABLE pick_log (
  tmdb_id               INTEGER PRIMARY KEY,   -- first recommendation of each film only
  title                 TEXT NOT NULL,
  year                  INTEGER,
  model                 TEXT NOT NULL,         -- model of the conversation that first recommended it
  conversation_id       TEXT NOT NULL,         -- informational; no foreign key
  first_recommended_at  TEXT NOT NULL
);

-- Backfill from live conversations (deleted ones have no recommendations left):
-- each film's earliest recommendation, ties broken by id.
INSERT INTO pick_log (tmdb_id, title, year, model, conversation_id, first_recommended_at)
SELECT tmdb_id, title, year, model, conversation_id, created_at
FROM (
  SELECT r.tmdb_id, r.title, r.year, c.model, r.conversation_id, r.created_at,
         ROW_NUMBER() OVER (PARTITION BY r.tmdb_id ORDER BY r.created_at, r.id) AS n
  FROM recommendations r
  JOIN conversations c ON c.id = r.conversation_id
  WHERE c.deleted_at IS NULL
)
WHERE n = 1;
