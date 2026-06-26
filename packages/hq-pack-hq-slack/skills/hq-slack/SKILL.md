---
name: hq-slack
description: >-
  Post, read, reply, DM, search, and upload to Slack from the CLI — acting AS
  the owner via their own Slack app's user token (xoxp-, no MCP). Use whenever
  the user asks to send/post a Slack message, drop a note in a channel (e.g.
  "#general"), reply in a thread, DM someone, read recent messages, or search
  Slack. MCP-free and durable. First-time setup creates the user's own
  full-access Slack app — see the bundled guide.
---

# hq-slack — MCP-free Slack messaging (your own Slack app)

Slack's Web API is plain HTTPS, so a token + a little Python handles
post/read/reply/search reliably — no MCP needed. This skill wraps
`scripts/hq-slack.sh`, which acts **as the owner** using their own Slack app's
`xoxp-` user token (read/post/reply on their behalf).

**Script (after install):** `core/packages/hq-pack-hq-slack/scripts/hq-slack.sh`
**Setup guide:** `core/knowledge/hq-slack/create-your-slack-app.md`
(in this pack's source: `knowledge/hq-slack/`)

## First-time setup (required once per workspace)

Before any messaging works, the owner must create their **own** Slack app, install
it with full user scopes, and store the resulting `xoxp-` token in the HQ vault.
Walk them through [`create-your-slack-app.md`](../../knowledge/hq-slack/create-your-slack-app.md):

1. Create a Slack app from the bundled `manifest.full-access.json` (full user scopes).
2. Install it to their workspace and copy the **User OAuth Token** (`xoxp-…`).
3. Store it: `printf '%s' '<token>' | hq secrets --personal set SLACK_TOKEN_DEFAULT_USER --from-stdin`.

If a command returns "no Slack token for workspace …", route the user to that guide.

## When to use

Route here for any of: "post to Slack", "send a note in #channel", "message the
team", "reply to that thread", "DM <person>", "what's in #general", "search Slack
for X". This CLI is the canonical path for owner-level Slack messaging.

## How it works (security)

- The per-workspace **user token** (`SLACK_TOKEN_<WS>_USER`, `xoxp-`) is read
  from the HQ vault (`hq secrets --personal`), or a local `.mcp.json` as a
  legacy fallback. The token is **never printed, never passed on the command
  line, never committed** — it's loaded into an env var inside the script and
  sent only as the `Authorization` header.
- Acts as the signed-in user (so posts show as them, and reads see every channel
  they're a member of — including private ones).
- Workspace defaults to `default`; pass `--ws <slug>` (or `HQ_SLACK_WS=<slug>`)
  to switch. Token store override: `HQ_SLACK_MCP_JSON=/path/to/.mcp.json`.

## Commands

```bash
S=core/packages/hq-pack-hq-slack/scripts/hq-slack.sh

bash "$S" whoami                              # confirm identity/workspace
bash "$S" post   '#general' 'message text…'   # post (channel name or ID)
bash "$S" read   '#general' 20                # last N messages (default 20)
bash "$S" thread '#general' <thread_ts> 50    # read replies in a thread
bash "$S" reply  '#general' <thread_ts> 'text…'  # reply in a thread
bash "$S" dm     someone@example.com 'text…'  # DM by email / @handle / U-id
bash "$S" upload '#general' ./chart.png 'caption'  # share a file/image
bash "$S" search 'query…'                     # needs search:read on the token
bash "$S" channels hq-                        # list your channels (optional prefix)
bash "$S" post '#x' 'hi' --ws acme            # other workspace
```

Channel names (`#general` or `general`) auto-resolve to IDs via
`conversations.list`. Slack mrkdwn works in message text (`*bold*`, `• bullets`,
`:emoji:`, backtick code).

## Operating rules (follow these when invoked)

1. **Short, human, non-technical — one liner by default.** Every outbound
   message leads with the outcome (not the diagnosis), uses Slack mrkdwn
   (`:emoji: *Headline* — outcome. <link>`), and links out for detail. **Never**
   include file paths, function names, env var names, commit SHAs, framework
   terms, error codes, repo names, PR/branch refs, or log snippets in the
   message body — the reader is often non-technical and on their phone.
     - Default shape: one line: `:emoji: *Headline* — outcome. <link>`
     - For larger drops: deploy a one-pager and link to it instead of writing
       4+ bullets in Slack.
     - Lead emoji: `:chart_with_upwards_trend:` shipped · `:wrench:` fixed
       · `:eyes:` heads-up · `:white_check_mark:` done · `:rocket:` launched
2. **Confirm content before sending.** Posting/replying/DM is an outbound message
   on the owner's behalf — show the drafted text and get a go before
   `post`/`reply`/`dm`, unless the user already gave the exact text to send.
3. **Read-back to verify.** After posting, `read` the channel to confirm it
   landed and to catch duplicates (surface a pre-existing duplicate rather than
   silently double-posting).
4. **Never delete messages.** Message deletion is a prohibited action — if a
   duplicate or mistake needs removing, instruct the user to delete it in Slack
   (hover → ⋯ → Delete message). Do not call `chat.delete`.
5. **Never echo the token** or paste it into chat, files, commits, or logs.
6. **Right workspace:** run `whoami` if unsure which workspace a channel is in;
   pass `--ws <slug>` to target a non-default workspace.

## The brevity check (run before every send)

1. **Length.** Keep it scannable; lead with the outcome. The script blocks any
   `post`/`reply`/`dm` body over **600 chars** (exit 2) — for anything longer,
   build a one-pager and post a single line + link. Tunables:
   `HQ_SLACK_MAX_CHARS`, `HQ_SLACK_MAX_LINES`. Sanctioned long post:
   `HQ_SLACK_ALLOW_LONG=1`.
2. **Read aloud.** Contains a file path, symbol name, env var, error code, commit
   SHA, branch name, framework term, "HTTP nnn", "401 / 502"? Rewrite without it.
3. **Outcome-first.** Does the reader know what to do (or that nothing more is
   required) from this one line alone? If not, rewrite the headline as an outcome.
4. **Sounds like a person.** Would a sharp colleague actually text this? Warm,
   direct, plain — no status-report cadence, no robotic hedging.

| ❌ Don't send | ✅ Send |
|---|---|
| "Root cause: CRON_SECRET wasn't rotated to match the new project secret, so the trigger step got 401'd. Rotated both sides, redeployed, fired the missed post." | `:wrench: Fixed — today's report just landed. Should fire automatically tomorrow.` |
| "Confirmed data file dated 2026-06-05 and the function picked up the new env var after the deploy." | `:white_check_mark: Confirmed — fresh data is live.` |

## Adding a workspace

Each workspace gets its own Slack app + `xoxp-` token + vault key
`SLACK_TOKEN_<SLUG>_USER`. Follow the setup guide again with a new slug, then
select it at call time with `--ws <slug>`.

## Not this skill

- Want an autonomous bot identity that answers `@`-mentions in channels?
  Use the `hq-pack-slack-bot` pack instead — it runs a per-bot mention watcher.
  This skill is day-to-day messaging **as you**.
