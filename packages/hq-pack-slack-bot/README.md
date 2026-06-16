# hq-pack-slack-bot

Per-bot Slack mention watcher + spawned-worker template. Watches every
channel a chosen HQ-issued Slack bot is a member of, and dispatches one
autonomous Claude worker per `@-mention`. Pairs with the
`/hq-new-bot` slash command shipped by [hq-pro][hq-pro]'s
slack-app-factory.

[hq-pro]: https://github.com/indigoai-us/hq-pro

## Quick start

After installing the pack and creating a bot via `/hq-new-bot`, run:

```
/run-bot <bot-slug> --personal               # personal vault; workspace auto-derived
/run-bot <bot-slug> -c <company> -w <ws>     # company vault; workspace explicit
```

(Slash form depends on host: master-sync exposes packs as
`<pack>:<skill>`, so the canonical form is `/hq-pack-slack-bot:run-bot`.)

The skill arms a `Monitor`-bound bash watcher. Every `@`-mention of the
bot across every channel it's a member of fires `SPAWN
agent=mention:<ts>` on the event stream and detaches a worker per
mention. Workers respond in-thread, ignore DMs from anyone other than
the bot's creator, and never call `AskUserQuestion`.

## Layout

```
packages/hq-pack-slack-bot/
├── README.md                              ← you are here
├── package.yaml                           ← HQ pack manifest
├── package.json                           ← npm-side manifest
├── skills/
│   └── run-bot/
│       └── SKILL.md                       ← the /run-bot skill
├── scripts/
│   ├── watch.sh                           ← bash watcher loop
│   ├── parse-mentions.py                  ← strict=False JSON parse + @-mention filter
│   ├── poll-thread.py                     ← in-thread reply polling helper
│   ├── claude-worker-template.sh          ← vendored: var-substitute + dispatch
│   ├── claude-worker.sh                   ← vendored: Claude SDK + Remote Control + Stop hook
│   └── claude-pty-spawn.py                ← vendored: pty wrapper for the claude CLI
└── workers/
    └── slack-mention-worker/
        ├── meta.yaml
        ├── settings.json                  ← AskUserQuestion denied
        ├── schema.json                    ← JSON envelope for final message
        └── system-prompt.md               ← worker behavior contract
```

The `scripts/claude-*` files are vendored from `personal/tools/` so the
pack is self-contained — installing it gives you a complete
@-mention-watcher + worker-spawner with no `personal/` or HQ-core
script dependencies beyond the `claude` CLI itself.

## Watcher CLI

```
bash core/packages/hq-pack-slack-bot/scripts/watch.sh \
  <bot-slug> { -c <company-slug> | --personal } [-w <workspace>] [-u <prs_personUid>] [--check]
