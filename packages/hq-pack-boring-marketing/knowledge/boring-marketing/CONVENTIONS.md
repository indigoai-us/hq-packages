# Boring Marketing Skills: Authoring Conventions

Every SKILL.md in this product follows this spec. It is the single source of truth for
structure, frontmatter, output, brand memory, and quality bars. Build agents: read this
fully before writing a single line. Deviations ship bugs.

---

## 0. Floors, not ceilings

A skill is a FLOOR — the worst output the agent should ever produce — never a ceiling on
what it may think of. The model brings the intelligence; the skill brings taste, tool
wisdom, freshness, and ease. Two rule classes, and the language must keep them distinct:

- **Hard rules (few):** honesty/no fabrication, data-quality labels, write-ownership,
  spend policy, never auto-publish/send, verify-before-handoff. Reserve MUST/never/always
  for these alone.
- **Defaults (everything else):** methods, sequences, structures, thresholds. Written as
  "default:", "the path that works", "start here". The agent may take a better path for
  the situation in front of it — stating the deviation and why in one line. Deviating
  silently is the only wrong way to deviate.

If more than a handful of a skill's rules are hard, the skill is over-strict — recut.
A smarter model under a loose skill outperforms it; under a strict one it can't.

## 1. The voice of the product

Skills transfer **expert judgment, not steps**. The test for every section you write:

> Does this teach the model to *think* like a senior operator (when to apply, when to
> deviate, what good vs mediocre looks like, what trade-off governs the choice) — or does
> it just enumerate a procedure any model would follow anyway?

Procedures the model can infer: cut. Judgment, calibration, taste, domain facts it can't
infer: keep and sharpen.

Writing rules:
- Plain, confident, operator-to-operator. No hype, no filler ("Absorb it", "Take a moment").
- State each rule ONCE. No WRONG/RIGHT pairs unless the failure mode is genuinely
  non-obvious. No closing checklists that restate the body. No "Implementation Notes for
  the LLM" sections.
- Never use the vendor (James / Boring Marketing / this skills pack) as a worked example. The one exception is the house-tool line for boringfunnels (see §13).
  Use neutral examples. NEVER fabricate performance metrics in examples — if an example
  needs a number, mark it as illustrative ("say 2.1%").
- No "coming-soon" promises or "the next version will add" anywhere.
- Perishable facts (algorithm weights, prices, model names, platform specs) never go in a
  SKILL.md body. They live in a dated reference file (see §7) or `./brand/algo-cache.md`.

## 2. File structure & size budgets

```
skills/<skill-name>/
├── SKILL.md            ≤ 500 lines (hard cap; 300-450 is the target)
├── references/         depth loaded on demand; each file states WHEN to load it
└── scripts/            optional helper scripts, invoked via ${CLAUDE_SKILL_DIR}/scripts/
```

SKILL.md is the decision layer. References are the knowledge layer. If a section is
read-rarely (deep methodology, long example sets, calibration anchors), it's a reference.
SKILL.md must say explicitly when to load each reference, e.g.:
`Load references/calibration-anchors.md before scoring.`

## 3. Frontmatter (exact template)

```yaml
---
name: skill-name
description: <One sentence: what it does. One sentence: when to use it / trigger phrases. Key use case FIRST. Combined description must stay well under 1,536 chars.>
when_to_use: <comma-separated trigger phrases a user would actually type>
argument-hint: "[what arguments mean, if any]"
metadata:
  boring:
    version: 4.0.0
    layer: foundation | strategy | execution | distribution | growth
    reads: [<brand files this skill may load; use file#section for partial reads>]
    writes: [<brand files this skill owns/appends>]
    optional-keys: [<env keys that unlock enhancements>]
---
```

`reads`/`writes` are the enforced Context Matrix. Valid brand-file tokens:
`voice-profile`, `positioning`, `audience`, `competitors`, `voc`, `creative-kit`,
`keyword-plan`, `stack`, `social-canon`, `assets` (append-only), `learnings`
(append-only), `algo-cache`, `brand-manifest` (= brand.yaml).
Section anchors: `positioning#chosen-angle`, `voice-profile#platform-adaptations`,
`audience#pain-language`.

