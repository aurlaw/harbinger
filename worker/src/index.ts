import { authenticate } from "./auth";
import { errorResponse } from "./http";
import { route } from "./router";

export default {
  async fetch(request, env): Promise<Response> {
    try {
      // Auth runs before routing so unauthenticated callers can't probe routes.
      const denied = authenticate(request, env);
      if (denied) return denied;
      return await route(request, env);
    } catch (err) {
      console.error("unhandled error", err);
      return errorResponse(500, "internal_error", "Internal server error");
    }
  },
} satisfies ExportedHandler<Env>;
