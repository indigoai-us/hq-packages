import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  createPacer,
  discoverLocalProjects,
  mergeProjectView,
  meshViewNeedsPut,
  newestProjectActivityAt,
  projectViewFromPrd,
  listProjectArtifactFiles,
  readCloudCompanyUid,
  runDoctor,
  stubProjectView,
  pairDmUidsFromInbox,
  attachReactionsToPayload,
  warmConversationCache,
} from "../work-mesh-doctor.mjs";

test("listProjectArtifactFiles keeps notes and skips genesis/repos", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "hq-project-files-"));
  fs.writeFileSync(path.join(dir, "prd.json"), "{}");
  fs.writeFileSync(path.join(dir, "brainstorm.md"), "# b");
  fs.writeFileSync(path.join(dir, "fabric-genesis.json"), "{}");
  fs.mkdirSync(path.join(dir, "journal"));
  fs.writeFileSync(path.join(dir, "journal", "note.md"), "n");
  const files = listProjectArtifactFiles(dir, "demo");
  assert.deepEqual(files.map((f) => f.name).sort(), ["brainstorm.md", "note.md", "prd.json"]);
  assert.ok(files.every((f) => f.path.startsWith("projects/demo/")));
});

test("readCloudCompanyUid only accepts cmp_ values", () => {
  assert.equal(readCloudCompanyUid("name: indigo\ncloudCompanyUid: cmp_01ABC\n"), "cmp_01ABC");
  assert.equal(readCloudCompanyUid("cloudCompanyUid: 'cmp_01ABC'\n"), "cmp_01ABC");
  assert.equal(readCloudCompanyUid("cloudCompanyUid: personal\n"), "");
  assert.equal(readCloudCompanyUid("# cloudCompanyUid: cmp_NOPE\nname: x\n"), "");
});

test("projectViewFromPrd tolerates object-shaped repos and criteria", () => {
  const view = projectViewFromPrd({
    name: "Weird",
    userStories: { not: "an array" },
    repos: { path: "nope" },
    metadata: { repos: { also: "nope" } },
  }, "cmp_x", "weird");
  assert.deepEqual(view.stories, []);
  assert.deepEqual(view.repos, []);
});

test("projectViewFromPrd maps stories and does not invent status", () => {
  const view = projectViewFromPrd({
    name: "Demo",
    description: "d",
    userStories: [
      { id: "US-001", title: "A", passes: true, acceptanceCriteria: ["ok"] },
      { id: "US-002", title: "B", status: "in_progress" },
    ],
    repos: [{ path: "repos/public/hq-core", branch: "main" }],
  }, "cmp_x", "demo");
  assert.equal(view.stories[0].status, "done");
  assert.equal(view.stories[1].status, "in_progress");
  assert.equal(view.repos[0].path, "repos/public/hq-core");
});

test("merge never downgrades a live mesh story status", () => {
  const remote = {
    companyUid: "cmp_x",
    projectId: "demo",
    name: "Demo",
    description: "",
    stories: [{ id: "US-001", title: "A", status: "in_progress", acceptanceCriteria: [] }],
    repos: [],
  };
  const local = projectViewFromPrd({
    name: "Demo",
    userStories: [
      { id: "US-001", title: "A", status: "queued" },
      { id: "US-002", title: "New", status: "queued" },
    ],
    repos: [{ path: "repos/private/foo", branch: "feat" }],
  }, "cmp_x", "demo");
  const merged = mergeProjectView(remote, local);
  assert.equal(merged.stories.find((s) => s.id === "US-001").status, "in_progress");
  assert.equal(merged.stories.find((s) => s.id === "US-002").title, "New");
  assert.equal(merged.repos[0].path, "repos/private/foo");
  assert.equal(meshViewNeedsPut(remote, merged), true);
  assert.equal(meshViewNeedsPut(merged, merged), false);
});

test("identical remote and local does not need a PUT", () => {
  const local = stubProjectView("cmp_x", "demo");
  local.name = "Demo";
  local.stories = [{ id: "US-001", title: "A", description: "", acceptanceCriteria: [], status: "queued", passes: false, priority: null }];
  const remote = { ...local, stories: local.stories.map((s) => ({ ...s })) };
  assert.equal(meshViewNeedsPut(remote, mergeProjectView(remote, local)), false);
});

