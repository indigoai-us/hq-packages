---
name: agent-browser-hq
description: Drive Vercel's agent-browser CLI the HQ way — the snapshot+refs workflow, saved-state auth profiles, headed vs headless mode, and the verify-before-you-file-a-bug discipline. Use when verifying a UI change in a real browser, running a QA/page-walk audit, scraping a client-rendered (Wix/React SPA) site, automating social posts, or testing a Tauri/WKWebView app. This is the HQ integration guide; the full command reference ships with the CLI via `agent-browser skills get core --full`.
---

# agent-browser, the HQ way

`agent-browser` is Vercel's browser-automation CLI — a self-contained native-Rust binary
(~7MB, ~8MB memory) that talks to Chromium over the Chrome DevTools Protocol directly. No
Node, no Playwright, no extension. In HQ it is the **default** tool for confirming a frontend
change actually works in a real browser, for QA page-walks, and for headless automation like
social posting and invoice flows.

> It is a **CLI, not an MCP server.** Never add it to `.mcp.json` — invoked with no args it
> just prints help and the runtime marks the server "failed." Always shell out to the global
> `agent-browser` binary.

## Prerequisites

```bash
brew install agent-browser      # or: npm i -g agent-browser  /  cargo install agent-browser
agent-browser install           # one-time: download Chromium
```

Installed globally it starts ~150x faster than `npx agent-browser`, so per-step browser
verification is cheap enough to do on every UI change.

## Step 1 — load the version-matched command reference

Before driving the browser, pull the CLI's own skills — they ship matched to your installed
version and beat guessing flags from memory:

```bash
agent-browser skills get core --full     # core workflow + selectors + examples
agent-browser skills list                # specialized: electron, slack, exploratory, ...
```

## The core workflow: snapshot → refs → interact → re-snapshot

```bash
agent-browser open https://example.com/login
agent-browser snapshot -i                 # accessibility tree, interactive-only → @e1, @e2, ...
agent-browser fill @e1 "user@example.com"
agent-browser fill @e2 "••••••"
agent-browser find role button click --name "Sign in"
agent-browser wait --load networkidle
agent-browser get url                      # confirm where you landed
agent-browser close
```

Rules of thumb:
- **Re-`snapshot -i` after every navigation or DOM change** — refs go stale once the page
  changes.
- Prefer **semantic locators** (`find role button --name "..."`, `find text "..."`) over raw
  refs when a React control doesn't respond to a plain `click` (controlled components often
  don't re-render on a synthetic click).
- Use `--session <name>` to run multiple independent browser tasks in parallel.

## Headed vs headless

Headless is the default. Flip to headed when a human needs to watch or log in:

```bash
AGENT_BROWSER_HEADED=1 agent-browser open https://...   # or: agent-browser --headed open ...
```

**CSR / Wix / React SPA scraping:** `WebFetch` returns only the JS bootstrap for
client-rendered sites. Use agent-browser with `wait --load networkidle`, then
`get text "body"` or `screenshot --full` to capture the *rendered* page.

## Auth profiles — log in once, reuse the session

Save browser state after a manual login and reload it later instead of re-authenticating.
Convention: `core/settings/{company}/browser-state/{service}-auth.json`.

```bash
# First time (headed): log in manually, then snapshot the session
agent-browser --headed open "https://x.com/login"
# ...complete login + 2FA...
agent-browser state save core/settings/personal/browser-state/x-auth.json
agent-browser close

# Later: reload and detect expiry
agent-browser state load core/settings/personal/browser-state/x-auth.json
agent-browser open "https://x.com/compose/post"
agent-browser wait --load networkidle
# If get-url redirects to /login or /signin → re-auth in --headed mode and re-save
```

> **Security:** state files hold session cookies/tokens. They are gitignored
> (`**/browser-state/*.json`) and must never be committed. For vault-backed credentials,
> inject the secret with `hq secrets exec` and read it *inside* the child shell — never echo
> a secret to the terminal. See the bundled `agent-browser` knowledge for the recipes
> (`auth-profiles.md`, `social-posting.md`).

## Verify before you file a bug (the discipline that pays off)

agent-browser makes it cheap to "test" a page — and cheap to file false positives. Before
reporting an empty or broken page:

1. **Check data/API context.** A page that says "Select an artist" with no data loaded isn't
   broken — it lacks context. Verify the API is reachable from the browser first.
2. **Suspect controlled components.** A `click` that produces no visible change may be a React
   state toggle that didn't fire — try a semantic locator before calling it a bug.
3. **Cross-reference the source.** Confirm the feature is genuinely missing in the code, not
   just absent from this test run.

This is the "E2E proves it works" bar: a green build is not proof; driving the changed
interaction in a real browser is.

## Tauri / macOS WKWebView

macOS Tauri apps run on WKWebView, which doesn't expose CDP. Use the `tauri://` provider
against the `tauri-plugin-agent-test` MCP plugin instead of a CDP URL:

```bash
agent-browser connect tauri://localhost:9876   # then snapshot / click / fill / screenshot
```

Setup details (plugin install, `withGlobalTauri: true`, port defaults) are in the bundled
`tauri-testing.md` knowledge.

## What this pack installs

- **Knowledge** (`knowledge/public/agent-browser/`): README + auth-profiles, social-posting,
  and tauri-testing recipes.
- **Policies**: prefer agent-browser for QA, it's-a-CLI-not-MCP, verify-UI-changes, and the
  data-dependent-page false-positive guard.
- **This skill**: the HQ workflow glue. The exhaustive command reference lives with the CLI —
  `agent-browser skills get core --full`.