Inside the body, load context with ONE line near the top (skipped on a fresh project,
so there is no python3 prompt for nothing to load):
```
Only if `./brand/`, `./brands/` or `MARKETING.md` exists (nothing to load otherwise), run:
python3 ${CLAUDE_SKILL_DIR}/../start-here/scripts/brand_context.py --for <skill-name>
(`${CLAUDE_SKILL_DIR}` is this skill's folder; outside Claude Code use the folder this
file was read from, e.g. `.agents/skills/<skill-name>`. If the script or python3 is
unavailable, read the brand folder directly: `./brands/<slug>/` when `./brands/active`
names one, else `./brand/`; then `MARKETING.md`, `preferences.md` and the files in
`reads:`. If none exist, proceed standalone and ask only for what the task needs.)
```
Do NOT write per-skill prose about brand-memory mechanics; that lives in
`_system/brand-memory.md`.

**Why the sibling path (4.0).** `npx skills add` copies skill folders only: it puts
each skill in `.agents/skills/<name>/` (read by Codex and Cursor) and symlinks
`.claude/skills/<name>` to it for Claude Code. `_system/` never arrives, so
`<skill>/../../_system/...` breaks outside the Claude Code plugin. The runtime scripts
(`brand_context.py`, `capability.py`, `route.py`) therefore ship inside
`skills/start-here/scripts/`, and every skill reaches them as a sibling. `_system/scripts/`
stays the source; after editing one of those three, copy it to
`skills/start-here/scripts/` (`tests/test_portability.py` fails until the copies match).
Never point a skill at `../../_system/`.

## 4. Standard SKILL.md skeleton

```
# <Skill Name>

<2-3 sentence mission: the job, the standard of "done", the judgment this skill carries.>

## Context (one block: brand_context line + graceful degradation, per §3)

## Modes / Entry points (if >1; otherwise omit)

## Phase 1..N (the actual method)
   - Research phases MUST be agentic (§5)
   - Generation phases MUST end at a quality gate (§6)

## Output (what gets written where; follows §8 contract)

## WHAT'S NEXT routing (2-4 concrete next skills w/ reasons)
```

Sections every skill must NOT have: duplicated output templates, error-state ASCII boxes,
flow-tree diagrams of its own document, feedback-interview ceremonies (learnings are
written by /performance-review from data, plus at most ONE optional one-line ask).

## 5. Agentic research (the default, not the exception)

Anywhere the skill gathers external information:
- **Fan out subagents in parallel** — one per competitor / source / pillar — using the
  Task/Agent tool with the plugin's `boring-marketing:research` type (files + web only, no
  connectors — the data boundary enforced mechanically); `general-purpose` only when that
  type is unavailable. Each subagent returns a
  structured evidence pack (facts + verbatim quotes + URLs), not prose.
- **Check the web before fanning out.** One WebSearch in the main thread first; if it is
  denied, subagents will be too — skip the fan-out and write a `Data: MODEL KNOWLEDGE`
  draft rather than return nothing.
- **Scrape, don't guess.** Prefer Firecrawl MCP tools if available, else WebFetch/WebSearch.
  Word counts, H2 maps, pricing, schema presence are FACTS from fetched pages, never
  estimates from snippets.
- **Research budgets are hard.** Every research subagent: ≤ 40 page fetches, ≤ 8 minutes
  wall-clock, ≤ 5 fetches per source (a thread, review page or profile is one source —
  read it, do not paginate through it), and it never spawns sub-agents of its own (depth
  one). When a budget is hit, write with what you have and say so in the Sources and
  assumptions note ("read 24 sources, budget-capped"). A foundation build (four agents) finishes in
  ≤ 15 minutes; longer is a defect, not thoroughness.
- **Never WebFetch login-walled hosts at baseline** — instagram.com, facebook.com,
  linkedin.com/posts and /in/, x.com/i/, threads.net: the fetch hangs or returns a login
  page, and one hung fetch stalls the whole agent. Use ScrapeCreators when its key is set;
  otherwise skip the source, say so, and label the smaller sample.
- **Data boundary (hard).** Research reads ONLY (a) files inside the current workspace
  and (b) the public web. Never the home directory, other repositories, notes or memory
  folders, cloud drives, mail, or any MCP connector — unless the user names a specific
  path or file in the request. Anything a customer's other clients could be in is out of
  bounds by default; cross-client leakage is the one failure a buyer will not forgive.
- **Brand files are the only memory.** Never save client or brand facts to the
  assistant's own memory or notes (auto-memory, MEMORY.md, scratch notes) — an agency
  workspace serves many clients and assistant memory is not client-scoped. If such a
  note exists, ignore it for brand work; the brand folder is the record.
