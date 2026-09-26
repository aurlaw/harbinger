-- Taste profile. Source: taste-profile.md (D1 table section).

-- Single row, enforced by CHECK (id = 1); saves are upserts.
CREATE TABLE taste_profile (
  id                  INTEGER PRIMARY KEY CHECK (id = 1),
  content             TEXT NOT NULL,
  based_on_import_id  INTEGER REFERENCES imports(id),      -- ratings it was drafted from
  updated_at          TEXT NOT NULL
);
