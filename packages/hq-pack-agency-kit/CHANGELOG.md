# Changelog

## 0.7.0 (2026-10-13)

- Renamed to the HQ Agency Kit. The previous partner name, keyword and
  palette are gone; `brand/` now carries the HQ palette and type (black ground, white text at 70% and 50%, hairline
  rules, Geist, square corners). Commands, slugs and file layout are
  unchanged, so existing installs and playbooks keep working.
- growth-scout: a prepared run in `growth/reddit/{date}-{site}/` (teardown,
  reply, preview) is sent as-is before any research; `report.md` is sent
  word for word when present.

## 0.6.2 (2026-10-13)

- Quoted the descriptions of 17 library skills whose text contained a colon; the
  unquoted form was invalid YAML and company sync refused to upload them.

## 0.6.1 (2026-10-13)

- Setup copies the pack's skills into `companies/{firm}/skills/` with the new
  `scripts/skills-library-install.sh`, so the library shows in the company's
  Skills view and syncs with the company. Existing company skills are kept.

## 0.6.0 (2026-10-13)

- New workflow, funnel-audit: the agency's conversion audit from the chat.
  The Agency Guide reads the client's inputs (brand guide, product details,
  competitors, proposal or SOW, CRM export, analytics export) and transcripts
  from the workspace, scores the funnel against the playbook's audit
  criteria with the evidence quoted per criterion (lost reasons with counts,
  exits by page and device, transcript lines with timestamps), a severity
  and a recommended test, then ranks the top five experiments. The draft is
  published as a password-protected review page with comments on; "Needs
  changes" or comments on the page revise and republish it with a list of
  what changed. Approval is logged in the engagement record and the next
  step offered is a Page Sprint proposal from the top experiment. Triggers:
  "run the conversion audit for {Client}", "funnel audit", "audit {Client}".
- reddit-scout drafts the reply a person posts after the hero section is
  published: short, two or three observations from the teardown, the
  preview link, the agency named once, no pitch; offered with "Looks good,
  I'll post it" or "Rewrite it". A tracker at `growth/reddit/tracker.md`
  keeps one row per teardown (date, subreddit, post, site, status, link)
  with a "Qualified calls booked" count at the top; "I posted it", "update
  the Reddit tracker" and "log a call with {site}" move a row forward
  (drafted, posted, replied, call booked, not qualified).
- Skills library: 25 small CRO skills, each a `SKILL.md` with a short
  method. Research: customer-interview-synthesis, review-mining,
  competitor-teardown, icp-statement, jobs-to-be-done-map. Audit:
  heuristic-page-review, form-friction-audit, pricing-page-review,
  mobile-ux-check, trust-and-proof-audit, analytics-leak-finder.
  Experiments: hypothesis-writer, test-prioritization, ab-test-readout,
  sample-size-check. Build: hero-rewrite, cta-hierarchy, pricing-table-copy,
  landing-page-brief, objection-handling-section. Client: kickoff-agenda,
  proposal-from-audit, case-study-draft (scope-check and weekly-update
  already existed). Growth: newsletter-issue, linkedin-post-from-readout.
  The Agency Guide's own skill list stays the workflows it runs.
- Setup ends with exactly one closing message (the summary with the
  next-step buttons), never a second "Setup is finished". A client whose
  proposal, SOW or deal names an audit package is offered "Run the
  conversion audit for {Client}".
- Worker rule: shell commands never read from standard input (no `cat`
  without a file, no `read`); the runtime's standard input is not a terminal.

## 0.5.0 (2026-10-12)

- New workflow, site-build: rebuild a client's website from the client's own
  data. The Agency Guide gathers the brand guide, product details, competitors,
  CRM export, analytics and call transcripts from the agency's tools, fetches
  the current site, writes an evidence brief (who actually buys, why visitors
  leave, what the site says and to whom), builds the new site in the client's
  brand, writes a before/after with a data point behind every change, and
  publishes a review link behind a password. Two approval gates; nothing is
  sent to the client.
- New workflow, reddit-scout: find founders asking for feedback on their site
  on Reddit, draft a specific teardown, build an improved hero section in
  their brand and publish it to a private link. `scripts/reddit.mjs` reads
  Reddit only (an agency-registered app through the HQ vault, or the public
  feeds with caching); posting is always a person's.
- Setup records each client's website and where its brand, product and
  export documents live, and offers "Build a new site for {Client}" first for
  agencies that do web or conversion work.

