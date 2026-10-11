#!/usr/bin/env node
// slack.mjs: read-only Slack for the Agency Guide, using the person's own
// Slack sign-in from HQ's Personal Slack account connection. The token lives
// in their personal HQ vault (SLACK_PERSONAL/{team}/{user}/USER_TOKEN) and is
// read on every call; this script never stores or prints it.
//
// Read-only by construction: only the Slack methods in READ_METHODS can be
// called. Nothing here posts, edits, reacts, joins, invites or deletes.
//
// Usage (prints one JSON object):
//   node slack.mjs status
//   node slack.mjs connect-link
//   node slack.mjs channels [--limit N]
//   node slack.mjs search <query...> [--limit N]
//   node slack.mjs history <channelId> [--limit N]
//   node slack.mjs thread <channelId> <threadTs> [--limit N]
// Add --team <T…> to pick a workspace when the person connected more than one.
//
// Exit codes: 0 ok, 1 usage error, 2 not connected or a Slack error (see "error").

import { execFileSync } from "node:child_process";

const READ_METHODS = new Set([
  "auth.test",
  "conversations.list",
  "conversations.history",
  "conversations.replies",
  "search.messages",
  "users.info",
]);
const TOKEN_NAME = /^SLACK_PERSONAL\/(T[A-Z0-9]+)\/(U[A-Z0-9]+)\/USER_TOKEN$/;
const CONSOLE = process.env.HQ_CONSOLE_URL || "https://hq.computer";
const CONNECT_PATH = process.env.HQ_SLACK_CONNECT_PATH || "/personal/integrations?add=slack";

function out(obj, code = 0) {
  process.stdout.write(`${JSON.stringify(obj, null, 2)}\n`);
  process.exit(code);
}
function fail(error, extra = {}) {
  out({ ok: false, error, ...extra }, 2);
}

function hq(args) {
  return execFileSync("hq", args, {
    encoding: "utf8",
    timeout: 60_000,
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, HQ_NO_UPDATE_CHECK: "1" },
  });
}

/** Personal Slack connections in the person's vault: [{ name, team, user }]. */
function connections() {
  let listing = "";
  try {
    listing = hq(["secrets", "--personal", "list"]);
  } catch {
    return [];
  }
  const found = [];
  for (const line of listing.split("\n")) {
    const name = line.trim().split(/\s+/)[0] || "";
    const m = TOKEN_NAME.exec(name);
    if (m) found.push({ name, team: m[1], user: m[2] });
  }
  return found;
}

function tokenFor(conn) {
  const text = hq(["secrets", "--personal", "get", "--reveal", conn.name]);
  const line = text.split("\n").find((l) => /^\s*Value:/.test(l));
  const token = line ? line.replace(/^\s*Value:\s*/, "").trim() : "";
  if (!token.startsWith("xoxp-")) fail("not_connected", { next: "connect Slack: node slack.mjs connect-link" });
  return token;
}

function pick(args) {
  const i = args.indexOf("--team");
  const team = i === -1 ? null : args.splice(i, 2)[1];
  const all = connections();
  if (!all.length) fail("not_connected", { next: "connect Slack: node slack.mjs connect-link" });
  const conn = team ? all.find((c) => c.team === team) : all[0];
  if (!conn) fail("unknown_team", { teams: all.map((c) => c.team) });
  return { conn, teams: all.map((c) => c.team) };
}

function flag(args, name, fallback, max) {
  const i = args.indexOf(name);
  if (i === -1) return fallback;
  const v = Number(args[i + 1]);
  args.splice(i, 2);
  return Number.isFinite(v) && v > 0 ? Math.min(v, max) : fallback;
}

