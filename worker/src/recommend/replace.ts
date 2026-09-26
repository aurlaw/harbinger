import { type ClaudeConfig, type ClaudeMessage, ClaudeError, callClaude } from "../claude/client";
import { RECOMMEND_NOW } from "./prompt";
import { type ResolvedPick, resolvePick } from "./resolve";
import { type FilmPick, type InvalidPick, OUTPUT_SCHEMA, type Reply, parseReply } from "./schema";
import { type ExclusionSet, type RejectReason, checkPick } from "./validate";

// The replacement loop: resolve → validate the first reply's picks, then ask
// Claude for the shortfall, at most MAX_REPLACEMENT_ROUNDS times. Nothing from
// the replacement exchange is stored; only the final pick set is.

export const MAX_REPLACEMENT_ROUNDS = 2;

export interface Rejection {
  /** As Claude gave it (null when an invalid pick had no usable title). */
  title: string | null;
  year: number | null;
  reason: RejectReason;
  /** 0 = Claude's first reply, then 1..MAX_REPLACEMENT_ROUNDS. */
  round: number;
}

export interface PickResult {
  target: number;
  /** Originally accepted picks in Claude's order, then replacements in the order accepted. */
  accepted: ResolvedPick[];
  rejected: Rejection[];
  rounds: number;
}

export interface ReplacementContext {
  env: Env;
  config: ClaudeConfig;
  model: string;
  /** Same system prompt as the first call, so replacement rounds hit the cache. */
  system: string;
  /** History + this user turn + the first assistant reply (its JSON as returned). */
  messages: ClaudeMessage[];
  exclusions: ExclusionSet;
}

const REASON_PHRASES: Record<RejectReason, string> = {
  excluded: "already seen, on the watchlist, or already decided",
  not_horror: "not a horror film",
  not_feature: "not feature-length",
  unresolved: "not found on TMDB",
  duplicate: "duplicate",
  invalid: "invalid",
};

const label = (r: Pick<Rejection, "title" | "year">) =>
  `${r.title ?? "Untitled pick"}${r.year !== null ? ` (${r.year})` : ""}`;

/** The user turn for a replacement round. Lists every rejection so far (cumulative). */
export function replacementTurn(rejected: Rejection[], count: number): string {
  const reasons = rejected.map((r) => `${label(r)} — ${REASON_PHRASES[r.reason]}`).join("; ");
  const films = count === 1 ? "1 different film" : `${count} different films`;
  return (
    `These picks can't be used: ${reasons}. Recommend ${films} for the same request. ` +
    `Don't repeat any film recommended or rejected in this conversation. ${RECOMMEND_NOW}`
  );
}

/**
 * Runs validation and replacement for a recommendations reply. Target = the
 * first reply's valid pick count (≤ 5); Claude returning 2 on purpose isn't
 * padded. Claude / TMDB failures propagate (the request stores nothing).
 */
export async function pickFilms(
  ctx: ReplacementContext,
  first: { picks: FilmPick[]; invalid: InvalidPick[] },
): Promise<PickResult> {
  const target = first.picks.length;
  const accepted: ResolvedPick[] = [];
  const rejected: Rejection[] = [];
  const seen = { accepted: new Set<number>(), rejected: new Set<number>() };

  const reject = (rejection: Rejection) => {
    rejected.push(rejection);
    console.log(JSON.stringify({ event: "pick_rejected", ...rejection }));
  };

  const processRound = async (round: number, reply: { picks: FilmPick[]; invalid: InvalidPick[] }) => {
    for (const bad of reply.invalid) reject({ ...bad, reason: "invalid", round });
    // Resolve (and enrich) concurrently; validate in Claude's order.
    const resolved = await Promise.all(reply.picks.map((pick) => resolvePick(ctx.env, pick)));
    for (const [i, film] of resolved.entries()) {
      if (accepted.length >= target) break; // over-delivery: extras are discarded
      const pick = reply.picks[i]!;
      if (!film) {
        reject({ title: pick.title, year: pick.year, reason: "unresolved", round });
        continue;
      }
      const reason = checkPick(film, ctx.exclusions, seen);
      if (reason) {
        seen.rejected.add(film.tmdb_id);
        reject({ title: pick.title, year: pick.year, reason, round });
      } else {
        seen.accepted.add(film.tmdb_id);
        accepted.push(film);
      }
    }
  };

  await processRound(0, first);

  const messages = [...ctx.messages];
  let rounds = 0;
  while (accepted.length < target && rounds < MAX_REPLACEMENT_ROUNDS) {
    rounds++;
    messages.push({ role: "user", content: replacementTurn(rejected, target - accepted.length) });
    const raw = await callClaude(ctx.config, {
      model: ctx.model,
      system: ctx.system,
      messages,
      schema: OUTPUT_SCHEMA,
    });
    messages.push({ role: "assistant", content: JSON.stringify(raw) });

    let reply: Reply;
    try {
      reply = parseReply(raw);
    } catch (err) {
      // An unusable reply (e.g. an empty question) is a round with zero picks.
      if (err instanceof ClaudeError && err.code === "recommendation_failed") continue;
      throw err;
    }
    // A question is a round with zero picks.
    if (reply.kind === "recommendations") await processRound(rounds, reply);
  }

  console.log(
    JSON.stringify({ event: "pick_summary", target, accepted: accepted.length, rejected: rejected.length, rounds }),
  );
  return { target, accepted, rejected, rounds };
}
