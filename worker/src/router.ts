import { health } from "./health";
import { errorResponse } from "./http";
import { listFilms, setOverride, upsertFilms } from "./library/films";
import { latestImport, runImport } from "./library/imports";
import { recordMatches } from "./library/matches";

type Handler = (request: Request, env: Env) => Promise<Response>;

const routes = new Map<string, Map<string, Handler>>([
  ["/health", new Map([["GET", health]])],
  [
    "/library/films",
    new Map([
      ["GET", listFilms],
      ["POST", upsertFilms],
    ]),
  ],
  ["/library/films/matches", new Map([["POST", recordMatches]])],
  ["/library/films/override", new Map([["PUT", setOverride]])],
  ["/library/import", new Map([["POST", runImport]])],
  ["/library/imports/latest", new Map([["GET", latestImport]])],
]);

export async function route(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  const methods = routes.get(pathname);
  if (!methods) {
    return errorResponse(404, "not_found", "Not found");
  }
  const handler = methods.get(request.method);
  if (!handler) {
    return errorResponse(405, "method_not_allowed", "Method not allowed", {
      Allow: [...methods.keys()].join(", "),
    });
  }
  return handler(request, env);
}
