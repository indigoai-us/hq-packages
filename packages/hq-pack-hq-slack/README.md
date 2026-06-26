# hq-pack-hq-slack

![hq-pack-hq-slack — MCP-free Slack messaging from the CLI, acting as you](cover.png)

MCP-free Slack messaging for HQ. Post, read, reply, DM, search, and upload to
Slack from the CLI — acting **as you**, via **your own** Slack app's user token
(`xoxp-`). No MCP server, no shared bot identity, no third-party broker: just a
self-contained script talking to Slack's HTTPS Web API with a token that lives
only in your HQ vault.

The pack ships a guided one-time setup that walks you through creating your own
**full-access** Slack app from a manifest and storing the token safely.

> Want an autonomous bot that answers `@`-mentions in channels instead? That's a
> different shape — use [`hq-pack-slack-bot`](../hq-pack-slack-bot). This pack is
> day-to-day messaging *as you*.

## Install

```bash
hq install @indigoai-us/hq-pack-hq-slack                                  # npm
hq install github:indigoai-us/hq-packages#packages/hq-pack-hq-slack       # git
hq install ./packages/hq-pack-hq-slack                                    # local
```

The slash form depends on the host — master-sync exposes packs as
`<pack>:<skill>`, so the canonical invocation is `/hq-pack-hq-slack:hq-slack`.

## One-time setup (create your own full-access Slack app)

Before any messaging works, create your own Slack app and store its user token.
Full walkthrough: [`knowledge/hq-slack/create-your-slack-app.md`](./knowledge/hq-slack/create-your-slack-app.md).

1. **Create the app from the manifest.** At <https://api.slack.com/apps> →
   **Create New App → From a manifest**, pick your workspace, and paste
   [`knowledge/hq-slack/manifest.full-access.json`](./knowledge/hq-slack/manifest.full-access.json).
   It requests a broad set of **user scopes** (full access).
2. **Install + copy the token.** **Settings → Install App → Install to
   Workspace**, then copy the **User OAuth Token** (`xoxp-…`).
3. **Store it in the HQ vault:**
   ```bash
   printf '%s' 'xoxp-YOUR-TOKEN' | hq secrets --personal set SLACK_TOKEN_DEFAULT_USER --from-stdin
   ```

Scopes explained (and a least-privilege minimal set): [`knowledge/hq-slack/scopes-reference.md`](./knowledge/hq-slack/scopes-reference.md).

## Use

```bash
S=core/packages/hq-pack-hq-slack/scripts/hq-slack.sh   # path after install

bash "$S" whoami                              # confirm identity + workspace
bash "$S" post   '#general' 'hello from HQ'   # post
bash "$S" read   '#general' 20                # last N messages
bash "$S" reply  '#general' <thread_ts> '…'   # reply in a thread
bash "$S" dm     someone@example.com '…'      # DM by email / @handle / U-id
bash "$S" upload '#general' ./chart.png 'cap' # share a file
bash "$S" search 'quarterly numbers'          # needs search:read
bash "$S" channels hq-                        # list your channels
bash "$S" post '#x' 'hi' --ws acme            # another workspace
```

Channel names auto-resolve to IDs. Slack mrkdwn works in message text. Multiple
workspaces: store one `xoxp-` token per workspace under
`SLACK_TOKEN_<SLUG>_USER` and select with `--ws <slug>`.

## Security

- The user token is read from the HQ vault (`hq secrets --personal`), or a local
  `~/.mcp.json` as a legacy fallback. It is loaded into an env var inside the
  script and sent **only** as the `Authorization` header — never printed, never
  on the command line, never committed.
- The token acts as you: posts appear as you and reads see every channel you're
  in, including private ones. Keep it secret; rotate or revoke any time (see the
  setup guide).
- The skill **never deletes messages** and confirms outbound text before sending.

## Layout

```
packages/hq-pack-hq-slack/
├── README.md                              ← you are here
├── package.yaml                           ← HQ pack manifest
├── package.json                           ← npm-side manifest
├── scripts/
│   └── hq-slack.sh                        ← self-contained MCP-free Slack CLI
├── skills/
│   └── hq-slack/
│       └── SKILL.md                       ← the /hq-slack skill
└── knowledge/
    └── hq-slack/
        ├── create-your-slack-app.md       ← one-time full-access app setup guide
        ├── manifest.full-access.json      ← paste-into-Slack app manifest
        └── scopes-reference.md            ← what each scope unlocks (+ minimal set)
```

The script is dependency-free (bash + python3 stdlib) and self-contained, so the
pack works with no `personal/` or HQ-core script dependencies.

## License

MIT.