test("discoverLocalProjects is tenant-scoped and skips no-prd unless --all", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "hq-doctor-"));
  try {
    const indigo = path.join(root, "companies", "indigo", "projects");
    const other = path.join(root, "companies", "acme", "projects");
    fs.mkdirSync(path.join(root, "companies", "indigo"), { recursive: true });
    fs.mkdirSync(path.join(root, "companies", "acme"), { recursive: true });
    fs.writeFileSync(path.join(root, "companies", "indigo", "company.yaml"), "cloudCompanyUid: cmp_01INDIGO\n");
    fs.writeFileSync(path.join(root, "companies", "acme", "company.yaml"), "name: acme\n");
    fs.mkdirSync(path.join(indigo, "alpha"), { recursive: true });
    fs.mkdirSync(path.join(indigo, "bare"), { recursive: true });
    fs.mkdirSync(path.join(indigo, "_archive", "old"), { recursive: true });
    fs.mkdirSync(path.join(other, "secret"), { recursive: true });
    fs.writeFileSync(path.join(indigo, "alpha", "prd.json"), JSON.stringify({ name: "Alpha", userStories: [] }));
    fs.writeFileSync(path.join(other, "secret", "prd.json"), JSON.stringify({ name: "Nope" }));

    const found = discoverLocalProjects(root, {});
    assert.deepEqual(found.companies.map((c) => c.slug), ["indigo"]);
    assert.deepEqual(found.projects.map((p) => p.projectId), ["alpha"]);

    const all = discoverLocalProjects(root, { all: true });
    assert.deepEqual(all.projects.map((p) => p.projectId).sort(), ["alpha", "bare"]);

    const one = discoverLocalProjects(root, { company: "indigo", project: "alpha" });
    assert.equal(one.projects.length, 1);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("doctor warms cache from GET and never PUTs when views match", async () => {
  const puts = [];
  const ensures = [];
  const cache = new Map();
  const remote = {
    companyUid: "cmp_x",
    projectId: "alpha",
    name: "Alpha",
    description: "",
    stories: [],
    repos: [],
  };
  const summary = await runDoctor({
    projects: [{
      slug: "indigo",
      companyUid: "cmp_x",
      projectId: "alpha",
      hasPrd: true,
      dir: "/tmp/alpha",
      localDesired: { ...remote },
    }],
    apply: true,
    paceMs: 0,
    jitterMs: 0,
    concurrency: 1,
  }, {
    getProjectView: async () => remote,
    putProjectView: async (_c, id, body) => {
      puts.push(id);
      return body;
    },
    ensureProject: async (_c, id) => {
      ensures.push(id);
    },
    writeCache: (view) => {
      cache.set(view.projectId, view);
      return `cache/${view.projectId}`;
    },
    readCache: (c, id) => cache.get(id) || null,
    sleep: async () => {},
    now: () => 0,
    random: () => 0,
  });
  assert.equal(puts.length, 0);
  assert.equal(ensures.length, 0);
  assert.equal(summary.cacheWarmed, 1);
  assert.equal(summary.puts, 0);
  assert.equal(summary.okCount, 1);
});

test("doctor --apply PUTs missing views and paces mutations", async () => {
  const puts = [];
  const sleeps = [];
  let clock = 1_000;
  const summary = await runDoctor({
    projects: ["a", "b"].map((id) => ({
      slug: "indigo",
      companyUid: "cmp_x",
      projectId: id,
      hasPrd: true,
      dir: `/tmp/${id}`,
      localDesired: stubProjectView("cmp_x", id),
      activityAt: "2026-04-01T00:00:00.000Z",
    })),
    apply: true,
    paceMs: 2500,
    jitterMs: 0,
    concurrency: 2,
  }, {
    getProjectView: async () => null,
    putProjectView: async (_c, id, body) => {
      puts.push({ id, lastActivityAt: body.lastActivityAt });
      return { ...body, projectId: id };
    },
    ensureProject: async () => ({ created: true }),
    writeCache: () => "ok",
    readCache: () => null,
    sleep: async (ms) => {
      sleeps.push(ms);
    },
    now: () => clock,
    random: () => 0,
  });
  assert.deepEqual(puts, [
    { id: "a", lastActivityAt: "2026-04-01T00:00:00.000Z" },
    { id: "b", lastActivityAt: "2026-04-01T00:00:00.000Z" },
  ]);
  assert.equal(summary.puts, 2);
  assert.equal(summary.channels, 2);
  assert.equal(summary.missing, 2);
  assert.ok(sleeps.some((ms) => ms >= 2500), `expected a 2500ms pace, got ${JSON.stringify(sleeps)}`);
});

test("newestProjectActivityAt prefers the latest real project date, not now", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "hq-act-"));
  try {
    const dir = path.join(root, "proj");
    fs.mkdirSync(dir);
    const prdPath = path.join(dir, "prd.json");
    fs.writeFileSync(prdPath, "{}");
    const then = Date.parse("2026-04-01T12:00:00.000Z");
    fs.utimesSync(prdPath, then / 1000, then / 1000);
    const at = newestProjectActivityAt({
      dir,
      prd: { metadata: { createdAt: "2026-03-01T00:00:00.000Z" } },
      genesisAt: "2026-03-15T00:00:00.000Z",
    });
    assert.equal(at, "2026-04-01T12:00:00.000Z");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("pairDmUidsFromInbox collects partners from events and pairUnreads", () => {
  assert.deepEqual(
    pairDmUidsFromInbox({
      events: [{ fromPersonUid: "prs_jacob" }, { fromPersonUid: "not-a-uid" }],
      pairUnreads: [{ withPersonUid: "agt_01agent" }],
    }),
    ["agt_01agent", "prs_jacob"],
  );
});

test("warmConversationCache writes directory and dm/chat/project message windows", async () => {
  const dirs = [];
  const chans = [];
  const written = await warmConversationCache({
    principalUid: "prs_01ARZ3NDEKTSV4RRFFQ69G5FAV",
    paceMs: 0,
    jitterMs: 0,
  }, {
    getDirectory: async () => ({
      rows: [
        { channelId: "chn_dm", type: "dm" },
        { channelId: "chn_chat", type: "chat" },
        { channelId: "chn_proj", type: "project" },
      ],
    }),
    getChannelMessages: async (id) => ({ messages: [{ id }] }),
    writeDirectory: (uid, feed) => {
      dirs.push({ uid, n: feed.rows.length });
    },
    writeChannelMessages: (id) => {
      chans.push(id);
    },
    sleep: async () => {},
    now: () => 1,
    random: () => 0,
  });
  assert.equal(written.directory, true);
  assert.deepEqual(chans.sort(), ["chn_chat", "chn_dm", "chn_proj"]);
  assert.equal(written.channels, 3);
});

test("warmConversationCache writes inbox, contacts, and pair-DM threads", async () => {
  const inboxWrites = [];
  const contactWrites = [];
  const threadWrites = [];
  const written = await warmConversationCache({
    principalUid: "prs_me",
    paceMs: 0,
    jitterMs: 0,
  }, {
    getDirectory: async () => ({ rows: [] }),
    writeDirectory: () => {},
    getInbox: async () => ({
      events: [
        { fromPersonUid: "prs_jacob", createdAt: "2026-08-16T21:10:27.909Z" },
      ],
      pairUnreads: [{ withPersonUid: "prs_jacob", unreadCount: 4 }],
    }),
    writeInbox: (uid, data) => inboxWrites.push({ uid, n: data.events.length }),
    getContacts: async () => ({
      contacts: [{ personUid: "prs_jacob", displayName: "Jacob Posel" }],
    }),
    writeContacts: (uid, data) => contactWrites.push({ uid, n: data.contacts.length }),
    getDmThread: async (uid) => ({ messages: [{ eventId: "m1", fromPersonUid: uid }] }),
    writeDmThread: (uid) => threadWrites.push(uid),
    sleep: async () => {},
    now: () => 1,
    random: () => 0,
  });
  assert.equal(written.inbox, true);
  assert.equal(written.contacts, true);
  assert.equal(written.threads, 1);
  assert.deepEqual(inboxWrites, [{ uid: "prs_me", n: 1 }]);
  assert.deepEqual(contactWrites, [{ uid: "prs_me", n: 1 }]);
  assert.deepEqual(threadWrites, ["prs_jacob"]);
});

test("attachReactionsToPayload stamps GET aggregates onto matching messages", async () => {
  const calls = [];
  const next = await attachReactionsToPayload(
    { messages: [{ eventId: "m1", body: "hi" }, { eventId: "m2" }] },
    "dm:prs_jacob",
    async (scope, id) => {
      calls.push(`${scope}:${id}`);
      if (id === "m1") return { reactions: [{ emoji: "👍", count: 1, reactedByMe: true }] };
      return { reactions: [] };
    },
  );
  assert.deepEqual(calls.sort(), ["dm:prs_jacob:m1", "dm:prs_jacob:m2"]);
  assert.deepEqual(next.messages[0].reactions, [
    { emoji: "👍", count: 1, reactedByMe: true },
  ]);
  assert.equal(next.messages[1].reactions, undefined);
});

test("createPacer skips the first call and waits later", async () => {
  const waits = [];
  let t = 0;
  const pace = createPacer({
    paceMs: 1000,
    jitterMs: 0,
    random: () => 0,
    now: () => t,
    sleep: async (ms) => {
      waits.push(ms);
      t += ms;
    },
  });
  assert.equal(await pace(), 0);
  t += 100;
  assert.equal(await pace(), 900);
  assert.deepEqual(waits, [900]);
});
