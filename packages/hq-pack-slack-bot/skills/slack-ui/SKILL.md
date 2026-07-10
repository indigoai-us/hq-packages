---
name: slack-ui
description: Post structured Slack status messages via Block Kit using the pack's slack-ui.sh helper (header, body, fields, context). Prefer this over raw chat.postMessage curl for short inline replies and status updates. Supports dry-run payloads, plain-text fallback, and auto-split for Slack block limits.
---

# slack-ui (hq-pack-slack-bot)

Structured **status / short-answer** posts for Slack bots in this pack.
Builds valid [Block Kit](https://api.slack.com/block-kit) `chat.postMessage`
payloads from typed flags so workers never hand-roll JSON that 400s.

**Source of truth:** `packages/hq-pack-slack-bot/scripts/slack-ui.sh`
(installed as `scripts/slack-ui.sh` relative to the pack / HQ scripts tree).

> **Scope note:** this skill covers the `post` subcommand only.
> `ask` (interactive prompts) and `report` (richer multi-section reports)
> are **future stories** — do not invent those subcommands yet.

## When to use

- Short inline replies and structured status updates in a thread
- Deploy/job status with a title, a few labeled fields, and context footnotes
- Any time you would otherwise curl `chat.postMessage` with a hand-built
  `blocks` array for a simple status message

Prefer `slack-ui.sh post` over raw `curl` + `jq`. Keep raw `chat.postMessage`
curl only as a **fallback** when the helper script is unavailable.

## Command

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

## Example

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

Dry-run (inspect payload, no API call):

```bash
bash scripts/slack-ui.sh post \
  --title "Ping" \
  --body "still here" \
  --field "Status|ok" \
  --channel C01234567 \
  --dry-run
```

Plain-text only:

```bash
bash scripts/slack-ui.sh post \
  --title "Ping" \
  --body "still here" \
  --channel C01234567 \
  --text-only \
  --dry-run
```

## Offline tests

```bash
bash packages/hq-pack-slack-bot/scripts/tests/test-slack-ui.sh
```

## Message body rules (worker context)

When used from `slack-mention-worker`, the title/body/fields/context must
still be **user-facing answer content only** — never status/wrapper meta
like “Replied in the Slack thread.” Those belong in the worker’s JSON
envelope, not in Slack.

## Future

- `ask` — interactive / confirmation patterns (not implemented)
- `report` — multi-section report layouts (not implemented)