## 0.4.19 (2026-10-12)

- Setup asks for the agency's website, reads it, and records its look (logo,
  colors, fonts, style, voice) in `knowledge/agency-playbook/brand.md`.
- After the kickoff package is approved, onboarding builds a client-facing
  kickoff page in the agency's own look, with internal notes left out, and
  publishes it with HQ's deploy skill behind a password only when the person
  says "Publish it". The account lead shares the link; nothing is sent.
- `drive.mjs read` reads Word (.docx, .doc), RTF and OpenDocument files from
  Drive, through macOS's textutil.

## 0.4.18 (2026-10-12)

- Call transcripts synced into Google Drive or Notion count as the notetaker:
  setup and onboarding look for them there, by client name.

## 0.4.17 (2026-10-12)

- Onboarding checks every kind of source (docs, notetaker, CRM) and says
  which it checked. With no docs tool connected it offers to connect Google
  Drive or Notion right then. A missing signed contract offers a stand-in
  ("Go ahead with that") and never ends the run or offers to remove the client.
- Slack connect always puts the link in the chat, and says plainly when Slack
  only lets a workspace owner connect HQ's app, with a workaround.

## 0.4.16 (2026-10-12)

- The Agency Guide re-reads a workflow's skill file each time it starts the
  workflow. After a kit update it no longer repeats an older answer from
  earlier in the same conversation.

## 0.4.15 (2026-10-12)

- Onboarding pulls the client's documents from the agency's tools before
  asking for any: the contract and proposal from docs tools (Google Drive,
  Notion, Dropbox, e-signature) and the CRM deal, full call transcripts from
  the notetaker, and deal facts from the CRM. It shows what it found and asks
  only for the rest. A missing signed contract is a blocking question in the
  brief instead of a stop.
- Scope checks look for the contract in the agency's tools too.
- The onboarding button reads "Kick off {Client}".

## 0.4.14 (2026-10-11)

- The tool list is examples, not a limit: the Agency Guide works out how to
  connect any tool the agency uses (HQ's catalog and a sign-in link, an access
  key entered through an HQ secrets link, a docs page or MCP server, or a
  workaround such as an export dropped into the chat).
- HubSpot, Salesforce and Asana now have a route instead of "later": a
  sign-in, then an access key or an export. Email and Teams offer a
  workaround (a few forwarded emails, or the client channel names).

## 0.4.13 (2026-10-11)

- Setup always asks about the agency's meeting notetaker and project
  management tool and offers to connect them. Fireflies, Fathom, Granola,
  Otter, Read AI and Grain, and ClickUp, Monday and Linear connect with an HQ
  sign-in link; Asana needs an access key and comes later.
- Client homes get each client's recent meetings and open projects when those
  tools are connected. The notetaker is linked as the transcripts slot.
- People can start with a few clients; setup creates only those.

## 0.4.12 (2026-10-11)

- Fix: `slack.mjs channels` read only the first page of Slack's channel list
  (38 of 268 channels in one workspace), so most client channels were never
  seen. It now follows every page and reports `total` and `complete`.
- The guide looks for the agency's client-channel naming pattern (a prefix
  or suffix shared by many external channels, like `hqx-`) to find clients.

## 0.4.11 (2026-10-11)

- The setup brief states its purpose: a fast setup with a workspace for each
  client, ready to look through and to run a workflow on. Connecting tools is
  only a way to find clients and fill in their details faster, so the guide
  stops connecting and reading once it has enough.
- Setup ends by leading with the client workspaces and offering to open one
  or run a workflow on a client. The done button is "Show me a client
  workspace".

## 0.4.10 (2026-10-11)

- Slack's channel list is enough for setup: the Agency Guide works out the
  clients from channel names, purposes and channels shared with other
  organizations, groups each client's channels, and lets the person confirm.
  Message history and search are only read if the person asks.
- Each client's Slack channels are recorded in that client's home.
- `slack.mjs channels` reports whether a channel is shared with another
  organization, and its purpose.

## 0.4.9 (2026-10-11)

- Slack connects in one step: the Agency Guide opens Slack's own sign-in page
  (`slack.mjs connect`, through `hq integrations slack connect`) instead of
  sending people to the HQ console's Add Integration dialog, whose popup
  browsers block. HQ still keeps the sign-in in their personal vault.
- When a Slack connection cannot search yet, the guide falls back to the
  channel list and a few channel histories.

## 0.4.8 (2026-10-11)

