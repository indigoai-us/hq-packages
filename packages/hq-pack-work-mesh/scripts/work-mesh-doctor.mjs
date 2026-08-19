/**
 * Local mesh doctor — align HQ project dirs with the work mesh and warm
 * ~/.hq/work-mesh/cache without a doorbell storm.
 *
 * Mesh is source of truth. Local prd.json may add missing stories / fill empty
 * metadata. It must never downgrade a live Board status.
 * Mutations (PUT / ensure-project) are serialized and paced.
 */
import fs from "node:fs";
import path from "node:path";

const STORY_STATUSES = new Set(["queued", "in_progress", "review", "done"]);
const SKIP_DIR_NAMES = new Set(["_template", "_overrides"]);
const SKIP_FILE_NAMES = new Set(["fabric-genesis.json", ".ds_store", "thumbs.db"]);
const ARTIFACT_EXT = new Set([".md", ".markdown", ".txt", ".json", ".yaml", ".yml", ".csv", ".html"]);
const MAX_PROJECT_FILES = 80;

export function readCloudCompanyUid(yamlText) {
  if (typeof yamlText !== "string") return "";
  for (const line of yamlText.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed.startsWith("#") || !trimmed.startsWith("cloudCompanyUid:")) continue;
    const uid = trimmed.slice("cloudCompanyUid:".length).trim().replace(/^['"]|['"]$/g, "");
    return uid.startsWith("cmp_") ? uid : "";
  }
  return "";
}

export function listCloudCompanies(hqRoot) {
  const companiesDir = path.join(hqRoot, "companies");
  if (!fs.existsSync(companiesDir)) return [];
  const out = [];
  for (const ent of fs.readdirSync(companiesDir, { withFileTypes: true })) {
    if (!ent.isDirectory() || ent.name.startsWith(".") || ent.name.startsWith("_")) continue;
    const yamlPath = path.join(companiesDir, ent.name, "company.yaml");
    if (!fs.existsSync(yamlPath)) continue;
    const companyUid = readCloudCompanyUid(fs.readFileSync(yamlPath, "utf8"));
    if (!companyUid) continue;
    out.push({
      slug: ent.name,
      companyUid,
      projectsDir: path.join(companiesDir, ent.name, "projects"),
    });
  }
  return out.sort((a, b) => a.slug.localeCompare(b.slug));
}

export function listProjectArtifactFiles(dir, projectId) {
  const files = [];
  const walk = (abs, rel) => {
    if (files.length >= MAX_PROJECT_FILES) return;
    let entries = [];
    try {
      entries = fs.readdirSync(abs, { withFileTypes: true });
    } catch {
      return;
    }
    for (const ent of entries) {
      if (files.length >= MAX_PROJECT_FILES) return;
      if (ent.name.startsWith(".")) continue;
      const nextRel = rel ? `${rel}/${ent.name}` : ent.name;
      const nextAbs = path.join(abs, ent.name);
      if (ent.isDirectory()) {
        if (SKIP_DIR_NAMES.has(ent.name) || ent.name === "node_modules") continue;
        walk(nextAbs, nextRel);
        continue;
      }
      if (!ent.isFile()) continue;
      if (SKIP_FILE_NAMES.has(ent.name.toLowerCase())) continue;
      const ext = path.extname(ent.name).toLowerCase();
      if (!ARTIFACT_EXT.has(ext)) continue;
      let updatedAt = "";
      try {
        updatedAt = fs.statSync(nextAbs).mtime.toISOString();
      } catch {
        updatedAt = "";
      }
      files.push({
        path: `projects/${projectId}/${nextRel}`,
        name: ent.name,
        updatedAt,
      });
    }
  };
  walk(dir, "");
  return files.sort((a, b) => a.path.localeCompare(b.path));
}

function isProjectDir(ent, opts) {
  if (!ent.isDirectory()) return false;
  if (ent.name.startsWith(".")) return false;
  if (SKIP_DIR_NAMES.has(ent.name)) return false;
  if (ent.name === "_archive" && !opts.includeArchived) return false;
  if (ent.name.startsWith("_") && ent.name !== "_archive") return false;
  return true;
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

export function projectViewFromPrd(prd, companyUid, projectId) {
  const meta = (prd && typeof prd === "object" && prd.metadata) || {};
  const stories = [];
  for (const raw of asArray(prd?.userStories)) {
    if (!raw || typeof raw !== "object" || !raw.id) continue;
    const ac = [];
    for (const item of asArray(raw.acceptanceCriteria)) {
      if (typeof item === "string" && item.trim()) ac.push(item.trim());
      else if (item && typeof item === "object" && String(item.text || "").trim()) {
        ac.push(String(item.text).trim());
      }
    }
    const passes = raw.passes === true;
    const status = STORY_STATUSES.has(raw.status) ? raw.status : (passes ? "done" : "queued");
    stories.push({
      id: String(raw.id).trim(),
      title: String(raw.title || "").trim(),
      description: String(raw.description || "").trim(),
      acceptanceCriteria: ac,
      status,
      passes: status === "done",
      priority: typeof raw.priority === "number" ? raw.priority : null,
    });
  }
  const repos = [];
  const repoSrc = asArray(prd?.repos).length > 0 ? prd.repos : asArray(meta.repos);
  for (const raw of asArray(repoSrc)) {
    if (!raw || typeof raw !== "object") continue;
    const repoPath = String(raw.path || raw.repoPath || raw.repo || "").trim();
    if (!repoPath) continue;
    repos.push({
      path: repoPath,
      branch: String(raw.branch || raw.branchName || "").trim(),
    });
  }
  if (repos.length === 0) {
    const repoPath = String(meta.repoPath || prd?.repoPath || "").trim();
    if (repoPath) {
      repos.push({
        path: repoPath,
        branch: String(prd?.branchName || meta.branchName || "").trim(),
      });
    }
  }
  return {
    companyUid,
    projectId,
    name: String(prd?.name || projectId).trim() || projectId,
    description: String(prd?.description || "").trim(),
    stories,
    repos,
    files: [],
  };
}

export function newestProjectActivityAt(args) {
  const { dir, prd, genesisAt, nowMs = Date.now() } = args;
  const stamps = [];
  const push = (value) => {
    if (typeof value === "number" && Number.isFinite(value)) {
      if (value > nowMs + 60_000) return;
      stamps.push(new Date(value).toISOString());
      return;
    }
    if (typeof value !== "string" || !value.trim()) return;
    const ms = Date.parse(value);
    if (!Number.isFinite(ms) || ms > nowMs + 60_000) return;
    stamps.push(new Date(ms).toISOString());
  };
  const meta = (prd && typeof prd === "object" && prd.metadata) || {};
  push(prd?.createdAt);
  push(prd?.updatedAt);
  push(meta.createdAt);
  push(meta.updatedAt);
  push(meta.created);
  push(genesisAt);
  if (dir) {
    for (const name of ["prd.json", "README.md", "fabric-genesis.json"]) {
      try {
        push(fs.statSync(path.join(dir, name)).mtimeMs);
      } catch {
        // missing
      }
    }
  }
  stamps.sort();
  return stamps[stamps.length - 1] || "";
}

export function stubProjectView(companyUid, projectId) {
  return {
    companyUid,
    projectId,
    name: projectId,
    description: "",
    stories: [],
    repos: [],
    files: [],
  };
}

function storyKey(story) {
  return String(story?.id || "").trim().toUpperCase();
}

function fillEmpty(remoteVal, localVal) {
  const remote = String(remoteVal || "").trim();
  if (remote) return remote;
  return String(localVal || "").trim();
}

export function mergeProjectView(remote, localDesired) {
  if (!remote) return localDesired;
  const remoteStories = Array.isArray(remote.stories) ? remote.stories : [];
  const byId = new Map(remoteStories.map((row) => [storyKey(row), row]));
  const stories = remoteStories.map((row) => {
    const local = (localDesired.stories || []).find((s) => storyKey(s) === storyKey(row));
    if (!local) return row;
    const ac = Array.isArray(row.acceptanceCriteria) && row.acceptanceCriteria.length > 0
      ? row.acceptanceCriteria
      : (local.acceptanceCriteria || []);
    return {
      ...row,
      title: fillEmpty(row.title, local.title),
      description: fillEmpty(row.description, local.description),
      acceptanceCriteria: ac,
    };
  });
  for (const local of localDesired.stories || []) {
    if (!byId.has(storyKey(local))) {
      stories.push(local);
      byId.set(storyKey(local), local);
    }
  }
  const remoteRepos = Array.isArray(remote.repos) ? remote.repos : [];
  const repoKeys = new Set(remoteRepos.map((r) => `${r.path}::${r.branch || ""}`));
  const repos = [...remoteRepos];
  for (const repo of localDesired.repos || []) {
    const key = `${repo.path}::${repo.branch || ""}`;
    if (!repoKeys.has(key)) {
      repos.push(repo);
      repoKeys.add(key);
    }
  }
  const localFiles = Array.isArray(localDesired.files) ? localDesired.files : [];
  const remoteFiles = Array.isArray(remote.files) ? remote.files : [];
  const fileKeys = new Set(remoteFiles.map((f) => String(f.path || "").trim()));
  const files = [...remoteFiles];
  for (const file of localFiles) {
    const key = String(file.path || "").trim();
    if (!key || fileKeys.has(key)) continue;
    files.push(file);
    fileKeys.add(key);
  }
  return {
    companyUid: remote.companyUid || localDesired.companyUid,
    projectId: remote.projectId || localDesired.projectId,
    name: fillEmpty(remote.name, localDesired.name) || localDesired.projectId,
    description: fillEmpty(remote.description, localDesired.description),
    stories,
    repos: remoteRepos.length > 0 ? repos : (localDesired.repos || []),
    files: localFiles.length > 0 ? localFiles : files,
  };
}

function canonStories(stories) {
  return (stories || [])
    .map((s) => ({
      id: String(s.id || "").trim(),
      title: String(s.title || "").trim(),
      description: String(s.description || "").trim(),
      acceptanceCriteria: Array.isArray(s.acceptanceCriteria) ? s.acceptanceCriteria : [],
      status: STORY_STATUSES.has(s.status) ? s.status : "queued",
    }))
    .sort((a, b) => a.id.localeCompare(b.id));
}

function canonRepos(repos) {
  return (repos || [])
    .map((r) => ({ path: String(r.path || "").trim(), branch: String(r.branch || "").trim() }))
    .filter((r) => r.path)
    .sort((a, b) => `${a.path}\0${a.branch}`.localeCompare(`${b.path}\0${b.branch}`));
}

export function meshViewNeedsPut(remote, merged) {
  if (!remote) return true;
  if (fillEmpty(remote.name, "") !== fillEmpty(merged.name, "")) return true;
  if (fillEmpty(remote.description, "") !== fillEmpty(merged.description, "")) return true;
  if (JSON.stringify(canonStories(remote.stories)) !== JSON.stringify(canonStories(merged.stories))) {
    return true;
  }
  if (JSON.stringify(canonRepos(remote.repos)) !== JSON.stringify(canonRepos(merged.repos))) {
    return true;
  }
  if (JSON.stringify(canonFiles(remote.files)) !== JSON.stringify(canonFiles(merged.files))) {
    return true;
  }
  return false;
}

function canonFiles(files) {
  return (files || [])
    .map((f) => ({ path: String(f.path || "").trim(), name: String(f.name || "").trim() }))
    .filter((f) => f.path)
    .sort((a, b) => a.path.localeCompare(b.path));
}

export function discoverLocalProjects(hqRoot, opts = {}) {
  const wantedCompany = String(opts.company || "").trim();
  const wantedProject = String(opts.project || "").trim();
  const companies = listCloudCompanies(hqRoot).filter((co) => {
    if (!wantedCompany) return true;
    return co.slug === wantedCompany || co.companyUid === wantedCompany;
  });
  const projects = [];
  for (const co of companies) {
    if (!fs.existsSync(co.projectsDir)) continue;
    for (const ent of fs.readdirSync(co.projectsDir, { withFileTypes: true })) {
      if (!isProjectDir(ent, opts)) continue;
      if (wantedProject && ent.name !== wantedProject) continue;
      const dir = path.join(co.projectsDir, ent.name);
      const prdPath = path.join(dir, "prd.json");
      const hasPrd = fs.existsSync(prdPath);
      if (!hasPrd && !opts.all) continue;
      let prd = null;
      if (hasPrd) {
        try {
          prd = JSON.parse(fs.readFileSync(prdPath, "utf8"));
        } catch {
          prd = null;
        }
      }
      let localDesired;
      try {
        localDesired = prd
          ? projectViewFromPrd(prd, co.companyUid, ent.name)
          : stubProjectView(co.companyUid, ent.name);
      } catch {
        localDesired = stubProjectView(co.companyUid, ent.name);
      }
      const genesisPath = path.join(dir, "fabric-genesis.json");
      let genesisAt = "";
      if (fs.existsSync(genesisPath)) {
        try {
          const genesis = JSON.parse(fs.readFileSync(genesisPath, "utf8"));
          genesisAt = typeof genesis.at === "string" ? genesis.at : "";
        } catch {
          genesisAt = "";
        }
      }
      const files = listProjectArtifactFiles(dir, ent.name);
      localDesired.files = files;
      projects.push({
        slug: co.slug,
        companyUid: co.companyUid,
        projectId: ent.name,
        hasPrd,
        dir,
        localDesired,
        activityAt: newestProjectActivityAt({ dir, prd, genesisAt }),
      });
    }
  }
  return { companies, projects };
}

export function createPacer({ paceMs, jitterMs, random = Math.random, sleep, now = Date.now } = {}) {
  const pace = Math.max(0, Number(paceMs) || 0);
  const jitter = Math.max(0, Number(jitterMs) || 0);
  let last = 0;
  let started = false;
  return async function waitTurn() {
    if (pace <= 0) {
      last = now();
      started = true;
      return 0;
    }
    const extra = jitter > 0 ? Math.floor(random() * (jitter + 1)) : 0;
    const wait = !started ? 0 : Math.max(0, pace + extra - Math.max(0, now() - last));
    if (wait > 0 && sleep) await sleep(wait);
    last = now();
    started = true;
    return wait;
  };
}

export async function mapPool(items, concurrency, fn) {
  const n = Math.max(1, Number(concurrency) || 1);
  const ret = new Array(items.length);
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const idx = next;
      next += 1;
      ret[idx] = await fn(items[idx], idx);
    }
  }
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, () => worker()));
  return ret;
}

