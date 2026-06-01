---
name: gbrain
description: Use the optional HQ GBrain pack for per-company brain setup, status, search, ask, capture, and doctor flows. Keeps GBrain isolated under workspace/gbrain/{company}.
allowed-tools: Bash, Read
---

# GBrain

Use this skill when the user wants HQ to use the optional GBrain memory layer.

## Commands

Run the pack wrapper from the HQ root:

```bash
core/scripts/hq-gbrain status <company>
core/scripts/hq-gbrain setup <company> --install-gbrain
core/scripts/hq-gbrain search <company> "<query>"
core/scripts/hq-gbrain ask <company> "<question>"
core/scripts/hq-gbrain capture <company> "<note>"
core/scripts/hq-gbrain doctor <company>
```

## Behavior

- Resolve the company before every call.
- Use the wrapper instead of raw `gbrain` so `GBRAIN_HOME` is company-scoped.
- For first-time setup, pass `--install-gbrain` when the user asked for an
  unattended install.
- Setup initializes PGLite with `--no-embedding` and imports company markdown
  with `--no-embed`, so smoke tests work without API keys.
- `ask` attempts `gbrain think`; if the model layer is not configured, it falls
  back to keyword search.

## Safety

Never use a shared `~/.gbrain` runtime for company work. Never import another
company's knowledge into the active company's brain. Never store secrets in
brain pages.
