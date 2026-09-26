# harbinger
A Horror Movie Recommendations APP

## Repo layout

- `worker/` — Cloudflare Worker + D1 API (`https://harbinger-api.aurlaw.dev`)
- `cli/` — Letterboxd import CLI (Go)
- `ios/` — iOS app (SwiftUI) — not yet built

## Worker

TypeScript Cloudflare Worker backed by a D1 database. Every request needs `Authorization: Bearer <API_KEY>`.

All commands below run from `worker/`.

### Prerequisites

- Node.js and npm
- A Cloudflare account with the `aurlaw.dev` zone (for deploys), logged in via `npx wrangler login`

### First-time setup

```sh
cd worker
npm install
cp .dev.vars.example .dev.vars   # then set API_KEY to any local value
```

`.dev.vars` is gitignored. Never commit keys.

### Run locally

```sh
npm run db:migrate:local   # apply migrations to the local D1 database
npm run dev                # http://localhost:8787
```

```sh
curl -H "Authorization: Bearer <local key>" http://localhost:8787/health
# {"status":"ok"}
```

Local D1 data lives in `worker/.wrangler/` (gitignored). Delete that directory to start from an empty database, then re-run `npm run db:migrate:local`.

### Test and typecheck

```sh
npm test            # Vitest in the Workers runtime; migrations applied automatically
npm run typecheck
```

After changing `wrangler.jsonc`, regenerate the `Env` types with `npm run types`.

### Database migrations

Migrations are plain SQL files in `worker/migrations/`, applied in filename order.

```sh
npx wrangler d1 migrations create harbinger <name>      # new empty migration file
npx wrangler d1 migrations list harbinger --local       # unapplied, local
npx wrangler d1 migrations list harbinger --remote      # unapplied, production
npm run db:migrate:local                                # apply locally
npx wrangler d1 migrations apply harbinger --remote     # apply to production
```

- Never edit a migration that has already been applied. Add a new one instead.
- A migration file must not end with a comment line (it breaks the test setup).
- Apply remote migrations **before** deploying code that depends on them.

### Deploy

```sh
npx wrangler d1 migrations apply harbinger --remote   # if there are new migrations
npx wrangler deploy
```

The Worker is served only at `https://harbinger-api.aurlaw.dev`. `workers.dev` and preview URLs are disabled.

Check the deploy:

```sh
curl -H "Authorization: Bearer <prod key>" https://harbinger-api.aurlaw.dev/health
# {"status":"ok"}
curl https://harbinger-api.aurlaw.dev/health
# 401
```

### Secrets

| Secret | Local | Production |
|---|---|---|
| `API_KEY` | `worker/.dev.vars` | `npx wrangler secret put API_KEY` |

Generate a production key with `openssl rand -base64 32`.

### One-time provisioning