async function slack(token, method, params = {}) {
  if (!READ_METHODS.has(method)) fail("method_not_allowed", { method });
  const body = new URLSearchParams(Object.entries(params).map(([k, v]) => [k, String(v)]));
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const res = await fetch(`https://slack.com/api/${method}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/x-www-form-urlencoded" },
      body,
    });
    if (res.status === 429) {
      const wait = Math.min(Number(res.headers.get("retry-after") || "30"), 65);
      if (attempt === 0) {
        await new Promise((r) => setTimeout(r, wait * 1000));
        continue;
      }
      fail("rate_limited", { method, retryAfterSeconds: wait });
    }
    const data = await res.json();
    if (!data.ok) {
      if (data.error === "missing_scope") fail("missing_scope", { method, needed: data.needed, next: "reconnect Slack with search: node slack.mjs connect-link" });
      fail("slack_error", { method, message: data.error });
    }
    return data;
  }
  return null;
}

const msg = (m) => ({
  ts: m.ts,
  user: m.user || m.username,
  text: (m.text || "").slice(0, 2000),
  ...(m.thread_ts && m.reply_count ? { threadTs: m.thread_ts, replies: m.reply_count } : {}),
});

async function main() {
  const args = process.argv.slice(2);
  const cmd = args.shift();

  if (cmd === "connect-link") {
    out({ ok: true, url: `${CONSOLE}${CONNECT_PATH}`, note: "Open this, pick the company, and allow access in Slack. Then run: node slack.mjs status" });
  }

  if (cmd === "status") {
    const all = connections();
    if (!all.length) out({ ok: true, connected: false });
    const { conn, teams } = pick(args);
    const me = await slack(tokenFor(conn), "auth.test");
    out({ ok: true, connected: true, team: me.team, teamId: conn.team, user: me.user, teams });
  }

  if (cmd === "channels") {
    const limit = flag(args, "--limit", 200, 1000);
    const { conn } = pick(args);
    const data = await slack(tokenFor(conn), "conversations.list", {
      types: "public_channel,private_channel",
      exclude_archived: true,
      limit,
    });
    out({
      ok: true,
      channels: (data.channels || []).map((c) => ({ id: c.id, name: c.name, private: c.is_private, member: c.is_member, members: c.num_members, topic: c.topic?.value || undefined })),
    });
  }

  if (cmd === "search") {
    const limit = flag(args, "--limit", 20, 100);
    const { conn } = pick(args);
    const query = args.join(" ").trim();
    if (!query) out({ ok: false, error: "usage: search <query...>" }, 1);
    const data = await slack(tokenFor(conn), "search.messages", { query, count: limit, sort: "timestamp" });
    out({
      ok: true,
      query,
      total: data.messages?.total ?? 0,
      matches: (data.messages?.matches || []).map((m) => ({ channel: m.channel?.name, channelId: m.channel?.id, ...msg(m), link: m.permalink })),
    });
  }

  if (cmd === "history" || cmd === "thread") {
    const limit = flag(args, "--limit", 15, 200);
    const { conn } = pick(args);
    const channel = args[0];
    if (!channel || !/^[CGD][A-Z0-9]+$/.test(channel)) out({ ok: false, error: `usage: ${cmd} <channelId>${cmd === "thread" ? " <threadTs>" : ""}` }, 1);
    const token = tokenFor(conn);
    if (cmd === "history") {
      const data = await slack(token, "conversations.history", { channel, limit });
      out({ ok: true, channel, messages: (data.messages || []).map(msg), more: Boolean(data.has_more) });
    }
    const ts = args[1];
    if (!ts || !/^\d+\.\d+$/.test(ts)) out({ ok: false, error: "usage: thread <channelId> <threadTs>" }, 1);
    const data = await slack(token, "conversations.replies", { channel, ts, limit });
    out({ ok: true, channel, threadTs: ts, messages: (data.messages || []).map(msg), more: Boolean(data.has_more) });
  }

  out({ ok: false, error: "usage: slack.mjs status | connect-link | channels | search <query> | history <channelId> | thread <channelId> <threadTs> [--limit N] [--team T…]" }, 1);
}

main().catch((err) => fail("unexpected", { message: String(err?.message || err).slice(0, 300) }));
