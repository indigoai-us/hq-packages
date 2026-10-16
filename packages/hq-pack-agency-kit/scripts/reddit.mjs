#!/usr/bin/env node
// reddit.mjs: read-only Reddit for the Agency Guide's growth work (finding founders
// who ask for feedback on their site). Never posts, votes, messages or logs in as
// a person. Two routes, tried in this order:
//
//   1. Reddit's API with an app the agency registered (free, at
//      https://www.reddit.com/prefs/apps, type "web app" or "script"). The id and
//      secret live in the agency's HQ vault as REDDIT_CLIENT_ID and
//      REDDIT_CLIENT_SECRET; this script reads them with `hq secrets` on every
//      call and never prints them. App-only access (client credentials) can read
//      public posts and comments, which is all this needs.
//   2. Reddit's public feeds (search.rss, a post's .rss) with no login. They work
//      at low volume and are rate-limited (HTTP 429) after a burst, so results
//      are cached under ~/.hq/reddit-cache/ and the last good answer is returned
//      when Reddit refuses. Fine for a demo; the app route is dependable.
//
// Usage (prints one JSON object):
//   node reddit.mjs status [--company <slug>]
//   node reddit.mjs search <query...> [--sub SaaS,startups] [--days 30] [--limit 20] [--company <slug>]
//   node reddit.mjs post <url-or-id> [--limit 20] [--company <slug>]
//
// Exit codes: 0 ok, 1 usage error, 2 Reddit refused and nothing is cached.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";

const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36 hq-agency-kit/0.6 (read-only)";
const DEFAULT_SUBS = ["SaaS", "startups", "Entrepreneur", "webdev", "SideProject"];
const CACHE_DIR = join(homedir(), ".hq", "reddit-cache");

function out(obj, code = 0) {
  process.stdout.write(`${JSON.stringify(obj, null, 2)}\n`);
  process.exit(code);
}
function fail(error, extra = {}) {
  out({ ok: false, error, ...extra }, 2);
}
function flag(args, name, fallback) {
  const i = args.indexOf(name);
  if (i === -1) return fallback;
  const v = args[i + 1];
  args.splice(i, 2);
  return v ?? fallback;
}
function num(v, fallback, max) {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? Math.min(n, max) : fallback;
}

// ── HQ vault: optional app credentials ──────────────────────────────────────
function secret(name, company) {
  try {
    const args = ["secrets", ...(company ? ["--company", company] : []), "get", "--reveal", name];
    const text = execFileSync("hq", args, { encoding: "utf8", timeout: 60_000, stdio: ["ignore", "pipe", "ignore"], env: { ...process.env, HQ_NO_UPDATE_CHECK: "1" } });
    const line = text.split("\n").find((l) => /^\s*Value:/.test(l));
    return line ? line.replace(/^\s*Value:\s*/, "").trim() : "";
  } catch {
    return "";
  }
}

async function appToken(company) {
  const id = secret("REDDIT_CLIENT_ID", company);
  const key = secret("REDDIT_CLIENT_SECRET", company);
  if (!id || !key) return null;
  const res = await fetch("https://www.reddit.com/api/v1/access_token", {
    method: "POST",
    headers: {
      Authorization: `Basic ${Buffer.from(`${id}:${key}`).toString("base64")}`,
      "Content-Type": "application/x-www-form-urlencoded",
      "User-Agent": UA,
    },
    body: "grant_type=client_credentials",
  });
  if (!res.ok) return null;
  const data = await res.json();
  return data.access_token || null;
}


// Scan every cached search result for a post id (used when a post read is refused).
function findInSearchCache(id) {
  try {
    for (const f of readdirSync(CACHE_DIR)) {
      try {
        const data = JSON.parse(readFileSync(join(CACHE_DIR, f), "utf8"));
        if (Array.isArray(data.value)) {
          const hit = data.value.find((p) => p && p.id === id);
          if (hit) return { at: data.at, post: hit };
        }
      } catch { /* skip unreadable cache file */ }
    }
  } catch { /* no cache dir */ }
  return null;
}

