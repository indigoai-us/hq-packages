---
id: hq-prefer-agent-browser
title: Default browser tool — agent-browser CLI for interactive/QA, Playwright for committed E2E
scope: global
trigger: browser-based QA, page audits, site testing, smoke tests, web automation, deploy verification
enforcement: soft
version: 3
created: 2026-03-24
updated: 2026-05-27
source: user-correction
public: true
---

## Rule

The HQ default for interactive, agentic browser work — page-walking, QA audits, site testing, smoke tests, data extraction, form filling, deploy verification, and the `/verify` flow — is the Vercel **agent-browser** CLI (currently v0.27.0). Prefer it over both Claude in Chrome and the Playwright MCP server for these tasks.

The decision splits cleanly by task type:

| Task | Tool | Why |
|------|------|-----|
| Ad-hoc browsing, deploy verification, screenshots, data extraction, `/verify` | **agent-browser CLI** | ~200–400 tokens per accessibility-tree snapshot vs ~114K tokens/task for Playwright MCP. Directly serves the `context-diet` and `image-context-isolation` policies. |
| Committed E2E suites (`prd.json` `e2eTests`, the `e2e-testing` skill, CI regression) | **Playwright (CLI runner)** | E2E is the truth signal for deployable projects and must run as real, committed `.spec.ts` files in CI — agent-browser is not a test runner and does not replace it. |
| Generating or self-healing those specs | **Playwright Test Agents** (planner / generator / healer, v1.56+) | Structured test scaffolding. Healer has a ~25% false-positive rate on selector fixes — never auto-commit healer output; gate behind review. |
| Routine browsing via **Playwright MCP** | **avoid** | Streams full accessibility trees inline (~114K tokens/task, ~4x the CLI). Context pollution past ~step 15 causes element hallucination. Acceptable only in sandboxed clients with no shell. |
| Claude in Chrome MCP | **reserve** | Use only for tasks needing real-time visual interaction, or when agent-browser is unavailable. The extension connection frequently disconnects. |

agent-browser advantages for the interactive lane:
- Headless by default; headed mode via `--headed` or `AGENT_BROWSER_HEADED=1` so the user can see and interact.
- Snapshot-based interaction (`agent-browser snapshot -i`) returning compact `@eN` refs — no Chrome extension required.
- State persistence (`state save`/`state load`, `--session-name`, `--profile`) for reusable auth sessions, with encryption at rest via `AGENT_BROWSER_ENCRYPTION_KEY`.
- Self-contained native Rust binary; supports parallel sessions, screenshots, annotated captures, and `--json` output for machine parsing.

**Authentication uses the HQ vault, not pasted secrets.** When a company holds a token or password secret, inject it via `hq secrets exec` and reference it inside the exec'd shell so the value never enters model context or shell history (it lives only in the child process environment). See `core/knowledge/public/agent-browser/auth-profiles.md` for the canonical patterns. Never paste a credential inline into an agent-browser command (`credential-access-protocol`).

**CSR/Wix site scraping:** WebFetch returns only JS bootstrap code from client-side rendered sites (Wix, React SPAs). Use agent-browser with `wait --load networkidle` to get fully rendered content, then `get text "body"` for text extraction and `screenshot --full` for full-page captures. Use `--session {name}` for named sessions.

## Rationale

User correction: Claude in Chrome requires an active extension connection that frequently disconnects. The Playwright MCP server, while capable, streams accessibility trees inline and costs roughly four times the tokens of a CLI approach per task — a poor fit for HQ's many-concurrent-session model and its context-diet discipline. agent-browser is self-contained, snapshot-efficient, supports headed mode for authentication, and integrates cleanly with `hq secrets` for vault-backed logins. Playwright remains the framework of record for committed E2E suites because those must run as real tests in CI, which agent-browser does not do.
