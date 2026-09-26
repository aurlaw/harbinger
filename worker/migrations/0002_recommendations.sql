-- Recommendation schema. Source: data-mapping.md (Recommendation schema section).
-- Recommended films are generally not in films, so everything here is keyed by TMDB ID.

-- One chat thread. Model is fixed for the life of the conversation.
CREATE TABLE conversations (
  id               TEXT PRIMARY KEY,          -- UUID
  model            TEXT NOT NULL,             -- from allowlist, set at creation
  title            TEXT,                      -- short label for the conversation list
  question_rounds  INTEGER NOT NULL DEFAULT 0 CHECK (question_rounds BETWEEN 0 AND 2),
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL
);

-- Ordered turns. Assistant turns are always structured.
CREATE TABLE messages (
  id               TEXT PRIMARY KEY,          -- UUID
  conversation_id  TEXT NOT NULL REFERENCES conversations(id),
  seq              INTEGER NOT NULL,          -- 1-based order within conversation
  role             TEXT NOT NULL CHECK (role IN ('user','assistant')),
  kind             TEXT NOT NULL CHECK (kind IN ('text','question','recommendations')),
  content_json     TEXT NOT NULL,             -- user text, or question + chips, or pick references
  created_at       TEXT NOT NULL,
  UNIQUE (conversation_id, seq)
);

-- Every pick shown. Drives cards, detail views, and "already shown" exclusion.
CREATE TABLE recommendations (
  id               TEXT PRIMARY KEY,          -- UUID
  conversation_id  TEXT NOT NULL REFERENCES conversations(id),
  message_id       TEXT NOT NULL REFERENCES messages(id),
  position         INTEGER NOT NULL CHECK (position BETWEEN 1 AND 5),
  tmdb_id          INTEGER NOT NULL,
  title            TEXT NOT NULL,
  year             INTEGER,
  why_short        TEXT NOT NULL,             -- card
  why_full         TEXT NOT NULL,             -- detail view
  tmdb_json        TEXT NOT NULL,             -- snapshot at recommend time: poster, runtime, director, overview, providers, trailer key
  created_at       TEXT NOT NULL,
  UNIQUE (message_id, position)
);

CREATE INDEX idx_recommendations_conversation ON recommendations(conversation_id);
CREATE INDEX idx_recommendations_tmdb_id ON recommendations(tmdb_id);

-- Current decision per film. Latest decision wins (decisions can be changed).
-- Created in W4 for the exclusion query; nothing writes to it until W5.
CREATE TABLE decisions (
  tmdb_id          INTEGER PRIMARY KEY,
  decision         TEXT NOT NULL CHECK (decision IN ('yes','maybe','no')),
  conversation_id  TEXT NOT NULL REFERENCES conversations(id),  -- scopes 'maybe'; recorded for all
  decided_at       TEXT NOT NULL
);
