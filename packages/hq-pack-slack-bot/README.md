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
│   └── parse-mentions.py                  ← strict=False JSON parse + @-mention filter
└── workers/
    └── slack-mention-worker/
        ├── meta.yaml
        ├── settings.json                  ← AskUserQuestion denied
        ├── schema.json                    ← JSON envelope for final message
        └── system-prompt.md               ← worker behavior contract
```

## Watcher CLI

```
bash core/packages/hq-pack-slack-bot/scripts/watch.sh \
  <bot-slug> { -c <company-slug> | --personal } [-w <workspace>] [--check]
```

| Arg | What it does |
|-----|--------------|
| `<bot-slug>` | Lowercase-dashed bot name (e.g. `hassaan`). Combined with workspace to resolve vault secret `HQ_SLACK_BOT_TOKEN_<NAME>_<WORKSPACE>`. |
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
8. Calls `claude-worker-template.sh -t slack-mention-worker` with
   per-spawn `--var` substitutions (channel, thread_ts, mention text,
   reporter, bot identity, creator id, scope flags). Worker is
   detached via `nohup ... &`.

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

## Creator inference (DM gate)

The bot is a personal/company identity surface; it must not respond to
DMs from arbitrary users. The watcher tries to infer the creator's
Slack user_id at startup, in this order:

1. Companion vault secret `HQ_SLACK_BOT_CREATOR_<NAME>_<WORKSPACE>`
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
- The watcher initializes channel cursors to `now` — backfilling old
  `@`-mentions would spawn workers on conversations that have long
  since resolved.
- The channel list is re-polled periodically (set diff, not just
  count) — newly-added channels start polling automatically with no
  restart.

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
