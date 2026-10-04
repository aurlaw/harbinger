import { authenticate } from "./auth";
import { errorResponse } from "./http";
import { RECENT_RELEASES_CRON, refreshRecentReleases } from "./recent/refresh";
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

  scheduled(controller, env, ctx): void {
    switch (controller.cron) {
      case RECENT_RELEASES_CRON:
        // Never rejects: the job catches and logs its own errors.
        ctx.waitUntil(refreshRecentReleases(env, new Date(controller.scheduledTime)));
        break;
      default:
        console.warn(`scheduled: unknown cron "${controller.cron}"`);
    }
  },
} satisfies ExportedHandler<Env>;
