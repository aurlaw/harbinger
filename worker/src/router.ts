import { appendMessage, createConversation, getConversation, listModels } from "./conversations/handlers";
import { health } from "./health";
import { errorResponse } from "./http";
import { listFilms, setOverride, upsertFilms } from "./library/films";
import { latestImport, runImport } from "./library/imports";
import { recordMatches } from "./library/matches";
import { movieDetails } from "./tmdb/movie";
import { searchMovies } from "./tmdb/search";

type Params = Record<string, string>;
type Handler = (request: Request, env: Env, params: Params) => Promise<Response>;

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
  ["/tmdb/search", new Map([["GET", searchMovies]])],
  ["/models", new Map([["GET", listModels]])],
  ["/conversations", new Map([["POST", createConversation]])],
]);

// Parameterized routes, checked after the static map. Named groups become params.
const paramRoutes: { pattern: RegExp; methods: Map<string, Handler> }[] = [
  { pattern: /^\/tmdb\/movie\/(?<id>[^/]+)$/, methods: new Map([["GET", movieDetails]]) },
  { pattern: /^\/conversations\/(?<id>[^/]+)$/, methods: new Map([["GET", getConversation]]) },
  { pattern: /^\/conversations\/(?<id>[^/]+)\/messages$/, methods: new Map([["POST", appendMessage]]) },
];

function match(pathname: string): { methods: Map<string, Handler>; params: Params } | null {
  const methods = routes.get(pathname);
  if (methods) return { methods, params: {} };
  for (const { pattern, methods } of paramRoutes) {
    const groups = pattern.exec(pathname)?.groups;
    if (groups) return { methods, params: { ...groups } };
  }
  return null;
}

export async function route(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  const matched = match(pathname);
  if (!matched) {
    return errorResponse(404, "not_found", "Not found");
  }
  const { methods, params } = matched;
  const handler = methods.get(request.method);
  if (!handler) {
    return errorResponse(405, "method_not_allowed", "Method not allowed", {
      Allow: [...methods.keys()].join(", "),
    });
  }
  return handler(request, env, params);
}
