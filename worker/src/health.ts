import { errorResponse, json } from "./http";

export async function health(_request: Request, env: Env): Promise<Response> {
  try {
    await env.DB.prepare("SELECT COUNT(*) AS count FROM films").first();
  } catch (err) {
    console.error("health: database check failed", err);
    return errorResponse(503, "db_unavailable", "Database unavailable");
  }
  return json(200, { status: "ok" });
}
