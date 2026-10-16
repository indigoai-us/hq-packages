// Builds the booking API from a config, a store and providers. hq-deploy
// (deployed.ts) and the dev server (dev/server.ts) both call this.

import { randomBytes } from "node:crypto";
import { registerAgentRoutes } from "./agent-api.ts";
import type { BookingConfig } from "./engine.ts";
import { ConflictError, HttpError, ProviderError } from "./errors.ts";
import { bookingKeyAuth, hqProProviders, type FetchLike } from "./hqpro.ts";
import { errorResponse, json, Router } from "./http.ts";
import { registerOwnerRoutes } from "./owner-api.ts";
import type { Providers } from "./providers.ts";
import { registerPublicRoutes } from "./public-api.ts";
import { sandboxProviders, SandboxCalendar, SandboxVideo } from "./sandbox.ts";
import { claimMinutesFor, type Services } from "./services.ts";
import type { Store } from "./store.ts";
import { sha256Hex } from "./util.ts";

export interface BuildOptions {
  config: BookingConfig;
  store: Store;
  now?: () => number;
  fetch?: FetchLike;
  secrets?: Record<string, string>;
  env?: Record<string, string>;
  appId?: string;
  log?: (message: string) => void;
  allowLocalWebhooks?: boolean;
  /** Replace the providers chosen from config (tests). */
  providers?: Providers;
}

export function buildServices(o: BuildOptions): Services {
  const now = o.now ?? Date.now;
  const env = o.env ?? {};
  const secrets = o.secrets ?? {};
  const fetchFn = o.fetch ?? (globalThis.fetch as unknown as FetchLike);
  let providers: Providers;
  let sandbox: SandboxCalendar | undefined;
  if (o.providers) {
    providers = o.providers;
  } else if (o.config.prototype?.provider === "hqpro") {
    const baseUrl = env.HQ_BOOKING_API_URL;
    const key = secrets.HQ_BOOKING_KEY;
    if (!baseUrl || !key) {
      throw new HttpError(503, "provider-not-configured", "This booking app is set to use hq-pro, but HQ_BOOKING_API_URL or the HQ_BOOKING_KEY secret is missing.");
    }
    // Video stays sandboxed in the prototype until hq-pro meeting creation is live.
    providers = hqProProviders({ baseUrl, authorize: bookingKeyAuth(key), appId: o.appId ?? "local", fetch: fetchFn }, new SandboxVideo());
  } else {
    const p = sandboxProviders(o.store, now);
    providers = p;
    sandbox = p.calendar;
  }
  if (!sandbox && providers.calendar instanceof SandboxCalendar) sandbox = providers.calendar;
  const ownerHash = o.config.prototype?.ownerKeySha256;
  const tokenKey =
    secrets.BOOKING_TOKEN_KEY ?? (ownerHash ? sha256Hex(`hq-booking-token|${ownerHash}|${o.appId ?? o.config.company}`) : randomBytes(32).toString("hex"));
  return {
    config: o.config,
    store: o.store,
    providers,
    ...(sandbox ? { sandbox } : {}),
    now,
    fetch: fetchFn,
    secrets,
    log: o.log ?? ((m) => console.error(m)),
    ...(env.PUBLIC_BASE_URL ? { publicBaseUrl: env.PUBLIC_BASE_URL } : {}),
    claimMinutes: claimMinutesFor(o.config),
    tokenKey,
    allowLocalWebhooks: o.allowLocalWebhooks === true,
  };
}

const SECURITY_HEADERS: Record<string, string> = {
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
};

function isPublicPath(path: string): boolean {
  return path.startsWith("/api/") && !path.startsWith("/api/owner/") && !path.startsWith("/api/agent/");
}

export function errorToResponse(err: unknown, log: (m: string) => void): Response {
  if (err instanceof HttpError) return errorResponse(err);
  if (err instanceof ConflictError) return errorResponse(new HttpError(409, "conflict", "Someone else changed this at the same moment. Reload and try again."));
  if (err instanceof ProviderError) return errorResponse(new HttpError(err.status === 404 ? 404 : 502, "provider-failed", err.message));
  log(`unhandled error: ${err instanceof Error ? err.message : String(err)}`);
  return errorResponse(new HttpError(500, "internal", "Something went wrong on our side. Try again in a minute."));
}

export interface BookingApp {
  services: Services;
  handle(req: Request): Promise<Response>;
}

export function createBookingApp(services: Services): BookingApp {
  const router = new Router<Services>();
  registerPublicRoutes(router);
  registerOwnerRoutes(router);
  registerAgentRoutes(router);
  const allowed = new Set(services.config.embed?.allowedOrigins ?? []);

  return {
    services,
    async handle(req: Request): Promise<Response> {
      const url = new URL(req.url);
      const origin = req.headers.get("origin");
      const cors: Record<string, string> = {};
      if (origin && allowed.has(origin) && isPublicPath(url.pathname)) {
        cors["access-control-allow-origin"] = origin;
        cors.vary = "Origin";
      }
      let res: Response;
      if (req.method === "OPTIONS") {
        res = new Response(null, {
          status: 204,
          headers: cors["access-control-allow-origin"]
            ? { ...cors, "access-control-allow-methods": "GET, POST, DELETE", "access-control-allow-headers": "content-type", "access-control-max-age": "600" }
            : {},
        });
      } else {
        try {
          res = await router.handle(req, services, (err) => errorToResponse(err, services.log));
        } catch (err) {
          res = errorToResponse(err, services.log);
        }
      }
      const headers = new Headers(res.headers);
      for (const [k, v] of Object.entries({ ...SECURITY_HEADERS, ...cors })) headers.set(k, v);
      return new Response(req.method === "HEAD" ? null : res.body, { status: res.status, headers });
    },
  };
}

/** For failures before the app exists (bad provider settings at cold start). */
export function startupFailure(err: unknown): Response {
  const r = errorToResponse(err, (m) => console.error(m));
  return r.status === 500 ? json({ error: { code: "unavailable", message: "The booking app could not start. Check its settings and secrets, then redeploy." } }, 503) : r;
}
