---
id: hq-agent-browser-is-cli-not-mcp-server
title: agent-browser is a CLI — never add it to .mcp.json
scope: global
trigger: Adding or editing MCP server entries in .mcp.json; configuring agent-browser
when: ".mcp.json" || ("agent-browser" && (mcp || server))
on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-06-15
updated: 2026-06-15
source: session-learning
---

## Rule

NEVER add `agent-browser` to `.mcp.json` — it is a pure CLI with no `mcp`/`serve`/`stdio` subcommand. Invoked with no args (as an MCP stdio server would be) it prints its help banner and exits, so Claude Code marks the server 'failed'. HQ already uses it correctly as the global CLI (`/opt/homebrew/bin/agent-browser`) via Bash, referenced by ~15 policies that call `agent-browser <cmd>` (never `mcp__agent-browser__*`). Removing the MCP entry loses zero capability.

## Rationale

agent-browser ships as a self-contained native binary that speaks a command-line interface, not the MCP stdio protocol. There is no server mode to start, so a `.mcp.json` entry can only ever fail to initialize — costing a "server failed" diagnostic and wasted debugging with no offsetting benefit. Every HQ workflow that needs it already shells out to the global `agent-browser` binary, so the MCP entry is pure liability.
