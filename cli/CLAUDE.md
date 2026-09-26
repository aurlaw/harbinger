# CLAUDE.md — harbinger/cli

Go CLI (macOS) that reads a Letterboxd export ZIP, pushes it to the Worker, and matches new films on TMDB through the Worker's proxy. Read the repo-root `CLAUDE.md` first — its working agreement applies here.

## Layout

- `cmd/harbinger/main.go` — entry point, subcommand dispatch with `flag.NewFlagSet`, `import` (dry-run + live). `run(args, stdout, stderr)` wraps `runWith(args, deps)`; `deps` injects stdin/stdout/stderr, `getenv`, and the terminal check so tests never touch the real environment
- `cmd/harbinger/library.go` — `films`, `override`, `newWorker` (env → client), `filmLine`
- `internal/export/` — ZIP + CSV parsing, validation, and the W2 payload types (`export.go` types + `Parse`/`ParseFile`, `csv.go` row/field rules)
- `internal/normalize/` — `Title(s)`: comparison key for TMDB matching
- `internal/api/` — `Worker` interface (every W2/W3 endpoint) and `Client`, its only HTTP implementation; `APIError`; request/response types
- `internal/match/` — matching strategy, pure logic over a `SearchFunc`
- `internal/prompt/` — interactive disambiguation over an injected `io.Reader` / `io.Writer`
- `internal/importer/` — live import pipeline orchestration and summary; depends on `api.Worker` and a `Decider` (nil = non-interactive)
- `Makefile` — `build`, `test`, `lint`

## Commands

Use `make`, not raw `go` commands:

- `make build` — builds `../bin/harbinger` (`bin/` at the repo root, gitignored)
- `make test` — `go test -race ./...`
- `make lint` — fails if `gofmt -l .` lists any file, then `go vet ./...`

Claude may also run `go mod tidy`. No git.

## Command reference

```
harbinger import [--force] [--no-interactive] [--retry-unmatched] <export.zip>
harbinger import --dry-run [--json] <export.zip>
harbinger films [--status pending|matched|ambiguous|unmatched] [--horror | --not-horror] [--search <text>]
harbinger override include|exclude|clear <letterboxd-uri>
```