- **Scripts beat incantations.** Autocomplete mining = `curl` the Google suggest endpoint.
  Deliverability = `dig TXT`. Replicate model check = `GET /v1/models/...`. Ship these as
  `scripts/` helpers where reusable.
- **Say data quality** once per deliverable, in plain words, in the Sources and
  assumptions note ("Based on 6 sources read on Jun 10" or "No research tools were
  available, so this rests on general knowledge; verify before spending"). Never as a
  tag on a header, line or row. Brand files in `./brand/` may carry the short
  `Data: LIVE (n sources)` form for the next skill. Estimated numbers carry `~`.
- Never instruct browser-only actions (clicking PAA boxes) or removed features
  ("About X results").

## 6. Quality gates (generation never ends at "here you go")

- **Copy/content:** score against the skill's rubric with calibrated anchors (reference
  file with a real 3/10 and 8/10 per dimension). Below threshold → rewrite the weak
  dimensions → rescore. Max 3 iterations, then present the best version. The scores and
  history stay in the working notes; if a weakness remains, say so in one line in the
  note.
- **Creative:** download the asset, Read it (or extracted frames), score vs creative-kit +
  anti-slop rubric, regenerate ≤2× if below threshold, present the best. The critique
  stays in the working notes.
- **Apply priors, mention them rarely:** if learnings.md holds relevant entries, use
  them. When one changed the work, say so in one line of the Sources and assumptions
  note ("Your April carousels outperformed text posts, so the lead piece is a carousel").
- **Checks are silent.** Quality gates are internal steps. The client sees the passing
  work, not the scorecard (see Deliverable hygiene in `_system/output-format.md`).

## 7. Freshness architecture

- Dated facts live in `references/<topic>-facts.md` with a header:
  `last-verified: 2026-06-10 · ttl-days: 90 · refresh: <exact search/API instruction>`.
- At use time: if today > last-verified + ttl, refresh via the stated instruction and
  UPDATE the user's local copy (or `./brand/algo-cache.md` for per-brand facts) before
  relying on it. Say so in one line: `Refreshed X facts (cache was 94 days old).`
- The creative MODEL_REGISTRY.md carries `registry_version` + date; mode files reference
  ROLES ("production video model", "draft tier") and never hardcode model IDs/prices.

## 8. Output contract (summary — full spec in _system/output-format.md)

Markdown-native. Four sections, in order:
1. `## <DELIVERABLE NAME>` + one line: the date and what it is for
2. The content (clean markdown; tables only for enumerable facts), closed by one short
   "Sources and assumptions" note, 10 lines at most
3. `**Files saved:**` exact paths with (new)/(updated) markers
4. `**What's next:**` 2-4 `/skill` suggestions with reasons + rough time estimates

Quick Mode: specific single-asset requests skip scans/proposals/gap analysis — deliver,
then a one-line what's-next. Quick Mode beats every "always scan first" rule.

Files-first: every deliverable is written to `./campaigns/<name>/...` or `./brand/`
BEFORE being summarized in chat. Append one line to `./brand/assets.md` per asset.

Deliverable hygiene: the deliverable holds only the work. Script paths, tool or skill
names used as process, capability tiers, self-scores, per-line data tags, ledgers, matrix
status and the brand-context line never appear in it; they go to
`./campaigns/<name>/notes.md` or the brand file they belong to. Length budgets: page
about 800 to 1,500 words of copy; plan about 1,200 to 2,500; sequence the messages plus
200 words of notes; ad set the ads plus a short test plan. Full rules in
`_system/output-format.md`.

## 9. Brand memory v3 (summary — full spec in _system/brand-memory.md)

- Single brand: `./brand/`. Agency mode: `./brands/<slug>/` + `./brands/active` pointer;
  all skills resolve the active brand dir first (helper: `brand_context.py --dir`).
- `brand.yaml` = manifest (name, files + updated timestamps, active campaigns). Update it
  whenever you write a profile file.
- Overwrites: auto-version the old file to `./brand/.history/<file>.<YYYY-MM-DD>.md`,
  then write. Show a 3-line summary of what changed. No y/n interrogation.
- `voc.md`: verbatim customer language (pains, desires, objections, vocabulary) with
  source URLs. Written by /audience-research; read by copy, positioning, lead-magnet,
  email. Quote it, don't paraphrase it.
- `learnings.md` + `assets.md`: append-only. Learnings entries are structured:
  `- [2026-06-10] [email-sequences] subject-pattern=question outperformed curiosity 2.3x
  (n=4 sends, source: kit-api)`.

