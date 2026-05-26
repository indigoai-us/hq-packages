---
name: setup-nanoclaw
description: Bootstrap a local NanoClaw install from inside HQ — clone the NanoClaw app, run its interactive setup, and register it in the HQ manifest. Use when the user wants to install NanoClaw, set up a container-isolated personal Claude assistant, or stand up NanoClaw for the first time. Triggers on "set up nanoclaw", "install nanoclaw", "bootstrap nanoclaw". For upgrading an existing install, use /update-nanoclaw or /migrate-nanoclaw instead.
---

# Set Up NanoClaw

Clone the NanoClaw app into HQ, hand off to its own installer, and register it as HQ infrastructure. NanoClaw is a container-isolated personal Claude assistant (messaging channels → per-session Claude agents in Linux containers). See `knowledge/nanoclaw/architecture.md` for what it is.

This skill does the HQ-side wiring. The actual install is NanoClaw's own interactive `nanoclaw.sh`, which **must run in a real terminal** (it uses `@clack/prompts`, builds a container image, and configures a service — it cannot run inside Claude Code).

## Step 1 — Resolve the target directory

Default clone target: `repos/public/nanoclaw` (HQ keeps code under `repos/public/` or `repos/private/`).

- If `repos/public/nanoclaw` already exists, **stop** — NanoClaw is already cloned. Point the user at `/update-nanoclaw` (sync upstream) or `/migrate-nanoclaw` (intent-based upgrade).
- Otherwise continue. Confirm `repos/public/` exists.

## Step 2 — Clone the app

Clone the upstream repo. Anchor the git command to the parent dir (HQ blocks unanchored git mutations from the HQ root):

```bash
git -C repos/public clone https://github.com/nanocoai/nanoclaw.git nanoclaw
```

This is a normal `repos/` checkout — it keeps its own git history and is updated via the maintenance skills, not HQ autosave.

## Step 3 — Hand off to NanoClaw's installer

Tell the user, verbatim, to run this in a terminal (do **not** run it yourself — it's interactive and long-running):

```bash
cd repos/public/nanoclaw && bash nanoclaw.sh
```

`nanoclaw.sh` handles the full end-to-end setup: dependencies (Node + pnpm + native modules), the agent container image, the OneCLI credential vault, the Anthropic credential, the background service, the first agent, and optional channel wiring. If it errors partway, it offers Claude-assisted recovery inline.

Wait for the user to confirm setup finished before continuing.

## Step 4 — Register as HQ infrastructure

After setup succeeds, record the repo in HQ so it's discoverable:

- Add a `repos/public/nanoclaw` entry under the appropriate company (or the personal/unaffiliated scope) in `companies/manifest.yaml`, following the existing repo-entry shape in that file.
- Refresh search indexing: `qmd update 2>/dev/null || true`.

If you are unsure which company owns it, ask rather than guessing — never cross-assign a repo to the wrong tenant.

## Step 5 — Point at next steps

- **Wire channels / customize** — done inside the NanoClaw checkout using its own in-repo skills (`/add-telegram`, `/add-slack`, `/init-first-agent`, `/customize`, …). Open a Claude session in `repos/public/nanoclaw` for those.
- **Keep it current** — `/update-nanoclaw` (low-token upstream sync) or `/migrate-nanoclaw` (intent-based upgrade) from HQ.
- **Remote access to a sensitive tree** — `/secure-sidecar` for the safe capability-bridge pattern.

## Notes

- The NanoClaw app is cloned, not vendored by this pack — you always get upstream `main`.
- NanoClaw's container runtime needs Docker (or Apple containers) and builds a ~hundreds-of-MB image; that's handled by `nanoclaw.sh`, not by this skill.
