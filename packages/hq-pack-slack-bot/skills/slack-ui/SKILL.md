---
name: slack-ui
description: Post structured Slack status messages via Block Kit using the pack's slack-ui.sh helper (header, body, fields, context). Prefer this over raw chat.postMessage curl for short inline replies and status updates. Supports dry-run payloads, plain-text fallback, auto-split for Slack block limits, canvas reports, and interactive decision asks with timeout/fallback.
---

# slack-ui (hq-pack-slack-bot)

Structured **status / short-answer / decision** posts for Slack bots in this pack.
Builds valid [Block Kit](https://api.slack.com/block-kit) payloads from typed
flags so workers never hand-roll JSON that 400s.

**Source of truth:** `packages/hq-pack-slack-bot/scripts/slack-ui.sh`
(installed as `scripts/slack-ui.sh` relative to the pack / HQ scripts tree).

Subcommands:

| Command | Purpose |
|---------|---------|
| `post` | Short status / answer (header, body, fields, context) |
| `report` | Canvas report + in-thread TL;DR (auto-fallback to link) |
| `ask` | Interactive decision (buttons / multi-select) + pending state |
| `resolve` | Turn a decision message into an audit line (usually watcher-driven) |

## When to use

- Short inline replies and structured status updates in a thread → `post`
- Longer durable write-ups → `report` (canvas) with `/deploy` fallback
- Need a human to pick among options before continuing → `ask`
- Any time you would otherwise curl `chat.postMessage` with a hand-built
  `blocks` array for a simple status message

Prefer `slack-ui.sh` over raw `curl` + `jq`. Keep raw `chat.postMessage`
curl only as a **fallback** when the helper script is unavailable.

## post

```bash
bash <pack-or-scripts-root>/slack-ui.sh post [options]
```

Typical pack paths after install:

- `core/packages/hq-pack-slack-bot/scripts/slack-ui.sh`
- `{{HQ_ROOT}}/core/packages/hq-pack-slack-bot/scripts/slack-ui.sh`

### Flags

| Flag | Repeatable | Description |
|------|------------|-------------|
| `--title <text>` | no | Header block (`plain_text`). Truncated to **150** chars (Slack header limit). |
| `--body <text>` | no | Section block (`mrkdwn`). Auto-splits at **3000** chars. |
| `--field "Label\|Value"` | yes (max **4**) | One section with a `fields` array of mrkdwn `*Label*\nValue` items. Errors if more than 4. |
| `--context <text>` | yes | One context block; each flag becomes one mrkdwn element. |
| `--channel <id>` | no | Target channel. **Required when sending** (not required for dry-run). |
| `--thread <ts>` | no | Optional `thread_ts` for in-thread replies. |
| `--text-only` | no | Emit/send only top-level `text` (no `blocks`). Text composed from title/body/fields/context. |
| `--dry-run` | no | Print final JSON payload(s) to stdout; **do not** call the Slack API. |
| `-h`, `--help` | no | Document all flags and limit behavior. |

### Limit behavior (hard — never produces a 400 payload)

- **Header:** truncated to 150 characters.
- **Body sections:** any mrkdwn section text longer than 3000 characters is
  split into multiple section blocks. Each subsequent chunk is prefixed with
  `(continued) `. Every section text is ≤3000 chars.
- **>50 blocks:** if the assembled block list would exceed Slack’s 50-block
  cap, the helper splits into **multiple** `chat.postMessage` payloads.
  Later messages reuse `channel` / `thread_ts` and mark their first block
  with `(continued)`.
- **Top-level `text`:** always set to a plain-text fallback summary
  (notifications / accessibility). With `--text-only`, that is the only
  content (no `blocks` key).
- **Fields:** max 4 pairs; clear error otherwise.

### Sending vs dry-run

- `--dry-run` — print one JSON object per message (one per line if split).
  Tests and agents use this to inspect payloads offline.
- Without `--dry-run` — `curl` `https://slack.com/api/chat.postMessage`.
  Token from `$SLACK_BOT_TOKEN` or `$HQ_SLACK_BOT_TOKEN` (never hardcode).

### Example

```bash
BOT_TOKEN="$(cat /tmp/bot-token.$MENTION_TS)"
export SLACK_BOT_TOKEN="$BOT_TOKEN"

bash "{{HQ_ROOT}}/core/packages/hq-pack-slack-bot/scripts/slack-ui.sh" post \
  --title "Deploy complete" \
  --body "web-front preview is live." \
  --field "Env|preview" \
  --field "SHA|abc1234" \
  --context "triggered by CI" \
  --channel "{{CHANNEL}}" \
  --thread "{{THREAD_TS}}"
```

## ask (decisions)

Interactive decisions for human-in-the-loop workflows. Posts buttons
(≤3 options) or a multi-select (`--multi` / >3 options), registers a
pending decision with timeout + declared fallback, and writes local state
under `${HQ_DECISIONS_DIR:-$HOME/.hq/slack-decisions}/<decision_id>.json`.

### Lifecycle

1. **ask** — worker posts the interactive message and registers the pending
   decision (`decision_id`, options, `expires_at`, `fallback`, channel,
   thread, `message_ts`).
2. **Answer** — human either:
   - taps a button / confirms multi-select (HQ API records the answer; the
     watcher polls and resolves), **or**
   - posts a threaded free-text reply that **exact-matches** an option
     value or label (case-insensitive, trimmed; no substring matches).
3. **Audit line** — watcher calls `resolve`: `chat.update` replaces the
   message with a short audit line (answered or timed-out). **No live
   actions blocks remain.** Never re-post live buttons for an answered
   decision.
4. **Dispatch** — watcher spawns a **fresh** worker for the same
   channel/thread with `DECISION_ID`, `DECISION_QUESTION`,
   `DECISION_ANSWER_VALUE`, `DECISION_ANSWER_LABEL`, `DECISION_USER`,
   `DECISION_CHANNEL`, `DECISION_THREAD_TS` set. At startup, if
   `DECISION_ID` is set, treat the run as decision resumption.
5. **Expiry** — if nobody answers before `--timeout`, the watcher fires
   the declared `--fallback`, the message says so (“fallback applied”),
   and dispatch still runs with that value.

### Flags (ask)

| Flag | Description |
|------|-------------|
| `--question <text>` | Required. Decision question. |
| `--option "value\|Label"` | Repeatable; ≥2 required. |
| `--recommend <value>` | Primary button style. |
| `--abort <value>` | Danger button style. |
| `--fallback <value>` | **Required.** Must be one of the option values (timeout path). |
| `--timeout <secs>` | **Required.** Positive integer expiry window. |
| `--channel` / `--thread` | Target thread. |
| `--multi` | Force multi_static_select even with ≤3 options. |
| `--decision-id` / `--state-dir` | Override id / pending dir. |
| `--dry-run` | Print register + postMessage JSON; still writes pending file. |

### Example

```bash
bash scripts/slack-ui.sh ask \
  --question "Ship to prod?" \
  --option "ship|Ship it" \
  --option "hold|Hold" \
  --option "abort|Abort" \
  --recommend ship \
  --abort abort \
  --fallback hold \
  --timeout 600 \
  --channel "{{CHANNEL}}" \
  --thread "{{THREAD_TS}}"
```

### Modals deferred: no `views.open` in v1

**HARD RULE:** modals / `views.open` are a **v1 non-goal**. Never open
Slack modals for decisions. Use buttons, multi-select, or free-text
option replies only. `resolve` is normally driven by the watcher
(`watch.sh`); workers should not re-post interactive components after
an answer.

## Offline tests

```bash
bash packages/hq-pack-slack-bot/scripts/tests/test-slack-ui.sh
bash packages/hq-pack-slack-bot/scripts/tests/test-decisions.sh
```

## Message body rules (worker context)

When used from `slack-mention-worker`, the title/body/fields/context must
still be **user-facing answer content only** — never status/wrapper meta
like “Replied in the Slack thread.” Those belong in the worker’s JSON
envelope, not in Slack.
