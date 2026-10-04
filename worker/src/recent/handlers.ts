import { errorResponse, json } from "../http";
import { refreshRecentReleases } from "./refresh";

// POST /jobs/recent-releases — runs the weekly refresh now (for checking after a deploy).

export async function runRecentReleases(_request: Request, env: Env): Promise<Response> {
  if (!env.TMDB_READ_TOKEN) {
    // Fail closed without making an outbound request.
    console.error("TMDB_READ_TOKEN is not configured");
    return errorResponse(500, "internal_error", "Internal server error");
  }
  const result = await refreshRecentReleases(env, new Date());
  // The previous list is kept on any failure.
  if (!result.ok) return errorResponse(502, "tmdb_unavailable", "TMDB is unavailable");
  return json(200, { count: result.count, last_success_at: result.last_success_at });
}