function classifyRow(project, remote, merged, cacheHit) {
  const missing = !remote;
  const stale = !missing && meshViewNeedsPut(remote, merged);
  const cache = cacheHit ? "warm" : "cold";
  let mesh = "ok";
  if (missing) mesh = "missing";
  else if (stale) mesh = "stale";
  const actions = [];
  if (missing) actions.push("put", "channel");
  else if (stale) actions.push("put");
  if (!cacheHit) actions.push("cache");
  return { mesh, cache, actions, missing, stale };
}

export async function runDoctor(opts, io) {
  const apply = Boolean(opts.apply) && !opts.cacheOnly && !opts.dryRun;
  const ensureAllChannels = Boolean(opts.channels);
  const limit = Number(opts.limit) > 0 ? Number(opts.limit) : Infinity;
  const discovered = opts.projects || [];
  const slice = discovered.slice(0, Number.isFinite(limit) ? limit : discovered.length);
  const pace = createPacer({
    paceMs: opts.paceMs ?? 2500,
    jitterMs: opts.jitterMs ?? 500,
    random: io.random,
    sleep: io.sleep,
    now: io.now,
  });

  let examinedCount = 0;
  const examined = await mapPool(slice, opts.concurrency ?? 2, async (project) => {
    let remote = null;
    let error = "";
    try {
      remote = await io.getProjectView(project.companyUid, project.projectId);
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
    }
    const merged = mergeProjectView(remote, project.localDesired);
    const cached = io.readCache ? io.readCache(project.companyUid, project.projectId) : null;
    const cacheHit = Boolean(cached && cached.projectId === project.projectId);
    const row = classifyRow(project, remote, merged, cacheHit);
    if (ensureAllChannels && !row.actions.includes("channel")) row.actions.push("channel");
    if (opts.cacheOnly) {
      row.actions = row.actions.filter((a) => a === "cache");
      if (!cacheHit) row.actions.push("cache");
    }
    if (typeof io.onProgress === "function") {
      examinedCount += 1;
      io.onProgress({
        phase: "projects",
        current: examinedCount,
        total: slice.length,
        label: project.projectId,
      });
    }
    return { project, remote, merged, error, ...row };
  });

  const mutations = [];
  const results = [];
  for (const row of examined) {
    const applied = [];
    if (!row.error && row.remote && io.writeCache) {
      try {
        if (io.writeCache(row.remote)) applied.push("cache");
      } catch (err) {
        row.error = err instanceof Error ? err.message : String(err);
      }
    }
    const needPut = apply && !row.error && row.actions.includes("put");
    const needChannel = apply && !row.error && row.actions.includes("channel");
    if (needPut || needChannel) mutations.push({ row, needPut, needChannel, applied });
    else results.push({ ...summarize(row), applied });
  }

  for (const item of mutations) {
    const waited = await pace();
    try {
      if (item.needChannel && io.ensureProject) {
        await io.ensureProject(item.row.project.companyUid, item.row.project.projectId);
        item.applied.push("channel");
      }
      if (item.needPut && io.putProjectView) {
        if (item.needChannel && item.needPut) await pace();
        const stored = await io.putProjectView(
          item.row.project.companyUid,
          item.row.project.projectId,
          {
            ...item.row.merged,
            ...(item.row.project.activityAt
              ? { lastActivityAt: item.row.project.activityAt }
              : {}),
          },
        );
        item.applied.push("put");
        if (stored && io.writeCache) {
          io.writeCache(stored);
          if (!item.applied.includes("cache")) item.applied.push("cache");
        }
      }
    } catch (err) {
      item.row.error = err instanceof Error ? err.message : String(err);
    }
    item.row.pacedMs = waited;
    results.push({ ...summarize(item.row), applied: item.applied });
  }

  const summary = {
    ok: true,
    action: "doctor",
    apply,
    cacheOnly: Boolean(opts.cacheOnly),
    scanned: examined.length,
    discovered: discovered.length,
    limited: Number.isFinite(limit) && discovered.length > limit,
    missing: results.filter((r) => r.mesh === "missing").length,
    stale: results.filter((r) => r.mesh === "stale").length,
    okCount: results.filter((r) => r.mesh === "ok" && !r.error).length,
    cacheWarmed: results.filter((r) => r.applied.includes("cache")).length,
    puts: results.filter((r) => r.applied.includes("put")).length,
    channels: results.filter((r) => r.applied.includes("channel")).length,
    errors: results.filter((r) => r.error).length,
    paceMs: opts.paceMs ?? 2500,
    projects: results,
  };
  return summary;
}

