-- Library schema. Source: data-mapping.md (Library schema section).

-- Durable identity + matching. Never deleted by imports.
CREATE TABLE films (
  letterboxd_uri  TEXT PRIMARY KEY,          -- film URI only; opaque
  name            TEXT NOT NULL,             -- as exported
  year            INTEGER NOT NULL,
  tmdb_id         INTEGER,                   -- NULL until matched
  match_status    TEXT NOT NULL DEFAULT 'pending'
                  CHECK (match_status IN ('pending','matched','ambiguous','unmatched')),
  is_horror       INTEGER,                   -- 1/0 from TMDB genres (27); NULL until matched
  genre_override  TEXT CHECK (genre_override IN ('include','exclude')),
  tmdb_json       TEXT,                      -- title, poster_path, runtime, genres, overview
  matched_at      TEXT,                      -- ISO 8601
  created_at      TEXT NOT NULL              -- first seen in an import
);

CREATE INDEX idx_films_tmdb_id ON films(tmdb_id);
CREATE INDEX idx_films_match_status ON films(match_status);

-- Snapshot tables. Fully replaced each import.
CREATE TABLE ratings (
  letterboxd_uri  TEXT PRIMARY KEY REFERENCES films(letterboxd_uri),
  half_stars      INTEGER NOT NULL CHECK (half_stars BETWEEN 1 AND 10),
  rated_on        TEXT                       -- export Date; informational only
);

CREATE TABLE watched (
  letterboxd_uri  TEXT PRIMARY KEY REFERENCES films(letterboxd_uri),
  logged_on       TEXT                       -- export Date; informational only
);

CREATE TABLE watchlist (
  letterboxd_uri  TEXT PRIMARY KEY REFERENCES films(letterboxd_uri),
  added_on        TEXT                       -- export Date
);

CREATE TABLE likes (                         -- optional signal
  letterboxd_uri  TEXT PRIMARY KEY REFERENCES films(letterboxd_uri)
);

-- Import history; drives the "last import: N days ago" nudge.
CREATE TABLE imports (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  imported_at      TEXT NOT NULL,
  source_filename  TEXT NOT NULL,
  ratings_count    INTEGER NOT NULL,
  watched_count    INTEGER NOT NULL,
  watchlist_count  INTEGER NOT NULL,
  likes_count      INTEGER NOT NULL,
  new_films_count  INTEGER NOT NULL
);

-- Effective horror classification.
-- Override wins; otherwise TMDB genre; unmatched films are never treated as horror.
CREATE VIEW horror_films AS
SELECT *
FROM films
WHERE CASE
        WHEN genre_override = 'include' THEN 1
        WHEN genre_override = 'exclude' THEN 0
        ELSE COALESCE(is_horror, 0)
      END = 1;