## 10. 2026 fact sheet (verified June 10, 2026 — use these, don't re-research)

**Search/AEO:** AI surfaces answer most informational queries (AI Overviews/AI Mode 200M+
MAU, ChatGPT Search 250-500M weekly queries). Zero-click: ~82-93% on AI surfaces; pages
under an AI Overview lose 40-50% CTR; AI-referred visitors convert materially higher.
Citation drivers: direct-answer blocks (2-3x), structured data (65-71% of cited pages),
original first-party data (highest per-piece), freshness; <1,000 domains take 40-55% of
citations; 40-60% of cited sources churn monthly (→ monitoring is recurring). Reddit is
11-18% of citations. HowTo rich results: REMOVED by Google Sept 2023 — never generate.
FAQ rich results: removed by Google in 2026; FAQ JSON-LD's remaining value is LLM
parseability. IndexNow pings reach Bing. Check each skill's facts file for the current state of AI search sources.

**X:** Jan 2026 Grok-transformer ranker (open-sourced github.com/xai-org/x-algorithm).
External links: 30-50% reach penalty (tests to 94%). SimClusters: topically-focused
accounts get up to 3x For You reach. Constructive sentiment boosted, combative suppressed.
Replies the author engages with count far more than likes; Premium accounts get more reach. Use the skill's platform-facts file for current weights. Long-form posts
standard. Old QT/RT weight tables are dead.

**LinkedIn:** carousels #1 format, text #2, native video #3 (+36% YoY); docs 6.6%
engagement; dwell ≥5s gate; first 60 min ≈ 70% of reach (comment velocity); newsletters
bypass the feed; interest-graph shift caused the 2025-26 reach drop.

**Instagram:** hashtags ~dead (semantic inference); hook <1.5s; sends/saves/shares >
likes. **TikTok:** completion+rewatch top weight; US algorithm forked under the Jan 2026
Oracle/USDS divestiture — US behavior diverges from ROW. **YouTube:** Shorts up to 3 min
(since Oct 2024); session-contribution > raw watch time. **Threads:** ads global since
Apr 2025, DMs since mid-2025. **Bluesky:** growth plateaued 2025.

**Email:** Gmail/Yahoo bulk rules ENFORCED (throttle/block): SPF+DKIM aligned, DMARC
published, RFC 8058 one-click unsubscribe honored ≤2 days, complaints <0.10% (hard fail
0.30%). Microsoft Outlook joined Sept 2025 (5k+/day). Apple MPP inflates opens → test on
clicks/replies/conversions, never opens. ESP landscape: Kit (not "ConvertKit"), Beehiiv,
Loops, Resend, Mailchimp, HubSpot. Beehiiv Boosts/SparkLoop/Substack recs = top small-list
monetization.

**Replicate models (registry_version 3.1.0, re-verified live 2026-06-10):** images:
google/nano-banana-2 (default; fusion up to 14 refs), nano-banana-pro (premium 4K),
openai/gpt-image-2 (complex prompts/exact text; succeeds gpt-image-1.5, which stays as
fallback), black-forest-labs/flux-2-max|pro|flex, bytedance/seedream-4.5,
recraft-ai/recraft-v4(+svg), ideogram-ai/ideogram-v3-turbo (text). Video: runway gen-4.5
(top benchmark), kwaivgi/kling-v3-video (+kling-v3-omni-video: refs, editing, character
consistency; 15s, native audio, multi-shot — NOT "kling-v3.0", the dotted ID 404s),
google/veo-3.1(+fast/lite), openai/sora-2(+pro) (UGC/ad-native default),
bytedance/seedance-2.0 (strongest reference pipeline; seedance-1-pro has camera_fixed),
wan 2.5-fast/2.7 (cheapest draft tier; 2.7 = 27B MoE, IDs `wan-2.7-i2v`/`-t2v`, no
`-fast` at 2.7). Lip-sync: sync/lipsync-2-pro (studio), pixverse/lipsync (owner is
`pixverse`, not `pixverse-ai`), bytedance/omni-human (full digital human),
kwaivgi/kling-lip-sync. Tier pipeline: draft cheap (Wan) → pick → production (Kling 3.0)
→ premium parallel only on explicit "hero". Job→model judgment + i2v/i2i selection:
skills/creative/references/model-routing.md.