// ── cache ────────────────────────────────────────────────────────────────────
function cachePath(key) {
  mkdirSync(CACHE_DIR, { recursive: true });
  return join(CACHE_DIR, `${createHash("sha1").update(key).digest("hex")}.json`);
}
function readCache(key) {
  const p = cachePath(key);
  if (!existsSync(p)) return null;
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch {
    return null;
  }
}
function writeCache(key, value) {
  writeFileSync(cachePath(key), JSON.stringify({ at: new Date().toISOString(), value }));
}

// ── fetch with one retry on 429 ──────────────────────────────────────────────
async function get(url, headers = {}) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const res = await fetch(url, { headers: { "User-Agent": UA, ...headers }, redirect: "follow" });
    if (res.status === 429 && attempt === 0) {
      await new Promise((r) => setTimeout(r, 6000));
      continue;
    }
    return res;
  }
  return null;
}

// ── normalizers ──────────────────────────────────────────────────────────────
const post = (d) => ({
  id: d.id,
  subreddit: d.subreddit,
  title: d.title,
  author: d.author,
  created: new Date(d.created_utc * 1000).toISOString(),
  score: d.score ?? d.ups,
  comments: d.num_comments,
  url: `https://www.reddit.com${d.permalink}`,
  // The site the founder is asking about, when the post links one.
  linkedUrl: d.url_overridden_by_dest && !/reddit\.com|redd\.it/.test(d.url_overridden_by_dest) ? d.url_overridden_by_dest : null,
  text: (d.selftext || "").slice(0, 3000),
});