- Setup learns their tools right after the agency name, asking by kind (docs,
  team chat, CRM) rather than by brand, and reads them before asking about
  the business.
- Buttons: at most four, all of the same kind; never answers mixed with
  connect actions.

## 0.4.7 (2026-10-11)

- The Agency Guide works from a brief, like HQ's own setup bot: what to build
  (agency brain, client brains, connected systems), what good looks like, the
  facts about each tool, and the scripts to run. No scripted messages, fixed
  question order or preset buttons; it adapts to the person.
- Worker rules: buttons only for real choices, never on typed answers or with
  guessed answers; the outdated practice-client job and exact phrasings are
  gone.

## 0.4.6 (2026-10-11)

- `setup.sources` says how each tool connects: Google Drive and Slack through
  the pack's `drive.mjs` and `slack.mjs`; Notion, ClickUp, Monday, Asana,
  Pipedrive, Close and Dropbox through HQ integrations; email, HubSpot,
  Salesforce and Teams marked not available yet. The guide no longer tells
  people Drive or Slack cannot be connected.
- The tools question is answered by typing, with no buttons and no example.

## 0.4.5 (2026-10-11)

- The Slack connect message says where to click (Add, then Slack), since the
  console's Personal Integrations page does not open the Slack form from a link.

## 0.4.4 (2026-10-11)

- Slack connects through HQ's Personal Slack account (the person's own Slack
  sign-in, stored in their personal HQ vault). `scripts/slack.mjs` reads it
  read-only: `status`, `connect-link`, `channels`, `search` (Slack search
  syntax), `history` and `thread`. Only Slack's read methods are allowed, the
  token is read per call and never printed, and rate limits are retried once.
- Setup connects Slack this way and reads search-first, since Slack limits
  history reads for apps outside its Marketplace.

## 0.4.3 (2026-10-11)

- Google Drive connects through Google's own sign-in on the person's Mac
  (`gcloud auth login --enable-gdrive-access`), with no HQ app review needed.
  `scripts/drive.mjs` installs Google's sign-in tool when missing, starts the
  sign-in without blocking the chat, and reads Drive read-only: `status`,
  `recent`, `search` (full text across the whole Drive) and `read` (Docs,
  Sheets, Slides and text as text). It mints a fresh token from the local
  sign-in on every call and only ever sends GET requests.
- Setup connects Google Drive first and does not try to connect email yet.

## 0.4.2 (2026-10-11)

