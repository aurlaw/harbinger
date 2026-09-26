# CLAUDE.md — harbinger/cli

Go CLI (macOS) that reads a Letterboxd export ZIP and, from C2 on, pushes it to the Worker. Read the repo-root `CLAUDE.md` first — its working agreement applies here.

## Layout

- `cmd/harbinger/main.go` — entry point; subcommand dispatch with `flag.NewFlagSet`. `run(args, stdout, stderr) int` holds all logic so tests drive it directly
- `internal/export/` — ZIP + CSV parsing, validation, and the W2 payload types (`export.go` types + `Parse`/`ParseFile`, `csv.go` row/field rules)
- `internal/normalize/` — `Title(s)`: comparison key for TMDB matching (used by C2)
- `Makefile` — `build`, `test`, `lint`

## Commands

Use `make`, not raw `go` commands:

- `make build` — builds `../bin/harbinger` (`bin/` at the repo root, gitignored)
- `make test` — `go test -race ./...`
- `make lint` — fails if `gofmt -l .` lists any file, then `go vet ./...`

Claude may also run `go mod tidy`. No git.

## Command shape

```
harbinger import --dry-run [--json] <export.zip>
```

- `--dry-run` prints a summary (counts, all ten rating buckets, rating date range); `--json` prints `Export` marshaled directly
- `import` without `--dry-run` → exit 1, "live import is not implemented yet (Phase C2)"
- Usage problems (no args, unknown subcommand, missing/extra args, unknown flag) → usage on stderr, exit 2. Parse/validation failure → `error: …` on stderr, exit 1. `--help` → usage on stdout, exit 0
- Subcommands are added as new `case`s in `run` (C2 adds `override`)

## Conventions

- **Standard library only.** No third-party modules, including test helpers (no cobra, no testify). `encoding/json` v1, not the `json/v2` experiment. Modern stdlib (`slices`, `maps`, `cmp`, range-over-int) is preferred where it simplifies
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

- Tests build ZIPs **in memory** with `archive/zip` (CLI tests write them to `t.TempDir()`). No binary fixtures, and never a real export in the repo (`*.zip` is gitignored here)
- Use CRLF in fixture CSVs to match the real export
- Keep the 5,000-row and over-20 MB cases; small fixtures won't catch size problems

## Scope reminders

C1 is offline only: no `net/http`, Worker client, API key handling, TMDB, reconcile, or `override` subcommand — all C2.
