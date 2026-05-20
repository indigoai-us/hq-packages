---
name: run-bot
description: Run an HQ-issued Slack bot — arm a per-bot @-mention watcher that spawns an autonomous Claude worker per mention. Pass the bot's slug (e.g. `hassaan`), a scope flag (`-c <company-slug>` or `--personal`), and optionally a workspace (`-w <slack-team-domain>`; auto-derived for `--personal` from SLACK_CREDENTIALS_JSON). The watcher resolves `HQ_SLACK_BOT_TOKEN_<NAME>_<WORKSPACE>` from the chosen vault, infers the creator's Slack user_id (used as a DM gate), enumerates the bot's channels (periodically re-polled so newly-added channels start polling automatically), and dispatches workers. Workers respond in-thread, ignore DMs from non-creators, and never call AskUserQuestion.
allowed-tools: Bash, Read, Monitor, TaskStop
---

# Run Bot (hq-pack-slack-bot)

A bot-mention watcher modeled on `monitor-liveops` but parameterized per
bot. Companion package: `hq-pack-slack-bot` (source of truth:
[indigoai-us/hq-packages](https://github.com/indigoai-us/hq-packages)/packages/hq-pack-slack-bot).
See the package README for layout, fork guide, and operational notes.

## When to invoke

Trigger phrases:

- "run <bot>"
- "run slack bot <bot>"
- "monitor mentions of <bot>"
- "watch @mentions of <bot>"
- "spin up bot watcher for <bot>"

Required arguments:

- The bot's **slug** (the lowercase-dashed name the bot was created with
  via `/hq-new-bot`).
- A **vault scope** — either `-c <company-slug>` or `--personal`. (Use
  `-c personal` as an alias for `--personal` if you want a single flag
  style.)
- A **workspace** — the Slack `team_domain` the bot is installed in
  (e.g. `indigo-ai`). Optional `-w <workspace>` flag; in `--personal`
  scope the watcher auto-derives it from `SLACK_CREDENTIALS_JSON` in
  the personal vault.

The slug + workspace + scope resolve to a vault entry named
`HQ_SLACK_BOT_TOKEN_<NAME>_<WORKSPACE>` (dashes → underscores, same
convention as the slack-app-factory in hq-pro). The workspace
component lets the same bot slug live in multiple workspaces without
colliding on vault keys.

Examples:

| Args | Vault secret read |
|------|-------------------|
| `hassaan --personal` | personal vault → `HQ_SLACK_BOT_TOKEN_HASSAAN_INDIGO_AI` (workspace auto-derived) |
| `support-bot -c indigo -w indigo-ai` | indigo company vault → `HQ_SLACK_BOT_TOKEN_SUPPORT_BOT_INDIGO_AI` |
| `my-cool-bot -c personal -w acme-co` | personal vault (alias) → `HQ_SLACK_BOT_TOKEN_MY_COOL_BOT_ACME_CO` |

## Procedure

1. **Sanity check.** Confirm the named bot has a token in the chosen
   vault and resolves to a usable Slack identity:

   ```bash
   bash core/packages/hq-pack-slack-bot/scripts/watch.sh \
     <bot-slug> { -c <company> | --personal } [-w <workspace>] --check
   ```

   `--check` runs the startup pre-flight (workspace resolution, token
   load, auth.test, users.conversations sample call, creator inference)
   and exits 0 if everything is wired, non-zero with a clear error
   otherwise. The output lines `workspace:` and `creator:` tell you
   what the watcher resolved and where from. Always run `--check`
   before arming — it's cheap to iterate on.

2. **Arm the watcher** via the `Monitor` tool:

   ```
   Monitor(
     command="bash core/packages/hq-pack-slack-bot/scripts/watch.sh <bot-slug> { -c <company> | --personal } [-w <workspace>]",
     description="@-mention watcher for <bot-slug> + worker spawner",
     persistent=true,
     timeout_ms=3600000
   )
   ```

   Events you'll receive on stdout:

   - `WATCHER_ARMED bot=<slug> workspace=<slug> scope=<…> user_id=<U…> channels=<N> creator=<U…|<none>> creator_src=<…> hash=<sha12>` — startup
   - `MENTION channel=<C…|D…|G…> ts=<ts> thread_ts=<ts> user=<U…> text=<first 200 chars> [(thread-reply)]` — every new @-mention. The `(thread-reply)` suffix means the mention was found in a thread REPLY (not the parent), via the watcher's per-thread polling pass. Dedupe is keyed on `thread_ts`, not `ts`, so each thread spawns at most one worker.
   - `SPAWN agent=mention:<ts> channel=<…> thread_ts=<…> log=<path> pid=<pid>` — worker dispatched
   - `SPAWN_FAILED ts=<ts> reason=<…>` — worker dispatch failed
   - `API_ERROR <slack-error>` — polling failed (e.g. invalid_auth). For thread-poll errors the prefix is `API_ERROR thread:<error>` and includes `thread_ts=`.
   - `CHANNEL_JOINED channel=<C…>` — bot was added to a new channel
     (emitted on the next channel-refresh tick)
   - `CHANNEL_LEFT channel=<C…>` — bot was removed from a channel
   - `CHANNELS_REFRESHED count=<N> (was <M>)` — count actually changed
   - `LEFT_CHANNEL channel=<C…> reason=creator_absent` — the creator is no longer a member of this channel, so the bot left it. Per-channel state (cursor, thread cursors, membership sentinel) is cleaned up so a re-invite starts fresh.
   - `LEAVE_FAILED channel=<C…> error=<slack-error>` — `conversations.leave` rejected the call (most commonly `missing_scope` if `channels:leave`/`groups:leave`/`mpim:leave` haven't been added). The channel is KEPT in the polling set so mentions still flow; add the scope and the next tick will succeed.
   - `RECOVERED [users.conversations|conversations.members]` — after a previously-emitted `API_ERROR` cleared

3. **Do not narrate every event back to the user verbatim.** The worker
   is the user-facing actor (it posts in Slack). Tell the user once
   that workers are firing, only re-surface specific events on
   `SPAWN_FAILED` / `API_ERROR`.

4. **Stop the watcher** when the user says stop / kill monitor:

   ```
   TaskStop(task_id="<watcher-task-id>")
   ```

   In-flight workers keep running until their own exit conditions fire
   (idle / resolved keyword / time cap / DM-non-creator). To kill those
   too:

   ```bash
   pkill -f 'claude-worker.sh -n mention:'
   ```

   Ask the user first.

## Rules

- **First-arm cursor init is "now".** Backfilling the bot's entire
  history would spawn workers on long-resolved conversations across
  every channel it already belongs to.
- **Mid-run channel joins backfill `MENTION_BACKFILL_SECS` (default
  600s).** When the bot is invited to a new channel after arm, the
  refresh tick initializes that channel's cursor to `(now - 600s)`,
  not `now`, so @-mentions that landed in the invite → refresh gap
  get picked up on the next poll. Spawn-dedupe ensures no double
  reply.
- **Spawn dedupe is per-thread, not per-message.** Sentinel lives at
  `$SPAWN_DIR/<thread_ts>.spawned`. The first @-mention in a thread
  starts a worker; if the human @-mentions the bot again later in the
  same thread, the watcher does NOT spawn another worker — the
  in-flight worker sees it as a normal `REPLY` event from its
  `poll-thread.py` loop and responds in-place.
- **Thread reply polling is automatic.** For every top-level message
  with `reply_count > 0` that hasn't been spawned-for, the watcher
  schedules per-thread polling via `conversations.replies`. State
  lives in `/tmp/hq-slack-bot.<slug>.threads/<channel>:<thread_ts>`.
  Stale threads are GC'd after `MENTION_THREAD_GC_SECS` (default 24h).
- **Creator-presence enforcement.** Every channel-refresh tick, the
  watcher confirms the creator (`creator:` field in `--check` output)
  is still a member of each non-DM channel via `conversations.members`.
  If absent, the bot leaves the channel via `conversations.leave`. The
  check is cached for `MENTION_MEMBERSHIP_CHECK_SECS` (default 300s) to
  cap API calls. DMs are always kept (the bot can't leave an IM and the
  worker-side DM gate already silences non-creator DMs). Disable by
  setting `MENTION_LEAVE_ON_CREATOR_ABSENT=0` — the watcher will still
  log who's missing, just won't leave. Required scopes are listed under
  Dependencies; without them the watcher emits `LEAVE_FAILED` once per
  channel per tick.
- **Never** spawn more than one worker per `ts`. The watcher dedupes
  via `/tmp/hq-slack-bot.<bot-slug>.spawned/<ts>` sentinels.
- **Never** include `AskUserQuestion` in the worker's allowed tools.
  Denied via both settings and system prompt — same belt-and-suspenders
  pattern as monitor-liveops.
- If the bot token is missing from the chosen vault, abort with a
  clear error — do not poll without auth.
- The DM gate is enforced inside the worker, not the watcher. The
  watcher emits a `MENTION` event for every match; the worker decides
  whether to actually post.

## Creator inference (DM gate)

The bot answers DM @-mentions ONLY from its creator. The watcher
resolves the creator's Slack user_id in this order:

1. Companion vault secret
   `HQ_SLACK_BOT_CREATOR_<NAME>_<WORKSPACE>` in the chosen scope.
   Written by hq-pro's install-callback at OAuth-completion time.
2. `--personal` scope fallback: `SLACK_CREDENTIALS_JSON` in the
   personal vault has a stable baked-in `user_id` field (the vault
   owner). Watcher parses that.
3. If neither resolves: no DM gate is active. The worker ignores ALL
   DM @-mentions and only responds in channels. Channel mentions are
   unaffected regardless.

The `--check` output reports which source (if any) supplied the
creator id, so you can confirm before arming.

## Dependencies

- Vault secret `HQ_SLACK_BOT_TOKEN_<NAME>_<WORKSPACE>` (xoxb-, with
  at minimum `channels:history`, `channels:read`, `chat:write`,
  `groups:history`, `groups:read`, `im:history`, `im:read`,
  `mpim:history`, `mpim:read`, `users:read`, `users:read.email`, and
  `app_mentions:read`). For creator-presence enforcement (auto-leave
  when the creator is absent), the bot ALSO needs `channels:leave`,
  `groups:leave`, and `mpim:leave` — without these scopes the watcher
  surfaces a `LEAVE_FAILED error=missing_scope` event each tick and
  the channel stays in the polling set. Created by `/hq-new-bot` and
  installed
  per-workspace via the OAuth callback.
- `hq` CLI on PATH.
- `claude` CLI on PATH. The pack vendors its own worker dispatcher
  (`scripts/claude-worker.sh` + `scripts/claude-pty-spawn.py` +
  `scripts/claude-worker-template.sh`) so no `personal/tools/` or
  `personal/workers/` symlinks are required — Claude Code is the
  only external runtime expected.
- `curl`, `jq`, `awk`, `python3`.

If the vault token comes from an app created via `/hq-new-bot`, the
bot already has all the required scopes — that's the canonical
Hassaan's-Assistant scope set.

## Forking

To build a per-bot specialized variant (e.g. a worker that does
something specific to your domain instead of the generic
acknowledgement), copy the pack inside hq-packages:

```bash
cp -r packages/hq-pack-slack-bot packages/hq-pack-<new-name>
# edit package.yaml + package.json to rename, then
# edit workers/slack-mention-worker/system-prompt.md
```

The watcher script rarely needs to change between forks — the variation
typically lives entirely in `workers/<name>/system-prompt.md`.
