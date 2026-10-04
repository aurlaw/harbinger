-- Recent releases (W8). Source: phase-w8-recent-releases.md.
-- recent_releases is replaced wholesale by each successful weekly refresh.
CREATE TABLE recent_releases (
  tmdb_id       INTEGER PRIMARY KEY,
  title         TEXT NOT NULL,
  release_date  TEXT,             -- YYYY-MM-DD
  year          INTEGER,
  overview      TEXT NOT NULL,
  genre_ids     TEXT NOT NULL,    -- JSON array, e.g. [27, 53]
  popularity    REAL NOT NULL,
  rank          INTEGER NOT NULL  -- 1..n in TMDB popularity order
);

-- Generic on purpose: one row per scheduled job (W10 reuses it).
CREATE TABLE job_state (
  name             TEXT PRIMARY KEY,   -- e.g. 'recent_releases'
  last_success_at  TEXT,
  last_error       TEXT,
  updated_at       TEXT NOT NULL
);
