// A stand-in for the hq-deploy control plane, for tests of `hq-booking.sh deploy`.
// Implements the app routes the deploy skill's helper scripts call and logs each
// request (one JSON line per request) so the test can check the sequence.
//
//   node fake-deploy-api.mjs <port-file> <log-file>
//
// Requests must carry `Authorization: Bearer test-jwt` and an X-Org-Slug header.
// A deploy to an app without a database answers 409 DATABASE_BILLING_ACK_REQUIRED.

import { createServer } from "node:http";
import { appendFileSync, writeFileSync } from "node:fs";

const [portFile, logFile] = process.argv.slice(2);
const apps = new Map();
let n = 0;

function send(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

const server = createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const raw = Buffer.concat(chunks);
    const text = raw.toString("latin1");
    const url = new URL(req.url, "http://x");
    const org = req.headers["x-org-slug"] ?? null;
    const entry = { method: req.method, path: url.pathname, org, auth: req.headers.authorization === "Bearer test-jwt" };
    const ct = String(req.headers["content-type"] ?? "");
    let body = null;
    if (ct.startsWith("application/json") && text) {
      try {
        body = JSON.parse(text);
      } catch {
        body = null;
      }
    }
    if (ct.startsWith("multipart/form-data")) {
      entry.form = {
        type: /name="type"\r\n\r\napp\r\n/.test(text),
        ack: /name="database_billing_acknowledged"\r\n\r\ntrue\r\n/.test(text),
        file: /name="file"; filename="upload.tar.gz"/.test(text),
        bytes: raw.length,
      };
    }
    if (body) entry.body = { ...body, ...(body.password ? { password: "(set)" } : {}) };
    appendFileSync(logFile, `${JSON.stringify(entry)}\n`);

    if (!entry.auth) return send(res, 401, { error: { code: "AUTH_FAILED", message: "bad token" } });
    if (!org) return send(res, 400, { error: { code: "ORG_REQUIRED", message: "X-Org-Slug missing" } });
    const parts = url.pathname.split("/").filter(Boolean); // api apps :id action
    if (parts[0] !== "api" || parts[1] !== "apps") return send(res, 404, { error: { code: "NOT_FOUND", message: "no route" } });
    const id = parts[2];
    const action = parts[3];
    if (!id) {
      if (req.method === "GET") return send(res, 200, { apps: [...apps.values()].filter((a) => a.org === org) });
      if (req.method === "POST") {
        if (!body?.name || body.type !== "app") return send(res, 400, { error: { code: "VALIDATION", message: "name and type app required" } });
        const app = { id: `app_${++n}`, name: body.name, type: body.type, subdomain: body.name, org, accessMode: "public", database: false };
        apps.set(app.id, app);
        return send(res, 201, app);
      }
    }
    const app = apps.get(id);
    if (!app || app.org !== org) return send(res, 404, { error: { code: "APP_NOT_FOUND", message: "no app" } });
    if (!action && req.method === "GET") return send(res, 200, app);
    if (!action && req.method === "PATCH") {
      if (body?.database === true) {
        if (body.databaseBillingAcknowledged !== true && org !== "indigo") return send(res, 409, { error: { code: "DATABASE_BILLING_ACK_REQUIRED", message: "terms" } });
        app.database = true;
        app.databaseBillingAcknowledgedAt = new Date().toISOString();
      }
      return send(res, 200, app);
    }
    if (action === "access-mode" && req.method === "POST") {
      if (!["public", "password", "private"].includes(body?.mode)) return send(res, 400, { error: { code: "VALIDATION", message: "mode" } });
      if (body.mode === "password" && !(typeof body.password === "string" && body.password.length >= 8)) return send(res, 400, { error: { code: "VALIDATION", message: "password" } });
      app.accessMode = body.mode;
      return send(res, 200, { ok: true, accessMode: app.accessMode });
    }
    if (action === "access-policy" && req.method === "PUT") {
      app.accessMode = body?.mode;
      return send(res, 200, { ok: true });
    }
    if (action === "deploy" && req.method === "POST") {
      if (!entry.form?.type || !entry.form.file) return send(res, 400, { error: { code: "VALIDATION", message: "type=app and file required" } });
      if (!app.database) return send(res, 409, { error: { code: "DATABASE_BILLING_ACK_REQUIRED", message: "terms" } });
      const deployId = `dep_${++n}`;
      return send(res, 202, { deployId, statusUrl: `/api/deploys/${deployId}` });
    }
    return send(res, 404, { error: { code: "NOT_FOUND", message: "no route" } });
  });
});

server.listen(0, "127.0.0.1", () => {
  writeFileSync(portFile, String(server.address().port));
});