function summarize(row) {
  return {
    company: row.project.slug,
    companyUid: row.project.companyUid,
    projectId: row.project.projectId,
    hasPrd: row.project.hasPrd,
    mesh: row.mesh,
    cache: row.cache,
    planned: row.actions,
    error: row.error || "",
  };
}

function isPersonUid(value) {
  return /^(prs|agt)_[A-Za-z0-9]+$/.test(String(value || "").trim());
}

/** Pair-DM partners from inbox events + unread rollup — not channel directory. */
const MAX_REACTION_MESSAGES = 30;

function messageListFromPayload(data) {
  if (Array.isArray(data?.messages)) return data.messages;
  if (Array.isArray(data)) return data;
  return [];
}

function eventIdFromMessage(row) {
  return String(row?.eventId || row?.id || "").trim();
}

function reactionsFromPayload(raw) {
  const list = Array.isArray(raw)
    ? raw
    : raw && typeof raw === "object" && Array.isArray(raw.reactions)
      ? raw.reactions
      : [];
  const out = [];
  for (const item of list) {
    const emoji = typeof item?.emoji === "string" ? item.emoji.trim() : "";
    if (!emoji) continue;
    out.push({
      emoji,
      count: typeof item.count === "number" ? item.count : 0,
      reactedByMe: Boolean(item.reactedByMe ?? item.reacted_by_me),
    });
  }
  return out;
}

