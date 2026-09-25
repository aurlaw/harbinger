import { health } from "./health";
import { errorResponse } from "./http";

type Handler = (request: Request, env: Env) => Promise<Response>;

const routes = new Map<string, Map<string, Handler>>([
  ["/health", new Map([["GET", health]])],
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