function parseAtom(xml) {
  const entries = [];
  const re = /<entry>([\s\S]*?)<\/entry>/g;
  let m;
  const pick = (block, tag) => {
    const mm = block.match(new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`));
    return mm ? mm[1] : "";
  };
  const unescape = (s) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&#32;/g, " ");
  while ((m = re.exec(xml))) {
    const b = m[1];
    const link = (b.match(/<link[^>]*href="([^"]+)"/) || [])[1] || "";
    const author = (pick(b, "author").match(/<name>([^<]*)<\/name>/) || [])[1] || "";
    const html = unescape(pick(b, "content"));
    const text = html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
    const linked = (html.match(/href="(https?:\/\/(?!(?:www\.)?reddit\.com|redd\.it)[^"]+)"/) || [])[1] || null;
    entries.push({
      id: (link.match(/comments\/([a-z0-9]+)\//) || [])[1] || "",
      subreddit: (link.match(/\/r\/([^/]+)\//) || [])[1] || "",
      title: unescape(pick(b, "title")),
      author: author.replace(/^\/u\//, ""),
      created: pick(b, "updated"),
      score: null,
      comments: null,
      url: link,
      linkedUrl: linked,
      text: text.slice(0, 3000),
    });
  }
  return entries;
}

// ── commands ─────────────────────────────────────────────────────────────────
async function main() {
  const args = process.argv.slice(2);
  const cmd = args.shift();
  const company = flag(args, "--company", null);

  if (cmd === "status") {
    const token = await appToken(company).catch(() => null);
    out({ ok: true, route: token ? "app" : "public", note: token ? "Reddit app credentials found in the HQ vault; reads use Reddit's API." : "No Reddit app credentials in the HQ vault; reads use Reddit's public feeds, which rate-limit after a burst. To make this dependable, register a free app at reddit.com/prefs/apps and add REDDIT_CLIENT_ID and REDDIT_CLIENT_SECRET to the agency's vault." });
  }

  if (cmd === "search") {
    const subs = flag(args, "--sub", DEFAULT_SUBS.join(",")).split(",").map((s) => s.trim()).filter(Boolean);
    const days = num(flag(args, "--days", "30"), 30, 365);
    const limit = num(flag(args, "--limit", "20"), 20, 100);
    const query = args.join(" ").trim();
    if (!query) out({ ok: false, error: "usage: search <query...> [--sub a,b] [--days N] [--limit N]" }, 1);
    const key = `search:${subs.join(",")}:${query}:${days}`;
    const since = Date.now() - days * 86_400_000;
    const token = await appToken(company).catch(() => null);
    let posts = [];
    let route = token ? "app" : "public";
    let refused = false;
    for (const sub of subs) {
      try {
        if (token) {
          const url = `https://oauth.reddit.com/r/${encodeURIComponent(sub)}/search?q=${encodeURIComponent(query)}&restrict_sr=1&sort=new&limit=${limit}&t=${days <= 7 ? "week" : days <= 31 ? "month" : "year"}`;
          const res = await get(url, { Authorization: `Bearer ${token}` });
          if (!res || !res.ok) { refused = true; continue; }
          const data = await res.json();
          posts.push(...(data.data?.children || []).map((c) => post(c.data)));
        } else {
          const url = `https://www.reddit.com/r/${encodeURIComponent(sub)}/search.rss?q=${encodeURIComponent(query)}&restrict_sr=1&sort=new`;
          const res = await get(url);
          if (!res || !res.ok) { refused = true; continue; }
          posts.push(...parseAtom(await res.text()));
        }
      } catch {
        refused = true;
      }
    }
    posts = posts.filter((p) => !p.created || Date.parse(p.created) >= since);
    posts.sort((a, b) => Date.parse(b.created || 0) - Date.parse(a.created || 0));
    posts = posts.slice(0, limit);
    if (posts.length) {
      writeCache(key, posts);
      out({ ok: true, route, query, subreddits: subs, days, total: posts.length, partial: refused, posts });
    }
    const cached = readCache(key);
    if (cached) out({ ok: true, route: "cache", cachedAt: cached.at, query, subreddits: subs, days, total: cached.value.length, note: "Reddit refused this run; these are the last results it gave for the same search.", posts: cached.value });
    fail("reddit_refused", { note: "Reddit rate-limited or blocked these reads and nothing is cached yet. Try again in a few minutes, or add Reddit app credentials (see: node reddit.mjs status)." });
  }

  if (cmd === "post") {
    const limit = num(flag(args, "--limit", "20"), 20, 100);
    const ref = args[0] || "";
    const id = (ref.match(/comments\/([a-z0-9]+)/) || [null, /^[a-z0-9]{5,8}$/.test(ref) ? ref : null])[1];
    if (!id) out({ ok: false, error: "usage: post <reddit post url or id>" }, 1);
    const key = `post:${id}`;
    const token = await appToken(company).catch(() => null);
    try {
      if (token) {
        const res = await get(`https://oauth.reddit.com/comments/${id}?limit=${limit}&depth=1`, { Authorization: `Bearer ${token}` });
        if (res && res.ok) {
          const [p, c] = await res.json();
          const value = {
            post: post(p.data.children[0].data),
            comments: (c.data.children || []).filter((x) => x.kind === "t1").map((x) => ({ author: x.data.author, score: x.data.score, text: (x.data.body || "").slice(0, 2000) })),
          };
          writeCache(key, value);
          out({ ok: true, route: "app", ...value });
        }
      } else {
        const res = await get(`https://www.reddit.com/comments/${id}/.rss?limit=${limit}`);
        if (res && res.ok) {
          const entries = parseAtom(await res.text());
          const value = { post: entries[0] || null, comments: entries.slice(1).map((e) => ({ author: e.author, score: null, text: e.text.slice(0, 2000) })) };
          if (value.post) {
            writeCache(key, value);
            out({ ok: true, route: "public", ...value });
          }
        }
      }
    } catch {
      /* fall through to cache */
    }
    const cached = readCache(key);
    if (cached) out({ ok: true, route: "cache", cachedAt: cached.at, ...cached.value });
    // Last resort: a search run already saw this post (the search feed carries
    // the post text and its linked site), so answer from that entry.
    const fromSearch = findInSearchCache(id);
    if (fromSearch) out({ ok: true, route: "search-cache", cachedAt: fromSearch.at, post: fromSearch.post, comments: [], note: "Reddit refused the post read; this is the post as the search feed returned it. Comments are not included." });
    fail("reddit_refused", { note: "Reddit rate-limited or blocked this read and it is not cached. Try again in a few minutes." });
  }

  out({ ok: false, error: "usage: reddit.mjs status | search <query...> [--sub a,b] [--days N] [--limit N] | post <url> [--limit N]" }, 1);
}

main().catch((err) => fail("unexpected", { message: String(err?.message || err).slice(0, 300) }));