/** Attach GET /v1/notify/reactions aggregates onto a thread/channel payload. */
export async function attachReactionsToPayload(data, messageScope, getReactions) {
  if (typeof getReactions !== "function" || !messageScope || data == null) return data;
  const messages = messageListFromPayload(data);
  const ids = [];
  const seen = new Set();
  for (const row of messages) {
    const id = eventIdFromMessage(row);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    ids.push(id);
    if (ids.length >= MAX_REACTION_MESSAGES) break;
  }
  if (ids.length === 0) return data;
  const byId = new Map();
  await mapPool(ids, 8, async (id) => {
    try {
      const payload = await getReactions(messageScope, id);
      const list = reactionsFromPayload(payload);
      if (list.length > 0) byId.set(id, list);
    } catch {
      // one message must not fail the window
    }
  });
  if (byId.size === 0) return data;
  const nextMessages = messages.map((row) => {
    const id = eventIdFromMessage(row);
    if (!id || !byId.has(id)) return row;
    return { ...row, reactions: byId.get(id) };
  });
  if (Array.isArray(data?.messages)) return { ...data, messages: nextMessages };
  if (Array.isArray(data)) return nextMessages;
  return data;
}

export function pairDmUidsFromInbox(inbox) {
  const ids = new Set();
  const events = Array.isArray(inbox?.events) ? inbox.events : [];
  for (const event of events) {
    const uid = String(event?.fromPersonUid || "").trim();
    if (isPersonUid(uid)) ids.add(uid);
  }
  const pairs = Array.isArray(inbox?.pairUnreads) ? inbox.pairUnreads : [];
  for (const row of pairs) {
    const uid = String(row?.withPersonUid || "").trim();
    if (isPersonUid(uid)) ids.add(uid);
  }
  return [...ids].sort();
}