- The tool interview is one question ("Which tools do you use for email, your
  CRM, team chat, docs and SOPs, and projects? For example: ..."), answered in
  one line.
- Sign-in links come from `hq integrations connect --link-only`, which returns
  the link at once; plain `--no-browser` waited for a sign-in the person had
  not been sent and stalled the chat.
- The guide does not narrate its steps; everything it writes is posted.

## 0.4.1 (2026-10-11)

- Setup starts with a short interview about the agency's tools, one tap per
  kind (email, CRM, team chat, docs, project management), then sends a
  sign-in link for each tool picked, one at a time. `setup.sources` lists the
  kinds with their likely tools and the domains HQ connects. Tools are named
  by kind until the person says which one they use. The `tools` topic comes
  from the interview and is no longer asked.

## 0.4.0 (2026-10-11)

- Setup builds three things: an agency brain (playbook plus the agency's own
  SOPs under `knowledge/agency-playbook/sops/`), a brain for each current
  client, and the agency's systems connected. The Agency Guide learns from
  connected apps and documents first (Gmail, Slack, HubSpot, Google Drive),
  proposes answers with their sources, and asks only what is left open.
- Current clients come in during setup: the guide proposes them from CRM
  deals, client Slack channels and email, the person confirms, and
  `scripts/import-clients.sh` creates every client home in one step. The
  guide then fills each `client-profile.md` and `access-and-assets.md` from
  what it read, with sources.
- `scripts/firm-setup.sh` links the client-service slots to the tools the
  agency uses (`--bind crm=HubSpot:cli`) and leaves the rest undecided
  instead of forcing them empty.
- Setup ends with a summary of what was set up and next steps ("Onboard a
  client"). Northwind Labs is offered only when the agency has no clients in
  HQ yet; `setup.run.then` no longer loads it.
- `scripts/practice-setup.sh` and the new scripts pass `--session-company`, so
  they work outside an HQ session.

## 0.3.3 (2026-10-11)

- The Agency Guide learns from connected apps before asking. After the agency
  name it lists the company's usable HQ integrations, offers to read recent
  sent client emails, client Slack channels and HubSpot deals (or to connect
  them), reads with read-only tools after a yes, and proposes answers with
  their sources for the person to confirm. `setup.sources` lists Gmail, Slack
  and HubSpot. It asks only the topics the data left open.
- The done message says Northwind Labs is a made-up practice client and asks
  whether to run its onboarding; the button reads "Run the practice
  onboarding".

## 0.3.2 (2026-10-11)

- Setup is an interview. Each `setup:` question has a `goal`, and the block
  lists `documents` (rate card, recent proposal, case study). The Agency Guide
  follows up once on a vague answer ("variable pricing": what does it vary
  with?), asks early for those documents, reads them, and adds what it found
  to the agency profile. Answers reach the playbook as full sentences.
- `scripts/practice-setup.sh` runs the steps after the playbook in one
  command: the client-service firm setup with every slot empty, Northwind Labs
  recorded, and its documents loaded. Safe to re-run. `setup.run.then` calls
  it, so every step the setup needs is declared in package.yaml.

## 0.3.1 (2026-10-11)

- Declare the client-service dependency as `requires.packs` (name and
  version range), the field hq-cli reads. A marketplace install of the kit
  now installs hq-pack-client-service 0.2.0 or later first; before, the old
  `requires.packages` list was ignored and a slug install skipped it.

## 0.3.0 (2026-10-11)

- The chat door. `package.yaml` gets a `setup:` block (bot `agency-guide`,
  display name "Agency Guide", six questions with suggested answers,
  `run` mapped to `scripts/agency-setup.sh`, then `scripts/practice-client.sh`,
  done message and the "Run Northwind's onboarding" suggestion,
  `takeover_setup: true`). `hq packages install --start-bot` starts the bot.
- New worker `workers/agency-guide/` (contributed under `core/workers/public/`):
  a personal bot that runs the pack setup in the HQ app chat, confirms the
  agency name from the company's display name, writes the playbook, runs the
  client-service firm setup with every slot empty, loads Northwind Labs, and
  runs onboarding step by step with Approve / Needs changes at each gate.
  Approve records the person's name and the date in the file and the status
  table. Skills: `setup`, `onboarding`, `clients` (new client, onboard, scope
  check, weekly update, drafts saved under the client's `reports/`, never
  sent). The worker never asks for a terminal or Claude Code and names every
  file as a Files-tab location.
- New script `scripts/grade-practice.sh`: grades a Northwind run against the
  instructor answer key and reports which of the eight planted issues were
  found; exits non-zero if any is missing. The Guide runs it after the kickoff
  package; `/practice-client` can use it too.
- Tests: the setup block (bot name in `contributes.workers`, unique question
  ids, `run.script`, `then` scripts and `args` flags exist), every worker file,
  the grader against a fixture (passes complete, fails with one issue removed).
- README and welcome describe the chat door; the Claude Code commands stay
  documented as optional.

## 0.2.0 (2026-10-11)

- New skill `/client-workspace` and script `scripts/client-workspace.sh`: one
  workspace layout for every client (`README.md`, `client-profile.md`,
  `access-and-assets.md`, `onboarding/inputs/`, `reports/`), scaffolded from
  `templates/client-workspace/`. Two modes: `folder` (inside the agency
  company) and `company` (the client also gets its own HQ company). Never
  overwrites.
- `/agency-setup` asks for the default client workspace mode and writes it to
  `agency-profile.md` (`--client-mode folder|company`, default folder).
- Partner brand: `brand/BRAND.md` and `brand/tokens.css`, with the rule that
  HQ and its commands are never renamed. Install welcome and README updated.
- Pack now lives in the hq-packages repo under `packages/hq-pack-agency-kit`.
- Tests cover the workspace script (placeholders, modes, keep-on-rerun, dry run,
  missing engagement) and the new playbook field.

Not yet built: members-only distribution, an install page, an
`/agency-tutorial`, a monthly report
skill, a client health check, and service add-on bundles.

## 0.1.0 (2026-10-09)

First version.

- Skills: `/agency-setup`, `/client-onboarding`, `/practice-client`,
  `/scope-check`, `/weekly-update`, `/proposal`.
- Agency playbook templates.
- Northwind Labs practice client with eight planted issues and an answer key.
- Policies: `agency-kit-evidence-before-commitment`, `agency-kit-playbook-learns`.
- Script tests (`tests/run.sh`).
