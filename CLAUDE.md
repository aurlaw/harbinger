# CLAUDE.md — harbinger

Personal horror movie recommendation app for one user. LLM-driven picks from Letterboxd ratings and watchlist. Three components in one repo: a Go import CLI (macOS), a TypeScript Cloudflare Worker + D1 (source of truth; assembles prompts and calls Claude), and a native Swift/SwiftUI iOS app (SwiftData read cache, one-way sync). Full plan and decisions: `Tech/harbinger/` in the Obsidian vault (`concept-brief`, `data-mapping`, `phases/`). Michael will paste relevant sections into briefs.

## Repo layout

- `worker/` — TypeScript Cloudflare Worker + D1 (`harbinger-api.aurlaw.dev`)
- `cli/` — Go Letterboxd import CLI
- `ios/` — Swift/SwiftUI app

Each component has (or will have, once scaffolded) its own `CLAUDE.md`. Read it before working in that directory.

## Working agreement

- Michael runs all `git` commands, `wrangler` deploys, Apple signing, and any dashboard/provisioning work. Never commit, push, deploy, or create infrastructure.
- Claude Code may author files and run installs, tests, typechecks, and linters. Nothing that touches remote resources (`--remote`, `wrangler secret`, `wrangler deploy`, `wrangler d1 create`).
- Work is phase-driven. Each session implements one brief. Stay inside the brief's scope; if something outside it needs changing, say so and stop.
- Modifying existing code = surgical change, not a rewrite.
- No secrets in the repo, ever. Local Worker secrets live in `worker/.dev.vars` (gitignored).
- The D1 schema in `data-mapping` is canonical. If it looks wrong, flag it; don't change it.
- Verify SDK and tooling APIs against the installed version's docs, not memory. Several have changed recently.