1. `npx wrangler d1 create harbinger`, then put the returned `database_id` in `wrangler.jsonc`
2. `npx wrangler secret put API_KEY`
3. `npx wrangler d1 migrations apply harbinger --remote`
4. `npx wrangler deploy` (creates the custom domain's DNS record and certificate)

## CLI

Go command-line tool (`harbinger`) that imports a Letterboxd export into the Worker. It parses the export ZIP, updates the film library and the ratings/watched/watchlist/likes snapshot, and matches new films to TMDB through the Worker. TMDB is only reached through the Worker, so the CLI never needs a TMDB token.

All build commands below run from `cli/`.

### Prerequisites

- Go 1.26 or newer
- The Worker's production `API_KEY` (for every command except `--dry-run`)
- A Letterboxd export ZIP: letterboxd.com → Settings → Data → Export your data

### Build, test, lint

```sh
cd cli
make build   # builds ../bin/harbinger (bin/ at the repo root, gitignored)
make test    # go test -race ./...
make lint    # gofmt check + go vet
```

Run the binary from the repo root as `./bin/harbinger`. Never commit an export ZIP (`*.zip` is gitignored in `cli/`).

### Configuration

| Env var | Required | Default | Purpose |
|---|---|---|---|
| `HARBINGER_API_KEY` | Yes, except for `--dry-run` | — | The Worker's `API_KEY`, sent as `Authorization: Bearer …` |
| `HARBINGER_API_URL` | No | `https://harbinger-api.aurlaw.dev` | Worker base URL. Set it to `http://localhost:8787` to import into a local `npm run dev` Worker |

```sh
export HARBINGER_API_KEY=...   # keep it out of shell history, e.g. load it from your password manager's CLI
```

The CLI never prints the key, including in error messages. There is no config file.

### Commands

```
harbinger import [--force] [--no-interactive] [--retry-unmatched] <export.zip>
harbinger import --dry-run [--json] <export.zip>
harbinger films [--status <status>] [--horror | --not-horror] [--search <text>]
harbinger override include|exclude|clear <letterboxd-uri>
harbinger --help
```

Flags go **before** the ZIP path.

#### `harbinger import <export.zip>`

Imports an export into the Worker:

1. Parses and validates `ratings.csv`, `watched.csv`, `watchlist.csv` and `likes/films.csv` from the ZIP. Other files are ignored. Any bad row stops the import with the file and line number.
2. Adds new films to the library and updates changed names or years. Existing TMDB matches are kept.
3. Replaces the ratings, watched, watchlist and likes snapshot with the export's contents.
4. Matches films that haven't been matched yet (status `pending`) to TMDB, printing progress (`[12/267] Title (Year) … matched`).
5. Prints a summary.

Re-importing the same export makes no TMDB calls: only films never seen before need matching.

| Flag | Purpose |
|---|---|
| `--dry-run` | Parse and validate only. Nothing is sent and no API key is needed. Prints counts, the ratings distribution and the rating date range. Use it to check a new export before importing |
| `--json` | With `--dry-run`: print the exact data that would be sent to the Worker as JSON instead of the summary. Not allowed without `--dry-run` |
| `--force` | Import even if it would empty a snapshot table that currently has rows (for example, a `likes/films.csv` with no rows). Without it the Worker refuses, as a guard against a truncated export |
| `--no-interactive` | Never prompt. Films without a confident match are recorded as `ambiguous` (candidates were found) or `unmatched` (nothing found). Prompts are also skipped automatically when stdin isn't a terminal |
| `--retry-unmatched` | Also re-try films previously recorded as `ambiguous` or `unmatched`, not just new ones |

**Matching.** Each film is searched on TMDB by title, first with its release year, then with any year field, then with no year. A result counts as a candidate if its title or original title matches (ignoring case, dash style, curly quotes and extra spaces) and its release year is within one year. One candidate, or exactly one with the exact year, is matched automatically. Anything else needs a decision.

**Prompts.** When a film needs a decision and the session is interactive:

```
? No confident match for "The Thing" (1982)
  1) The Thing (1982) — In remote Antarctica, a group of American research scientis… [horror]
  2) The Thing (2011) — Prequel. [horror]
  [1-2] choose · [m] enter TMDB ID · [s] skip · [q] quit matching
>
```

| Input | Effect |
|---|---|
| `1`–`N` | Match that candidate |
| `m` | Enter a TMDB movie ID (the number in a themoviedb.org movie URL). An unknown ID is reported and you're asked again |
| `s` | Skip: recorded as `ambiguous` if candidates were shown, `unmatched` if none |
| `q` | Stop matching. Everything answered so far is saved, the snapshot is already imported, and the remaining films stay `pending` for the next import. Exits 0 |

Use `q` rather than Ctrl-C. Ctrl-C can lose up to 24 recent answers that haven't been sent yet.

If TMDB fails for a film even after retries, the film stays `pending` and is retried on the next import.

**Summary.**

```
Import #4 from letterboxd-aurlaw-2026-09-24-21-54-utc.zip
  snapshot   ratings 238 · watched 238 · watchlist 29 · likes 12 · new films 4
  matching   4 attempted · 3 auto · 1 chosen · 0 ambiguous · 0 unmatched · 0 left pending
  library    267 films · 131 horror · 2 ambiguous · 1 unmatched
```

#### `harbinger films`

Lists library films, mainly to find a film's Letterboxd URI for `override`. Output is sorted by name:

```
-  Hereditary (2018)  matched  override:exclude  https://boxd.it/def
H  The Witch (2015)  matched  https://boxd.it/abc
```

Each line shows `H` if the film counts as horror (`-` if not), then the name and year, match status, any genre override, and the URI.

| Flag | Purpose |
|---|---|
| `--status <status>` | Only films with this match status: `pending`, `matched`, `ambiguous` or `unmatched` |
| `--horror` | Only films that count as horror |
| `--not-horror` | Only films that don't. Can't be combined with `--horror` |
| `--search <text>` | Only films whose name contains the text (ignoring case, dash style, curly quotes and extra spaces) |

A film counts as horror if its genre override is `include`, or it has no override and TMDB lists it as Horror. A film with override `exclude` never counts, and an unmatched film counts only with `include`.

#### `harbinger override include|exclude|clear <letterboxd-uri>`

Corrects TMDB's horror classification for one film and prints the updated film line.

| Action | Purpose |
|---|---|
| `include` | Always treat the film as horror |
| `exclude` | Never treat the film as horror |
| `clear` | Remove the override and go back to TMDB's genres |

Overrides are kept across imports.

```sh
./bin/harbinger films --search "the thing"
./bin/harbinger override include https://boxd.it/abc
```

### Typical workflow

```sh
cd cli && make build && cd ..
./bin/harbinger import --dry-run ~/Downloads/letterboxd-*.zip   # check the export
./bin/harbinger import ~/Downloads/letterboxd-*.zip             # import and answer prompts
./bin/harbinger films --status ambiguous                        # review skipped films
./bin/harbinger import --retry-unmatched ~/Downloads/letterboxd-*.zip   # try them again later
```

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success, including quitting matching with `q` |
| `1` | Error: missing API key, invalid export, Worker or network failure, empty-snapshot guard, unknown URI for `override` |
| `2` | Usage error: unknown command or flag, wrong number of arguments, conflicting flags. Nothing is sent to the Worker |
