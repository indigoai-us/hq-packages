// A small router over Web Request/Response, so the same handlers run under
// hq-deploy's per-app Lambda and the local dev server.

import { badRequest, HttpError } from "./errors.ts";
import { isRecord } from "./util.ts";

export const MAX_BODY_BYTES = 64 * 1024;

export interface RouteCtx<S> {
  req: Request;
  url: URL;
  params: Record<string, string>;
  query: URLSearchParams;
  ip: string;
  services: S;
  /** The JSON object body. Empty object when there is no body. */
  body(): Promise<Record<string, unknown>>;
}

export type Handler<S> = (c: RouteCtx<S>) => Promise<unknown> | unknown;

interface Route<S> {
  method: string;
  parts: string[];
  handler: Handler<S>;
}

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });
}

export function errorResponse(err: HttpError): Response {
  const headers: Record<string, string> = {};
  if (err.status === 429 && typeof err.details?.retryAfterSeconds === "number") headers["retry-after"] = String(err.details.retryAfterSeconds);
  return json({ error: { code: err.code, message: err.message, ...(err.details ? { details: err.details } : {}) } }, err.status, headers);
}

export function clientIp(req: Request): string {
  const fwd = req.headers.get("x-forwarded-for");
  const first = fwd?.split(",")[0]?.trim();
  return first || req.headers.get("x-real-ip") || "unknown";
}

async function readBody(req: Request): Promise<Record<string, unknown>> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) throw new HttpError(413, "too-large", "The request body is too large.");
  const raw = await req.text();
  if (Buffer.byteLength(raw, "utf8") > MAX_BODY_BYTES) throw new HttpError(413, "too-large", "The request body is too large.");
  if (raw.trim() === "") return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw badRequest("bad-json", "The request body is not valid JSON.");
  }
  if (!isRecord(parsed)) throw badRequest("bad-json", "The request body must be a JSON object.");
  return parsed;
}

export class Router<S> {
  private readonly routes: Route<S>[] = [];

  add(method: string, pattern: string, handler: Handler<S>): this {
    this.routes.push({ method, parts: pattern.split("/").filter(Boolean), handler });
    return this;
  }

  get(p: string, h: Handler<S>) {
    return this.add("GET", p, h);
  }
  post(p: string, h: Handler<S>) {
    return this.add("POST", p, h);
  }
  put(p: string, h: Handler<S>) {
    return this.add("PUT", p, h);
  }
  patch(p: string, h: Handler<S>) {
    return this.add("PATCH", p, h);
  }
  delete(p: string, h: Handler<S>) {
    return this.add("DELETE", p, h);
  }

  match(method: string, path: string): { handler: Handler<S>; params: Record<string, string> } | { allowed: string[] } | null {
    let segments: string[];
    try {
      segments = path.split("/").filter(Boolean).map(decodeURIComponent);
    } catch {
      return null;
    }
    const allowed = new Set<string>();
    for (const r of this.routes) {
      if (r.parts.length !== segments.length) continue;
      const params: Record<string, string> = {};
      let ok = true;
      for (let i = 0; i < r.parts.length; i++) {
        const part = r.parts[i] as string;
        const seg = segments[i] as string;
        if (part.startsWith(":")) params[part.slice(1)] = seg;
        else if (part !== seg) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      if (r.method === method || (method === "HEAD" && r.method === "GET")) return { handler: r.handler, params };
      allowed.add(r.method);
    }
    return allowed.size ? { allowed: [...allowed] } : null;
  }

  async handle(req: Request, services: S, onError: (err: unknown) => Response): Promise<Response> {
    const url = new URL(req.url);
    const found = this.match(req.method, url.pathname);
    if (!found) return errorResponse(new HttpError(404, "not-found", "There is no such API route."));
    if ("allowed" in found) {
      return json({ error: { code: "method-not-allowed", message: `Use ${found.allowed.join(" or ")} for this route.` } }, 405, { allow: found.allowed.join(", ") });
    }
    let bodyPromise: Promise<Record<string, unknown>> | undefined;
    const ctx: RouteCtx<S> = {
      req,
      url,
      params: found.params,
      query: url.searchParams,
      ip: clientIp(req),
      services,
      body: () => (bodyPromise ??= readBody(req)),
    };
    try {
      const result = await found.handler(ctx);
      return result instanceof Response ? result : json(result ?? { ok: true });
    } catch (err) {
      return onError(err);
    }
  }
}
