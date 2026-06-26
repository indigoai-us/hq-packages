# Create your own Slack app (full access) and mint a user token

This is the one-time setup that powers the `hq-slack` skill. You will create a
personal Slack app, install it to your workspace with a broad set of **user
scopes**, copy the resulting **user token** (`xoxp-…`), and store it in your HQ
vault. After that, `hq-slack` can post, read, reply, search, DM, and upload —
all acting as **you**.

You only do this once per Slack workspace. The whole thing takes a few minutes.

> **Why a user token (`xoxp-`), not a bot token (`xoxb-`)?**
> A user token acts as *you*: posts show up as you, and reads see every channel
> you're a member of — including private ones. A bot token acts as a separate
> bot identity that must be invited to each channel. This pack is built for
> personal, owner-level messaging, so it uses a user token. If you want an
> autonomous bot identity that answers `@`-mentions instead, use the
> `hq-pack-slack-bot` pack.

---

## Step 1 — Create the app from the manifest

1. Go to **https://api.slack.com/apps** and click **Create New App**.
2. Choose **From a manifest**.
3. Pick the **workspace** you want the app installed in, then click **Next**.
4. Select the **JSON** tab, delete the placeholder, and paste the full contents
   of [`manifest.full-access.json`](./manifest.full-access.json) (shipped next to
   this guide).
5. Click **Next**, review the summary, then **Create**.

The manifest requests a broad set of **user scopes** so the app has full access
to do anything the skill supports (and headroom for more). You can trim scopes
later under **OAuth & Permissions** — see
[`scopes-reference.md`](./scopes-reference.md) for what each one unlocks and the
minimal set the skill actually needs.

> Prefer the web UI? You can instead click **Create New App → From scratch**,
> then add the scopes from `scopes-reference.md` by hand under **OAuth &
> Permissions → User Token Scopes**. The manifest just does this for you.

---

## Step 2 — Install the app and copy your user token

1. In your new app's settings, open **Settings → Install App**.
2. Click **Install to <your workspace>** and approve the requested permissions
   on the consent screen.
3. After install, the same page shows a **User OAuth Token** that starts with
   **`xoxp-`**. Copy it.

> Keep this token secret. It can act as you in Slack. Treat it like a password —
> never paste it into chat, commits, screenshots, or a file. The next step puts
> it somewhere safe.

---

## Step 3 — Store the token in your HQ vault

Pick a short **workspace slug** to refer to this token by. The skill defaults to
`default`, so if you only use one workspace, use that and the bare commands work
with no `--ws` flag. Store the token under the key
`SLACK_TOKEN_<SLUG>_USER` (uppercased):

```bash
# default workspace (no --ws needed at call time)
printf '%s' 'xoxp-YOUR-TOKEN-HERE' | hq secrets --personal set SLACK_TOKEN_DEFAULT_USER --from-stdin

# or a named workspace, e.g. "acme" → call later with --ws acme
printf '%s' 'xoxp-YOUR-TOKEN-HERE' | hq secrets --personal set SLACK_TOKEN_ACME_USER --from-stdin
```

`printf` (not `echo`) avoids a trailing newline in the stored value, and
`--from-stdin` keeps the token off your shell history and off the process list.

> No `hq` CLI? The skill also reads tokens from a local `~/.mcp.json` (or
> `~/Documents/HQ/.mcp.json`) as a fallback — add
> `SLACK_TOKEN_DEFAULT_USER` to a Slack server's `env` block there. The HQ
> vault is the recommended path; `.mcp.json` is legacy.

---

## Step 4 — Verify

```bash
S=core/packages/hq-pack-hq-slack/scripts/hq-slack.sh   # path after install

bash "$S" whoami                       # confirms identity + workspace
bash "$S" channels                     # lists channels you're in
bash "$S" post '#general' 'hello from HQ 👋'
```

If `whoami` prints `ok: True` with your team and user, you're done. If you see
`missing_scope` or `not_authed`, re-check Step 2 (install) and the stored token
key in Step 3.

---

## Adding more workspaces later

Repeat Steps 1–3 with a new slug. Each workspace gets its own `xoxp-` token and
its own `SLACK_TOKEN_<SLUG>_USER` vault key. At call time, select it with
`--ws <slug>` (or set `HQ_SLACK_WS=<slug>` for the session).

## Rotating or revoking

- **Rotate:** mint a fresh token (re-install the app in Step 2) and overwrite the
  vault key with the same `hq secrets … set` command.
- **Revoke:** delete the app at **https://api.slack.com/apps → your app →
  Settings → Basic Information → Delete App**, or have a workspace admin revoke
  it. Then remove the vault key:
  `hq secrets --personal rm SLACK_TOKEN_<SLUG>_USER`.

## Security notes

- The token lives only in your HQ vault (or local `.mcp.json`). The skill loads
  it into an environment variable inside the script and sends it **only** as the
  `Authorization` header — it is never printed, never passed on the command
  line, and never committed.
- "Full access" here means the *user scopes* in the manifest — broad enough to
  manage messages, channels, files, reactions, pins, and your profile. It does
  **not** include Enterprise Grid `admin.*` scopes (org-wide administration);
  those require an org-owner-approved app. See `scopes-reference.md` if you need
  them.
- Want least-privilege instead? Trim the manifest to the minimal set in
  `scopes-reference.md` before installing — you can always add scopes back and
  re-install.
