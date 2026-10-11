#!/usr/bin/env node
// drive.mjs: read-only Google Drive for the Agency Guide, signed in through
// Google's own gcloud CLI (`gcloud auth login --enable-gdrive-access`). The
// sign-in stays on this Mac; every call mints a fresh access token from it, so
// nothing expires mid-setup and no token is stored by this script.
//
// Read-only by construction: this script only ever sends GET requests to the
// Drive API. It has no command that creates, changes, shares or deletes.
//
// Usage (prints one JSON object):
//   node drive.mjs status
//   node drive.mjs connect            start the Google sign-in (opens the browser), return at once
//   node drive.mjs recent [--limit N]
//   node drive.mjs search <terms...> [--limit N]
//   node drive.mjs read <fileId> [--max-chars N]
//
// Exit codes: 0 ok, 1 usage error, 2 not connected or a Drive error (see "error").

import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync, openSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const DRIVE = "https://www.googleapis.com/drive/v3";
const STATE_DIR = join(homedir(), ".hq", "google-drive");
const STATE_FILE = join(STATE_DIR, "state.json");
const LOGIN_LOG = join(STATE_DIR, "login.log");
const SDK_DIR = join(homedir(), ".hq", "tools", "google-cloud-sdk");
const SDK_URL = {
  arm64: "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-darwin-arm.tar.gz",
  x64: "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-darwin-x86_64.tar.gz",
};
const EXPORT_AS = {
  "application/vnd.google-apps.document": "text/plain",
  "application/vnd.google-apps.spreadsheet": "text/csv",
  "application/vnd.google-apps.presentation": "text/plain",
};
const TEXT_TYPES = /^(text\/|application\/(json|csv|xml|markdown))/;

function out(obj, code = 0) {
  process.stdout.write(`${JSON.stringify(obj, null, 2)}\n`);
  process.exit(code);
}
function fail(error, extra = {}) {
  out({ ok: false, error, ...extra }, 2);
}

function readState() {
  try {
    return JSON.parse(readFileSync(STATE_FILE, "utf8"));
  } catch {
    return {};
  }
}
function writeState(state) {
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  writeFileSync(STATE_FILE, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
}

function findGcloud() {
  const candidates = [
    ...(process.env.PATH || "").split(":").map((d) => join(d, "gcloud")),
    "/opt/homebrew/bin/gcloud",
    "/usr/local/bin/gcloud",
    join(SDK_DIR, "bin", "gcloud"),
    join(homedir(), "google-cloud-sdk", "bin", "gcloud"),
  ];
  return candidates.find((p) => p && existsSync(p)) || null;
}

function installGcloud() {
  const url = process.arch === "arm64" ? SDK_URL.arm64 : SDK_URL.x64;
  mkdirSync(join(homedir(), ".hq", "tools"), { recursive: true });
  const tgz = join(homedir(), ".hq", "tools", "google-cloud-cli.tar.gz");
  execFileSync("curl", ["-fsSL", "-o", tgz, url], { stdio: "ignore", timeout: 600_000 });
  execFileSync("tar", ["-xzf", tgz, "-C", join(homedir(), ".hq", "tools")], { stdio: "ignore", timeout: 600_000 });
  execFileSync(join(SDK_DIR, "install.sh"), ["--quiet", "--usage-reporting=false", "--path-update=false", "--command-completion=false"], {
    stdio: "ignore",
    timeout: 600_000,
  });
  return join(SDK_DIR, "bin", "gcloud");
}

function gcloud(bin, args) {
  return execFileSync(bin, args, {
    encoding: "utf8",
    timeout: 60_000,
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, CLOUDSDK_CORE_DISABLE_PROMPTS: "1" },
  }).trim();
}

async function tokenScopes(token) {
  const res = await fetch(`https://oauth2.googleapis.com/tokeninfo?access_token=${encodeURIComponent(token)}`);
  if (!res.ok) return [];
  const data = await res.json();
  return String(data.scope || "").split(/\s+/).filter(Boolean);
}

/** The signed-in account with Drive access: the one recorded at connect, else the first that has it. */
async function driveAccount(bin) {
  const state = readState();
  let accounts = [];
  try {
    accounts = JSON.parse(gcloud(bin, ["auth", "list", "--format=json"])).map((a) => a.account);
  } catch {
    return null;
  }
  const ordered = state.account && accounts.includes(state.account) ? [state.account, ...accounts.filter((a) => a !== state.account)] : accounts;
  for (const account of ordered) {
    try {
      const token = gcloud(bin, ["auth", "print-access-token", `--account=${account}`]);
      const scopes = await tokenScopes(token);
      if (scopes.some((s) => s.endsWith("/auth/drive") || s.endsWith("/auth/drive.readonly"))) {
        if (state.account !== account) writeState({ ...state, account, connectedAt: state.connectedAt || new Date().toISOString() });
        return { account, token };
      }
    } catch {
      // not usable; try the next account
    }
  }
  return null;
}

async function requireDrive() {
  const bin = findGcloud();
  if (!bin) fail("not_connected", { next: "run: node drive.mjs connect" });
  const found = await driveAccount(bin);
  if (!found) fail("not_connected", { next: "run: node drive.mjs connect" });
  return found;
}