export async function warmConversationCache(opts, io) {
  const feed = await io.getDirectory();
  const principalUid = String(opts.principalUid || "").trim();
  const written = {
    directory: false,
    channels: 0,
    inbox: false,
    contacts: false,
    threads: 0,
  };
  if (feed && principalUid && io.writeDirectory) {
    io.writeDirectory(principalUid, feed);
    written.directory = true;
  }
  const rows = Array.isArray(feed?.channels)
    ? feed.channels
    : Array.isArray(feed?.rows)
      ? feed.rows
      : [];
  const pace = createPacer({
    paceMs: opts.paceMs ?? 400,
    jitterMs: opts.jitterMs ?? 100,
    random: io.random,
    sleep: io.sleep,
    now: io.now,
  });
  const warmable = rows.filter((row) => {
    const type = row?.type;
    const channelId = String(row?.channelId || "").trim();
    if (!channelId) return false;
    return type === "dm" || type === "chat" || type === "project" || type === "channel";
  });
  let index = 0;
  for (const row of warmable) {
    const channelId = String(row.channelId || "").trim();
    index += 1;
    if (typeof io.onProgress === "function") {
      io.onProgress({
        phase: "chats",
        current: index,
        total: warmable.length,
        label: channelId,
      });
    }
    await pace();
    try {
      const messages = await io.getChannelMessages(channelId);
      if (messages && io.writeChannelMessages) {
        const enriched = await attachReactionsToPayload(
          messages,
          `chan:${channelId}`,
          io.getReactions,
        );
        io.writeChannelMessages(channelId, enriched);
        written.channels += 1;
      }
    } catch {
      // one channel must not fail the rest
    }
  }

  // 1:1 DMs are a different mesh resource than /v1/notify/channels.
  // Skipping inbox/thread here is how Jacob's today messages never hit cache.
  if (typeof io.getInbox === "function" && principalUid && io.writeInbox) {
    try {
      const inbox = await io.getInbox();
      if (inbox) {
        io.writeInbox(principalUid, inbox);
        written.inbox = true;
        const uids = pairDmUidsFromInbox(inbox);
        let dmIndex = 0;
        for (const uid of uids) {
          dmIndex += 1;
          if (typeof io.onProgress === "function") {
            io.onProgress({
              phase: "dms",
              current: dmIndex,
              total: uids.length,
              label: uid,
            });
          }
          if (typeof io.getDmThread !== "function" || !io.writeDmThread) continue;
          await pace();
          try {
            const thread = await io.getDmThread(uid);
            if (thread) {
              const enriched = await attachReactionsToPayload(
                thread,
                `dm:${uid}`,
                io.getReactions,
              );
              io.writeDmThread(uid, enriched);
              written.threads += 1;
            }
          } catch {
            // one pair must not fail the rest
          }
        }
      }
    } catch {
      // inbox warm is required for pair DMs but must not abort channel cache
    }
  }
  if (typeof io.getContacts === "function" && principalUid && io.writeContacts) {
    try {
      const contacts = await io.getContacts();
      if (contacts) {
        io.writeContacts(principalUid, contacts);
        written.contacts = true;
      }
    } catch {
      // contacts warm is best-effort
    }
  }
  return written;
}

export function formatDoctorReport(summary, { json = false } = {}) {
  if (json) return JSON.stringify(summary, null, 2);
  const lines = [
    "company                     project                          mesh      cache   planned",
    "--------------------------- -------------------------------- --------- ------- --------------------",
  ];
  for (const row of summary.projects) {
    const planned = row.error
      ? `ERROR ${row.error}`
      : (row.planned || []).join(",") || "none";
    lines.push(
      `${String(row.company).padEnd(27)} ${String(row.projectId).slice(0, 32).padEnd(32)} ${String(row.mesh).padEnd(9)} ${String(row.cache).padEnd(7)} ${planned}`,
    );
  }
  lines.push("");
  lines.push(
    `${summary.okCount} ok  ${summary.missing} missing  ${summary.stale} stale  ${summary.cacheWarmed} cache-warmed  ${summary.puts} puts  ${summary.channels} channels  ${summary.errors} errors`,
  );
  if (!summary.apply) {
    lines.push(`audit only — pass --apply to repair (paced ${summary.paceMs}ms between mutations). PUT is skipped when the mesh already matches.`);
  }
  return lines.join("\n");
}