```

| Arg | What it does |
|-----|--------------|
| `<bot-slug>` | Lowercase-dashed bot name (e.g. `hassaan`). Combined with workspace + personUid to resolve vault secret `<personUid>/HQ_SLACK_BOT_TOKEN_<NAME>_<WORKSPACE>`. |
| `-u <prs_personUid>` | Override for the auto-derived operator personUid. Optional — by default the watcher reads it from `~/.hq/secrets-cache/prs_*/` (the dir name IS the personUid; created by `hq` on first personal-vault touch). Pass `-u` only when running someone else's bot in a shared company vault, or on a machine where the cache directory doesn't exist yet. |
| `-c <company-slug>` | Pull the token from that company's HQ vault. `-c personal` is an alias for `--personal`. |
| `--personal` | Pull the token from the operator's personal vault. |
| `-w <workspace>` | Slack `team_domain` the bot is installed in (e.g. `indigo-ai`). Required for company scope; optional for `--personal` (auto-derived from `SLACK_CREDENTIALS_JSON.team_domain`). |
| `--check` | Run startup pre-flight only and exit 0 (workspace + token load, auth.test, channels sample call, creator inference). |

## What the watcher does

1. Resolves `<bot-slug>` + scope + workspace → vault → token, token →
   bot user_id via `auth.test`.
2. Infers the bot's *creator* (used as a DM gate downstream — see
   below).
3. Calls `users.conversations` to enumerate every channel the bot is a
   member of (public + private + DMs + MPIMs, paginated).
4. Polls each channel's `conversations.history` since a per-channel
   cursor.
5. Filters for messages whose `text` contains `<@BOT_USER_ID>` — that's
   how Slack renders `@`-mentions over the wire.
6. Re-polls `users.conversations` on a cadence (default 300s) and
   compares the result as a *set* against the prior list. Newly-added
   channels get a `now` cursor and start polling immediately; emits
   `CHANNEL_JOINED` / `CHANNEL_LEFT` / `CHANNELS_REFRESHED` events.
7. Dedupes against `/tmp/hq-slack-bot.<bot-slug>.spawned/<ts>` so
   restarts inside the same session don't re-spawn.
8. **Workspace-wide search backstop.** Periodically (default 30s) calls
   `search.messages` for the literal `<@BOT_USER_ID>` token and dispatches
   workers for any newly-indexed hits not already spawned. This catches
   in-thread @-mentions in threads the channel + thread pollers never
   tracked — typically when the thread's parent message predates arm
   time and so never appears in `conversations.history`. Requires the
   granular `search:read.public` / `search:read.private` /
   `search:read.im` / `search:read.mpim` scopes; bots created via
   `/hq-new-bot` after 2026-05 ship with them. If the bot was installed
   without them, `search.messages` returns `missing_scope` and the
   watcher emits `SEARCH_DISABLED` once then skips for the lifetime of
   the watcher (re-install the bot to enable). Disable entirely with
   `MENTION_SEARCH_POLL_ENABLE=0`.
9. Calls the vendored
   `scripts/claude-worker-template.sh -t slack-mention-worker` with
   per-spawn `--var` substitutions (channel, thread_ts, mention text,
   reporter, bot identity, creator id, scope flags). The runner pulls
   the worker template from `workers/slack-mention-worker/` inside
   the pack and hands off to the vendored `scripts/claude-worker.sh`.
   Worker is detached via `nohup ... &`.

## What the worker does

The worker (`slack-mention-worker`) is a starting-point template you
will likely customize per use case. Out of the box it:

1. **Checks the DM gate first.** If the `@`-mention came from a DM
   channel and the reporter is not the inferred creator, exits
   silently with `status=exited-resolved`,
   `exit_reason=dm-non-creator`, no Slack posts.
2. Loads the bot token via `hq secrets {{SCOPE_FLAGS}} get --reveal`.
3. Reads the mentioning message + the thread context if any.
4. Acknowledges the mention by posting `chat.postMessage` in the
   thread (replace the body with whatever real behavior you want).
5. Polls the thread for follow-up replies for ≤ 30 min idle and
   responds in-thread.
6. Exits on idle / resolved keyword / 60-minute hard cap.
7. Emits the JSON envelope required by the Stop hook before exit.

`workers/slack-mention-worker/system-prompt.md` is the easiest place
to teach the worker something domain-specific — keep the interaction
protocol + JSON envelope + DM gate intact, replace the placeholder
"what to do" section.

## Credential handling & injection posture (governed)

This pack is conformant with the HQ governing policy
`indigo-agent-scoped-credential-handling-and-injection-posture`
(`companies/indigo/policies/`, enforcement: **hard**) — it is brought
into conformance, not granted a carve-out. The contract:

- **Vault is the sole source.** The bot token is resolved ONLY from the
  HQ vault via `hq secrets <scope> get --reveal
  <personUid>/HQ_SLACK_BOT_TOKEN_<NAME>_<WORKSPACE>`. The token is never
  hardcoded, inlined, read from 1Password, or trusted from a pre-set
  env var (a pre-set `BOT_TOKEN` / `SLACK_*_TOKEN` is a stale leftover —
  always re-fetch from the vault path you were handed).
- **Token is a capability — never expose the plaintext.** The watcher
  hands the worker the secret *name* + scope flags, never the value; the
  worker re-resolves from the vault and caches to a `umask 077` per-run
  tmpfile. The token value is never echoed to stdout, logs, code, tests,
  or audit summaries — only its name and length. The detect-secrets hook
  blocks raw `xoxb-…` in commands; do not route around it.
- **Per-entity identity.** Each bot is its own per-entity Slack app with
  its own scoped token; the watcher never falls back to another entity's
  credential.
- **Verify identity before acting.** The watcher runs `auth.test` to
  bind the token to its real `bot_user_id` before arming.
- **Scoped client-held credential, not a broker endpoint.** Capability
  is driven through the agent's own CLI/tools; no per-capability backend
  route. Blast radius is bounded by per-entity scope + membership/DM
  gating + short-lived materialization (with rotation + audit owned by
  the `agent-slack-capabilities` sibling stories), not by stripping
  capabilities.

## Creator inference (DM gate)

The bot is a personal/company identity surface; it must not respond to
DMs from arbitrary users. The watcher tries to infer the creator's
Slack user_id at startup, in this order:

1. Companion vault secret `<personUid>/HQ_SLACK_BOT_CREATOR_<NAME>_<WORKSPACE>`
   in the same vault scope as the token. Written by hq-pro's
   install-callback at OAuth-completion time.
2. `--personal` scope only: parse `SLACK_CREDENTIALS_JSON.user_id` in
   the personal vault. That snapshot has a stable baked-in user_id =
   the vault owner.
3. If neither resolves: no DM gate — the worker ignores ALL DM
   `@`-mentions and only responds in channels.

The `--check` output reports both the resolved creator id and the
source it came from, so you can confirm before arming.

## Operational notes

- Slack `users.conversations?types=public_channel,private_channel,im,mpim`
  is paginated; the watcher follows `response_metadata.next_cursor`
  until exhausted before each poll.
- Per-channel `oldest=` cursors are maintained in
  `/tmp/hq-slack-bot.<bot-slug>.cursors/<channel_id>`, so the watcher
  only re-fetches new messages per channel.
- On first arm, the watcher initializes existing channel cursors to
  `now` — backfilling the bot's entire history would spawn workers on
  long-resolved conversations across every channel it already belongs
  to.
- The channel list is re-polled every `MENTION_CHANNEL_REFRESH_SECS`
  (default `60s`, set diff not just count) — newly-added channels
  start polling automatically with no restart.
- For channels joined MID-RUN, the cursor is initialized to
  `(now - MENTION_BACKFILL_SECS)` (default `600s`) rather than `now`,
  so `@`-mentions that landed in the gap between the bot being
  invited and the next refresh tick get picked up on the very next
  poll.
- **Thread polling.** `conversations.history` only returns top-level
  messages, so the watcher additionally polls `conversations.replies`
  for any top-level message it sees with `reply_count > 0` that
  doesn't already have a worker spawned for it. Per-thread reply
  cursors live in `/tmp/hq-slack-bot.<bot-slug>.threads/<channel>:<thread_ts>`.
  Stale threads (`MENTION_THREAD_GC_SECS`, default 24h) are GC'd to
  bound state; per-tick poll cap is `MENTION_THREAD_POLL_CAP`
  (default 50).
- **One worker per thread.** Spawn dedupe is keyed on `thread_ts`,
  not the individual message ts: `$SPAWN_DIR/<thread_ts>.spawned`.
  The first @-mention in a thread (parent OR a reply, whichever lands
  first) starts the worker; subsequent @-mentions in the same thread
  are handled by the in-flight worker's own `poll-thread.py` loop and
  do NOT spawn another instance.
- **Creator-presence enforcement.** Every channel-refresh tick, the
  watcher confirms the creator is still a member of each non-DM
  channel via `conversations.members`. If absent, the bot leaves the
  channel via `conversations.leave` — the bot represents the
  creator's identity and shouldn't operate in rooms they've left or
  were never in. The check is cached for `MENTION_MEMBERSHIP_CHECK_SECS`
  (default `300s`) to bound API calls. Sentinel files live under
  `/tmp/hq-slack-bot.<slug>.membership/<channel>` (mtime = last
  successful check). DMs are skipped (bot can't leave an IM and the
  worker-side DM gate already covers non-creator DMs). Set
  `MENTION_LEAVE_ON_CREATOR_ABSENT=0` to disable leaving (events
  still fire, just without the side-effect). Required Slack scopes:
  `channels:leave`, `groups:leave`, `mpim:leave` — without them, the
  watcher surfaces `LEAVE_FAILED ... error=missing_scope` events and
  keeps the channel in the polling set.

## Forking guide

To build a per-bot specialized package, copy this directory:

```
cp -r packages/hq-pack-slack-bot packages/hq-pack-<new-name>
```

Then edit:

- `package.yaml` + `package.json` — rename `hq-pack-slack-bot` →
  `hq-pack-<new-name>`
- `skills/run-bot/SKILL.md` — keep or rename the trigger
- `workers/slack-mention-worker/system-prompt.md` — replace behavior
- `scripts/watch.sh` — usually unchanged