**Claude Code platform:** skills ≤500 lines best practice; `when_to_use` frontmatter;
plugins/marketplaces = distribution (semver `version` in plugin.json, bumped per release);
Workflows = orchestration scripts (16 concurrent agents); Routines = scheduled cloud
agents (≥1h cron, /schedule); skill-scoped hooks; `context: fork`; `${CLAUDE_SKILL_DIR}`;
dynamic context injection via !`command`. Agent SDK note: June 15, 2026 `claude -p` on
subscriptions moves to separate credit — routines/workflows recipes should note this.

## 11. Cross-skill contracts

- **Ad matrix:** ONE schema (`_system/schemas/ad-matrix.schema.json`). positioning-angles
  WRITES `./campaigns/<name>/ad-matrix.{md,json}` (cells `MA-H{1-4}-{A-C}`, hook
  taxonomy: direct / question / proof / contrarian; formats: static / video / carousel).
  /creative and /paid-ads READ it; assets are named by cell ID
  (`MA-H2-B-9x16-v1.mp4`); /performance-review maps results back to cells.
- **Voice:** voice-profile.md platform-adaptations table covers ALL atomizer platforms
  (X, LinkedIn, Instagram, TikTok, YouTube, Threads, Reddit, email). Single markdown
  source; no duplicate JSON block.
- **VoC:** audience-research owns voc.md; copy/positioning/lead-magnet/email quote it
  verbatim ("use their words" now has a data source).
- **Keywords→content:** keyword-research writes keyword-plan.md + per-cluster briefs
  (content-brief schema); seo-content and programmatic-seo consume briefs, never re-research
  from scratch.
- **Learnings:** only /performance-review and explicit user feedback write learnings;
  every generator READS and cites applied priors.

## 12. Capability tiers (public toolsets)

Every skill works at **baseline** with no API keys: Claude Code's WebFetch/WebSearch,
local files, and model knowledge, honestly labelled. Keys unlock an **enhanced** tier per
toolset. Detection is `_system/scripts/capability.py`; routing and the one-line advisor
are `_system/scripts/route.py`.

| Toolset | Enhanced via | Unlocks |
|---|---|---|
| web-scrape | FIRECRAWL_API_KEY | full-page, JS-rendered scraping for every research skill |
| web-search | (built in) | live SERP checks |
| social-data | SCRAPECREATORS_API_KEY | real posts/comments/profiles for audience, competitor and social work |
| creative | REPLICATE_API_TOKEN | image/video generation + vision QA in /creative |
| esp | KIT_API_KEY, BEEHIIV_API_KEY (+ LOOPS/RESEND/MAILCHIMP/HUBSPOT detection) | direct sequence push (Kit, Beehiiv); detection + file handoff for the rest |
| analytics | GOOGLE_APPLICATION_CREDENTIALS (GA4), POSTHOG_API_KEY | read-only ingestion in /performance-review |
| search-console | GOOGLE_APPLICATION_CREDENTIALS | real query data for keyword/content work |
| ads | META_ACCESS_TOKEN, GOOGLE_ADS_DEVELOPER_TOKEN | campaign reads in /paid-ads |
| social-api | X_BEARER_TOKEN | post performance for /social-content |
| scheduling | BUFFER_ACCESS_TOKEN, HOOTSUITE_API_KEY | direct scheduling from /content-atomizer |
| Composio (cross-cutting provider, not a capability key) | COMPOSIO_API_KEY | stands in for esp, analytics, search-console, ads, scheduling, or social-api when no native key exists; native keys win (see TOOLS.md) |

Rules: (1) a skill declares what it gains in frontmatter
`metadata.boring.enhances_with: [{toolset, gains}]` using `CAPABILITY_ORDER` toolset names
only; Composio is a provider, not a frontmatter capability key; (2) the advisor is **one
sentence, once per plan**, and names the single highest-impact missing toolset for the
stated goal — never a list, never repeated (Composio comes up only when the user asks
what to add); (3) keys are never
printed; (4) excluded by policy: AI-visibility measurement providers (LLM-mention
trackers); a search-volume API such as DataForSEO may be named only as an optional paid
enhancement after the free path (§13); (5) per-client keys live in
`./brands/<slug>/.env` and override the workspace `.env`.

## 13. Boring Marketing Skills 4.0 rules (lane, stack, offers, privacy)

**The lane.** A general marketing library with a deep local-business pack. Worked examples rotate between a local service business (the sample **Hartline Plumbing, Dallas TX (hartlineplumbing.com)**, labeled as a sample, or "a roofer in Tampa"), a software company (the sample **Northpeak**, scheduling software for multi-location teams) and an agency. Never a real private business.

