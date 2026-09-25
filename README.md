# harbinger
A Horror Movie Recommendations APP

## Repo layout

- `worker/` — Cloudflare Worker + D1 API (`https://harbinger-api.aurlaw.dev`)
- `cli/` — Letterboxd import CLI (Go) — not yet built
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