async function driveGet(token, path, params = {}) {
  const url = new URL(`${DRIVE}${path}`);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, String(v));
  const res = await fetch(url, { method: "GET", headers: { Authorization: `Bearer ${token}` } });
  if (!res.ok) {
    let message = `HTTP ${res.status}`;
    try {
      message = (await res.json()).error?.message || message;
    } catch {}
    fail("drive_error", { message });
  }
  return res;
}

function flag(args, name, fallback) {
  const i = args.indexOf(name);
  if (i === -1) return fallback;
  const v = Number(args[i + 1]);
  args.splice(i, 2);
  return Number.isFinite(v) && v > 0 ? v : fallback;
}

const FILE_FIELDS = "files(id,name,mimeType,modifiedTime,size,webViewLink,owners(displayName)),nextPageToken";

function shape(files) {
  return (files || []).map((f) => ({
    id: f.id,
    name: f.name,
    type: f.mimeType.replace("application/vnd.google-apps.", "google-"),
    modified: f.modifiedTime,
    link: f.webViewLink,
    owner: f.owners?.[0]?.displayName,
  }));
}

async function main() {
  const args = process.argv.slice(2);
  const cmd = args.shift();

  if (cmd === "status") {
    const bin = findGcloud();
    if (!bin) out({ ok: true, connected: false, gcloud: false });
    const found = await driveAccount(bin);
    out({ ok: true, connected: Boolean(found), gcloud: true, ...(found ? { account: found.account } : {}) });
  }

  if (cmd === "connect") {
    let bin = findGcloud();
    let installed = false;
    if (!bin) {
      try {
        bin = installGcloud();
        installed = true;
      } catch (err) {
        fail("gcloud_install_failed", { message: String(err.message || err).slice(0, 200) });
      }
    }
    mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
    const log = openSync(LOGIN_LOG, "w", 0o600);
    // Detached, so the sign-in keeps waiting for the browser after this command returns.
    const child = spawn(bin, ["auth", "login", "--enable-gdrive-access", "--brief", "--force"], {
      detached: true,
      stdio: ["ignore", log, log],
      env: { ...process.env, CLOUDSDK_CORE_DISABLE_PROMPTS: "1" },
    });
    child.unref();
    let url = "";
    for (let i = 0; i < 20 && !url; i += 1) {
      await new Promise((r) => setTimeout(r, 500));
      const m = readFileSync(LOGIN_LOG, "utf8").match(/https:\/\/accounts\.google\.com\/o\/oauth2\/auth\S+/);
      if (m) url = m[0];
    }
    out({
      ok: true,
      started: true,
      installedGcloud: installed,
      signInUrl: url || null,
      note: "A Google sign-in page opened in the browser. Sign in, allow access, then run: node drive.mjs status",
    });
  }

  if (cmd === "recent") {
    const limit = Math.min(flag(args, "--limit", 30), 100);
    const { token } = await requireDrive();
    const res = await driveGet(token, "/files", { pageSize: limit, orderBy: "modifiedTime desc", q: "trashed=false", fields: FILE_FIELDS });
    out({ ok: true, files: shape((await res.json()).files) });
  }

  if (cmd === "search") {
    const limit = Math.min(flag(args, "--limit", 20), 100);
    const terms = args.join(" ").split(/[,\s]+/).map((t) => t.trim()).filter(Boolean);
    if (!terms.length) out({ ok: false, error: "usage: search <terms...>" }, 1);
    const esc = (t) => t.replace(/\\/g, "\\\\").replace(/'/g, "\\'");
    const q = `trashed=false and (${terms.map((t) => `fullText contains '${esc(t)}' or name contains '${esc(t)}'`).join(" or ")})`;
    const { token } = await requireDrive();
    const res = await driveGet(token, "/files", { pageSize: limit, q, fields: FILE_FIELDS });
    out({ ok: true, terms, files: shape((await res.json()).files) });
  }

  if (cmd === "read") {
    const maxChars = Math.min(flag(args, "--max-chars", 40_000), 200_000);
    const id = args[0];
    if (!id || !/^[A-Za-z0-9_-]{10,}$/.test(id)) out({ ok: false, error: "usage: read <fileId>" }, 1);
    const { token } = await requireDrive();
    const meta = await (await driveGet(token, `/files/${id}`, { fields: "id,name,mimeType,modifiedTime,webViewLink" })).json();
    let text;
    if (EXPORT_AS[meta.mimeType]) {
      text = await (await driveGet(token, `/files/${id}/export`, { mimeType: EXPORT_AS[meta.mimeType] })).text();
    } else if (TEXT_TYPES.test(meta.mimeType)) {
      text = await (await driveGet(token, `/files/${id}`, { alt: "media" })).text();
    } else {
      out({ ok: true, id, name: meta.name, type: meta.mimeType, link: meta.webViewLink, text: null, note: "Not a Google Doc, Sheet, Slides or text file; open the link to read it." });
    }
    out({
      ok: true,
      id,
      name: meta.name,
      type: meta.mimeType.replace("application/vnd.google-apps.", "google-"),
      modified: meta.modifiedTime,
      link: meta.webViewLink,
      truncated: text.length > maxChars,
      text: text.slice(0, maxChars),
    });
  }

  out({ ok: false, error: "usage: drive.mjs status | connect | recent [--limit N] | search <terms...> [--limit N] | read <fileId> [--max-chars N]" }, 1);
}

main().catch((err) => fail("unexpected", { message: String(err?.message || err).slice(0, 300) }));