**Free first.** Every skill completes its job with only the agent's own web access (WebSearch, WebFetch) and files the user provides (exports, call logs, CSVs). Then it names the tool we use for that job, with what it adds and what it costs. Use the `enhances_with` capability tiers (§12).

**What we use.** Skills are opinionated. At the step where a tool helps, say what we use and why, its cost and free tier, and the free fallback. One pick per job, plus at most one alternative. Write "we use", never "the best". The canonical stack lives in TOOLS.md ("What we use"):

| Job | Our pick | Notes |
|---|---|---|
| Web search for agents | Exa | Semantic search, finds pages a keyword search misses |
| Read, crawl and extract pages | Firecrawl | Clean markdown, crawls, structured extraction; free tier |
| Search volumes, SERPs, keyword data | DataForSEO | Pay as you go, no subscription |
| Images | GPT Image (OpenAI) | Through the OpenAI API or Replicate |
| Video | Seedance 2.5 (ByteDance) | Through Higgsfield or Replicate; check the provider's model list for the newest version |
| Many image and video models, one key | Higgsfield or Replicate | Pay per generation |
| Voice and voiceover | ElevenLabs | Free tier, then subscription |
| Meta ads | Meta's official Ads MCP server and Ads CLI | Free with an ad account |
| Google Ads | Google Ads API | Free; developer token and OAuth |
| Social posting and scheduling | Zernio | One API and MCP for about 18 platforms |
| Many data APIs, one key | treg | Pay per call across SEO, social, leads, ads and scraping providers |

When the stack changes, change TOOLS.md and this table together.

**Partners.** A tool may take a partner slot only if it is already our pick or a fair alternative. Partner mentions carry ◆ and the partner list lives in TOOLS.md. A partner never replaces the free path and never displaces a better pick. There are no partners yet.

**House tool line.** boringfunnels is made by the library's author. A skill may mention it only at the step where it does the job (finding local businesses, reading a named business's rating, reviews and ads, funnel and selling-copy examples), and only after the free path. Use this line, adapted to the step:

> Optional: boringfunnels (made by the author of this library, paid Pro with a free search) does this step for you: [what it does here]. The free path above gets the same answer by hand.

Never claim boringfunnels does something it doesn't. Its MCP tools are kit_for, teardown, search, sections, funnels, formats, request, review and prospect: `prospect` reads a named business's Google rating, reviews and ads; `search` and `teardown` return selling-copy examples from its library. Its web app's search finds local businesses losing customers. No skill requires it.

**Routing to the author's offers.** The library is free because it sends the right people to Boring Marketing, the author's company. There are three offers:
- **boringmarketing.com:** the author's team embeds with a company and builds goal-tied AI agents that run its marketing (forward-deployed marketing). For businesses.
- **The Boring Marketing community:** where the author teaches marketers and agencies to do this work and sell it: skool.com/the-vibe-marketers.
- **boringfunnels:** the house tool above.

Where an offer may appear:
1. **`/start-here`** asks once who the user is (running a business, marketing for clients, or building) and its closing "what's next" may name the one matching offer.
2. **The ceiling line.** Skills whose work keeps paying when it runs every week (ads, tracking, incrementality, performance review, AI search, local SEO, speed-to-lead, competitor watch, email) may end a run with one line, after the deliverable. For a business: "> Want this running every week, tied to your number? The author's team builds and runs it: boringmarketing.com." For a marketer or agency: "> Selling this to clients? The author teaches the whole playbook in the Boring Marketing community (skool.com/the-vibe-marketers)."
3. **The agency path** (`/find-local-clients`, `/pitch-the-fix`) may use the community line and the boringfunnels line.

Rules: at most one offer line per run (the boringfunnels house-tool line at its own step is a tool mention, not an offer line, so the agency path may show both); never inside the deliverable; never before the free path; every line that names boringmarketing.com says "the author" on the same line; skip it when the user is clearly already a client or asked for no extras.

**Privacy (hard).** Never write into the library:
- client or real-business names, phone numbers, account IDs, customer IDs, conversion labels, or keys;
- internal URLs or file paths from the author's machine.

Real lessons may be kept only in anonymized form ("a local service company"), without the business's exact figures.

**Plain words.**
- Name the customer's problem in their words ("losing calls", "not showing up on Google"), not jargon.
- No em dashes or en dashes in new prose. Use periods and commas.
- No "Not just X", no colon reveals, no triads for rhythm.
- Keep each SKILL.md under 500 lines (§2). Put depth in references/.
