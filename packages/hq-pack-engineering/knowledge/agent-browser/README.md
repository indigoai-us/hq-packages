# agent-browser — HQ Browser Automation

CLI browser automation tool from Vercel. Headless by default, snapshot+refs pattern for minimal context usage.

## Architecture (v0.27+)

100% native Rust — Node.js and Playwright have been fully removed. ~10MB install, low memory, direct CDP connection to Chromium. No configuration needed. Install: `brew install agent-browser` then `agent-browser install` (downloads Chrome for Testing).

**Limitations:** Chromium + Safari only (no Firefox/WebKit), network interception uses CDP Fetch. None affect current HQ usage.

## When to Use What

This is the HQ default split (see policy `hq-prefer-agent-browser`):

| Tool | Use For |
|------|---------|
| **agent-browser CLI** | Default for all interactive/agentic browser work — page audits, smoke tests, deploy verification, `/verify`, data extraction, social posting, invoice automation. ~200–400 tokens/snapshot. |
| **Playwright (CLI runner)** | Committed E2E suites that run in CI (`prd.json` `e2eTests`, the `e2e-testing` skill), axe-core a11y audits, structured regression pipelines. agent-browser is not a test runner. |
| **Playwright Test Agents** (planner/generator/healer) | Generating/self-healing committed specs. Never auto-commit healer output (~25% false-positive rate). |
| **Playwright MCP** | Avoid for routine browsing — ~4x the token cost of the CLI and prone to context pollution. Acceptable only in sandboxed, no-shell clients. |
| **Claude in Chrome MCP** | Reserve for real-time visual interaction or when agent-browser is unavailable. |

## Core Workflow

```bash
agent-browser open <url>
agent-browser snapshot -i        # Get @refs for interactive elements
agent-browser fill @e1 "text"    # Interact via refs
agent-browser click @e2
agent-browser close
```

## Auth Persistence

Auth state files live at `core/settings/{company}/browser-state/*.json`. Never committed (gitignored).

```bash
# First time: login manually in headed mode
agent-browser --headed open "https://x.com/login"
# ... login ...
agent-browser state save core/settings/personal/browser-state/x-auth.json
agent-browser close

# Later: load saved state
agent-browser state load core/settings/personal/browser-state/x-auth.json
agent-browser open "https://x.com"
```

## Auth Expiry Detection

After loading state, check if redirected to login:
```bash
agent-browser state load core/settings/personal/browser-state/x-auth.json
agent-browser open "https://x.com/compose/post"
agent-browser wait --load networkidle
agent-browser get url
# If URL contains "login" or "signin" → auth expired, re-auth in --headed mode
```

## Key References

- Bundled skill (version-matched, ships with the CLI): `agent-browser skills get core --full`
- Specialized skills: `agent-browser skills list` (electron, slack, exploratory, cloud providers)
- Auth patterns + hq-secrets integration: `core/knowledge/public/agent-browser/auth-profiles.md`
- Social posting: `core/knowledge/public/agent-browser/social-posting.md`
