// Local dev server: the same API handlers as on hq-deploy, with the in-memory
// store and SANDBOX providers, plus static files from dist/ when the UI has
// been built. Data lives only as long as the process.
//
//   npm run dev                                   # api/_lib/booking.config.json
//   npm run dev -- --config ../booking/booking.yaml --port 5180
//
// OWNER_KEY=<key> sets the owner key (its SHA-256 replaces the config's);
// without it, a fresh key is printed at start. Due reminders and webhook
// retries run every 30 seconds (POST /api/owner/jobs/run does the same).

import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, extname, join, normalize, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { buildServices, createBookingApp, type BookingApp } from "../api/_lib/app.ts";
import { MemoryStore } from "../api/_lib/memory-store.ts";
import { runJobs } from "../api/_lib/owner-api.ts";
import { sha256Hex } from "../api/_lib/util.ts";
import { checkBookingYaml, checkConfig, type BookingConfig } from "../shared/config.ts";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
};

export function loadConfig(path: string): BookingConfig {
  const raw = readFileSync(path, "utf8");
  const result = /\.ya?ml$/i.test(path) ? checkBookingYaml(raw) : checkConfig(JSON.parse(raw));
  if (!result.ok || !result.config) {
    const lines = result.errors.map((e) => `  ${e.path || "(file)"}: ${e.message}`).join("\n");
    throw new Error(`${path} has problems:\n${lines}`);
  }
  return result.config;
}

async function toRequest(req: IncomingMessage, origin: string): Promise<Request> {
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) {
    if (v === undefined) continue;
    headers.set(k, Array.isArray(v) ? v.join(", ") : v);
  }
  // Like the front door, the server decides the client address.
  headers.set("x-forwarded-for", req.socket.remoteAddress ?? "127.0.0.1");
  const chunks: Buffer[] = [];
  if (req.method !== "GET" && req.method !== "HEAD") for await (const c of req) chunks.push(c as Buffer);
  return new Request(new URL(req.url ?? "/", origin), {
    method: req.method,
    headers,
    ...(chunks.length ? { body: Buffer.concat(chunks) } : {}),
  });
}

async function send(res: ServerResponse, r: Response): Promise<void> {
  res.statusCode = r.status;
  r.headers.forEach((v, k) => res.setHeader(k, v));
  res.end(Buffer.from(await r.arrayBuffer()));
}

function serveStatic(res: ServerResponse, distDir: string, path: string): void {
  if (!existsSync(join(distDir, "index.html"))) {
    res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
    res.end("HQ Booking API is running (sandbox). Build the booking pages into dist/ to see them here.\n");
    return;
  }
  let file = normalize(join(distDir, decodeURIComponent(path)));
  if (!file.startsWith(distDir + sep) && file !== distDir) {
    res.writeHead(404).end();
    return;
  }
  if (!existsSync(file) || statSync(file).isDirectory()) file = join(distDir, "index.html");
  res.writeHead(200, { "content-type": TYPES[extname(file)] ?? "application/octet-stream" });
  res.end(readFileSync(file));
}

export interface DevServer {
  url: string;
  ownerKey: string | null;
  app: BookingApp;
  close(): Promise<void>;
}

export async function startDevServer(opts: { configPath?: string; port?: number; ownerKey?: string; distDir?: string; jobsEveryMs?: number } = {}): Promise<DevServer> {
  const config = loadConfig(opts.configPath ?? join(root, "api", "_lib", "booking.config.json"));
  let ownerKey: string | null = opts.ownerKey ?? null;
  if (!ownerKey && !config.prototype?.ownerKeySha256) ownerKey = `dev_owner_${randomBytes(18).toString("base64url")}`;
  if (ownerKey) config.prototype = { ...(config.prototype ?? {}), ownerKeySha256: sha256Hex(ownerKey) };
  if (config.prototype?.provider === "hqpro") {
    console.error("The dev server always uses the sandbox providers; prototype.provider hqpro is ignored here.");
  }
  config.prototype = { ...(config.prototype ?? {}), provider: "sandbox" };

  const app = createBookingApp(buildServices({ config, store: new MemoryStore(), allowLocalWebhooks: true, env: process.env as Record<string, string> }));
  const distDir = resolve(opts.distDir ?? join(root, "dist"));
  let origin = "http://127.0.0.1";
  const server: Server = createServer((req, res) => {
    const path = (req.url ?? "/").split("?")[0] as string;
    if (path === "/api" || path.startsWith("/api/")) {
      toRequest(req, origin)
        .then((r) => app.handle(r))
        .then((r) => send(res, r))
        .catch(() => {
          res.writeHead(500, { "content-type": "application/json" });
          res.end(JSON.stringify({ error: { code: "internal", message: "Something went wrong on our side." } }));
        });
      return;
    }
    serveStatic(res, distDir, path);
  });
  await new Promise<void>((ok) => server.listen(opts.port ?? 0, "127.0.0.1", ok));
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;
  origin = `http://127.0.0.1:${port}`;
  const timer = setInterval(() => {
    runJobs(app.services).catch((e) => console.error(`jobs failed: ${(e as Error).message}`));
  }, opts.jobsEveryMs ?? 30_000);
  timer.unref();
  return {
    url: origin,
    ownerKey,
    app,
    close: () =>
      new Promise((ok) => {
        clearInterval(timer);
        server.close(() => ok());
      }),
  };
}

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : undefined;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(arg("port") ?? process.env.PORT ?? 5180);
  startDevServer({ configPath: arg("config") ?? process.env.BOOKING_CONFIG, port, ownerKey: process.env.OWNER_KEY })
    .then((s) => {
      console.log(`HQ Booking dev server (sandbox, in-memory) at ${s.url}`);
      if (s.ownerKey && !process.env.OWNER_KEY) console.log(`Owner key for this run: ${s.ownerKey}`);
    })
    .catch((e) => {
      console.error((e as Error).message);
      process.exit(1);
    });
}