- `--dry-run`: offline, no key; prints a summary (counts, all ten rating buckets, rating date range). `--json` prints `Export` marshaled directly and requires `--dry-run` (else exit 2)
- `--force` sends `force: true` (bypasses the Worker's empty-file guard). `--no-interactive` never prompts. `--retry-unmatched` also re-attempts `ambiguous` and `unmatched` films
- `films`: one line per film — `H`/`-` effective horror marker, name (year), status, `override:<value>` if set, URI — sorted by normalized name. `--search` is a `normalize.Title` substring match; `--horror`/`--not-horror` use the effective rule and are mutually exclusive (exit 2)
- `override`: `PUT /library/films/override` with `"include"`, `"exclude"`, or `null` (clear); prints the updated film line. `404` → `no film with URI …`, exit 1
- Exit codes: usage problems (no args, unknown subcommand, bad/missing args, unknown flag, invalid flag value) → usage on stderr, exit 2, checked before any network call. Missing key, parse/validation failure, Worker error → stderr, exit 1. `--help` → usage on stdout, exit 0. Quitting matching with `q` → exit 0
- Subcommands are added as new `case`s in `runWith`

## Configuration

| Env var | Required | Default |
|---|---|---|
| `HARBINGER_API_KEY` | Yes, for every live command | — |
| `HARBINGER_API_URL` | No | `https://harbinger-api.aurlaw.dev` |

- Missing/empty key on a live command → `HARBINGER_API_KEY is not set`, exit 1. `--dry-run` never reads it. No config file
- The key is **never** printed, logged, or included in error messages. Client errors are built from method + path + cause, never from request headers

## Worker client (`internal/api`)

- Callers depend on the `Worker` interface; `Client` is the only HTTP implementation. Tests use fakes (`importer`) or `httptest.Server` with the real client (`api`, `cmd/harbinger`)
- Every request: `Authorization: Bearer <key>`, `Accept: application/json`, `User-Agent: harbinger-cli`; `Content-Type: application/json` on bodies. URLs via `url.URL.JoinPath` + `url.Values` — no string concatenation with user input
- Per-attempt timeout 30 s via `context`. Non-2xx → `*APIError{Status, Code, Message}` from the error envelope (`IsAPIError` helper)
- **Retry policy** (every W2 write is idempotent): `503 tmdb_rate_limited` → wait `Retry-After` s (default 2 s), up to 3 attempts total. Network error / `502` / other `5xx` → up to 2 retries, 1 s then 2 s. `4xx` never retried. `Client.sleep` is swappable so tests don't wait
- `MovieTMDB` returns the body verbatim as `json.RawMessage`; it is sent back as `tmdb_json` byte-for-byte. Request bodies are encoded with `SetEscapeHTML(false)` — `json.Marshal` would rewrite `&`, `<`, `>` inside the raw message. Only `is_horror` is decoded (`MovieIsHorror`)
- `Match`: `Matched(...)` carries `tmdb_id`, `is_horror` (0/1), `tmdb_json`; `Unresolved(...)` omits all three (pointers + `omitempty`) because W2 rejects them on `ambiguous`/`unmatched`
- Effective horror rule: `LibraryFilm.EffectiveHorror()` — override wins, else `is_horror == 1`

## Import pipeline (`internal/importer`)

Order matters — snapshot before matching, so quitting mid-match never loses the import:

1. Parse (C1); fail fast
2. `POST /library/films` with every `Export.Films` entry
3. `POST /library/import` (`source_filename` = ZIP base name). `409 empty_snapshot` → `EmptySnapshotError` (Worker message + `re-run with --force if this is intentional`), exit 1, no matching
4. `GET /library/films` → `pending` films (+ `ambiguous`/`unmatched` with `--retry-unmatched`), in Worker order
5. Match each sequentially (no concurrency), printing `[i/n] Name (Year) … <outcome>`
6. `POST /library/films/matches` in batches of 25, flushed as batches fill, on quit, on error, and at the end
7. Summary (`Summary.Print`); `library` counts come from a final `GET /library/films`

- A film whose TMDB calls fail after retries is **left `pending`** (not recorded), counted as "left pending", and retried on the next import. On `q`, the current film and every film not reached also count as left pending
- Re-importing the same export makes zero TMDB calls: only never-seen films are `pending`

## Matching strategy (`internal/match`)

- Up to three searches, stopping at the first stage with any filtered candidates: (1) `query` + `primary_release_year`, (2) `query` + `year`, (3) `query` only
- Filter: `normalize.Title(name)` equals `normalize.Title` of `title` **or** `original_title`, and release year within ±1 (`release_date: null` excluded)
- Decide: exactly one filtered → auto; several with exactly one exact-year → auto that one; otherwise needs a decision
- `Result.Candidates` (for a decision) = the filtered candidates, else the top 5 results of the last stage run, else empty
- Undecided films: interactive → prompt; non-interactive → `ambiguous` if candidates were offered, `unmatched` if none

## Interactive prompt (`internal/prompt`)

- Interactive only if stdin is a character device **and** `--no-interactive` isn't set
- `1-N` choose · `m` enter TMDB ID (fetched via `/tmdb/movie`; 404 → message + re-prompt) · `s` skip (→ `ambiguous` with candidates, `unmatched` without) · `q` quit matching. Invalid input re-prompts; EOF = `q`
- One `Prompter` per import (its `bufio.Scanner` holds buffered input across films). Never read `os.Stdin` inside the package

## Conventions

- **Standard library only.** No third-party modules, including test helpers (no cobra, no testify; HTTP tests use `net/http/httptest`). `encoding/json` v1, not the `json/v2` experiment. Modern stdlib (`slices`, `maps`, `cmp`, range-over-int) is preferred where it simplifies
- **Go version:** `go.mod` declares `go 1.26`; no `toolchain` line
- **Payload types:** JSON tags in `internal/export` match the Worker's W2 request payloads exactly, so C2 sends them as-is. `Export.Films` is the de-duplicated union across all four files sorted by URI; snapshot slices keep file order and marshal as `[]`, never `null`
- **Stored names are never normalized.** `normalize.Title` is only a matching key
- **Source files:** write invisible or confusable characters (BOM, NBSP, curly quotes, em space) as `\u` escapes, not literal characters

## Parsing rules (`internal/export`)

- Required entries at the ZIP root, located by exact name: `ratings.csv`, `watched.csv`, `watchlist.csv`, `likes/films.csv`. Missing (or duplicated) → error naming it. **No other entry is ever opened** — in particular `diary.csv`, whose URIs are diary-entry URIs, not film URIs
- Each required entry is capped at 20 MB uncompressed, checked against the header **and** enforced with an `io.LimitReader`
- `encoding/csv`; strip a leading UTF-8 BOM from the header's first field. Header must match exactly: `Date,Name,Year,Letterboxd URI` (+ `,Rating` for `ratings.csv`). Every row must have the header's field count
- Errors name the file and line (`csv.Reader.FieldPos`), e.g. `watched.csv line 12: Year "abc" must be …`
- Fields:
  - `Date` — `time.DateOnly`; stored as the original string
  - `Name` — non-empty after trim; stored byte-for-byte as exported
  - `Year` — integer 1870–2100, no sign or leading zeros; empty is an error (`films.year` is `NOT NULL`)
  - `Letterboxd URI` — trimmed; `https://boxd.it/` + a non-empty code, otherwise opaque
  - `Rating` — exactly `0.5`…`5` in half steps, whole numbers with or without `.0`; `HalfStars` = rating × 2. Anything else is an error
- Duplicate URI within a file → error naming both lines. Same URI with a different name or year in another file → "inconsistent export" error naming both locations
- Header-only files are valid (empty snapshots); the empty-file guard lives in the Worker/C2

## Title normalization (`internal/normalize`)

En/em dash → `-`; curly single/double quotes → straight; Unicode whitespace runs → one space; trim; `strings.ToLower`.

**Known limitation:** no Unicode normalization (NFC/NFKD) — that needs `golang.org/x/text`, which the stdlib-only rule excludes. A title exported in decomposed form won't match its precomposed TMDB spelling.

## Testing

- **Test credentials:** never write key-shaped literals in tests or docs — build them at runtime (`strings.Repeat("k", 32)`). GitHub push protection blocks realistic-looking secrets
- CLI tests call `runWith` with an injected `getenv`; never add a test that runs a live command through `run`, which reads the real environment and could hit the production Worker
- Claude never runs the CLI against the real Worker

- Tests build ZIPs **in memory** with `archive/zip` (CLI tests write them to `t.TempDir()`). No binary fixtures, and never a real export in the repo (`*.zip` is gitignored here)
- Use CRLF in fixture CSVs to match the real export
- Keep the 5,000-row and over-20 MB cases; small fixtures won't catch size problems

## Scope reminders

C1: offline parsing. C2: live import, `films`, `override`. TMDB is only ever reached through the Worker's `/tmdb/*` endpoints. No Worker changes from this component — if an endpoint blocks CLI work, stop and flag it.
