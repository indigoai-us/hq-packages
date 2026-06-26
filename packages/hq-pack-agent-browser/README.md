# hq-pack-agent-browser

![hq-pack-agent-browser cover](./cover.png)

Wire [Vercel's **agent-browser**](https://github.com/vercel-labs/agent-browser) CLI into HQ.

agent-browser is a self-contained native-Rust browser-automation tool (~7MB, ~8MB memory)
that drives Chromium over the Chrome DevTools Protocol directly — no Node, no Playwright, no
browser extension. This pack makes it a first-class HQ citizen: the snapshot+refs workflow,
saved-state auth profiles, social-posting and Tauri-testing recipes, and the policies that
make it the default for UI verification and QA audits.

## What it adds

| Contribution | What you get |
|---|---|
| **Skill** `/agent-browser-hq` | The HQ workflow guide — snapshot→refs→interact, headed vs headless, auth profiles, verify-before-you-file-a-bug, Tauri/WKWebView. |
| **Knowledge** `agent-browser` | README + `auth-profiles.md`, `social-posting.md`, `tauri-testing.md` recipes. |
| **Policy** `hq-prefer-agent-browser` | Default to agent-browser over Claude-in-Chrome for QA/page-walks/scraping. |
| **Policy** `hq-agent-browser-is-cli-not-mcp-server` | Never add it to `.mcp.json` — it's a CLI, not an MCP server. |
| **Policy** `agent-browser-ui-verification` | Verify UI changes in a real browser before calling them done. |
| **Policy** `agent-browser-react-false-positives` | Check data/API context and React state before filing "empty/broken page" bugs. |

> The pack ships knowledge, policies, and the how-to skill — **not** the binary. The full,
> version-matched command reference ships with the CLI itself via
> `agent-browser skills get core --full`.

## Prerequisites

```bash
brew install agent-browser      # or: npm i -g agent-browser  /  cargo install agent-browser
agent-browser install           # one-time: download Chromium
```

The pack declares `conditional: command -v agent-browser` — on a host without the CLI on
`PATH`, install is **skipped** (not failed) with a notice.

## Install

```bash
hq install @indigoai-us/hq-pack-agent-browser                                          # npm (when published)
hq install github:indigoai-us/hq-packages#packages/hq-pack-agent-browser               # git
hq install ./packages/hq-pack-agent-browser                                            # local path
```

After install, run `/agent-browser-hq` to get oriented.

## License

MIT.
