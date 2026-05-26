# Sidecar Boundary — Threat Model Template

Copy this file into your project and replace every `<placeholder>`. Fill it in **before** writing code: the point is to decide each boundary explicitly, so a reviewer can audit the safety model before runtime wiring expands. Keep it next to the code and update it whenever a capability or mount changes.

> Sensitive tree: `<sensitive-tree>` (e.g. a source repo, knowledge base, agent workspace)
> Remote channel(s): `<channel>` (e.g. Telegram)
> Trusted identity: `<identity>` (e.g. paired Telegram chat id + sender id)

## Boundary summary

The sidecar is a short-lived bridge for remote access. It is **not** a host runtime and must not become remote shell access. The bridge is a dispatcher over named capabilities, not a command interpreter. Messages that do not classify into a known capability are refused.

| Layer | Boundary |
|---|---|
| Message ingress | `<channel>` is the first access point. A local CLI path exists for credential-free smoke tests only. |
| Identity | Requests are accepted only from the paired trusted identity `<identity>`. CLI requests are local-only and do not prove remote identity. |
| Agent context | Requests land in a dedicated, constrained context (`<group-name>`), not a general-purpose assistant. |
| Capability bridge | Named handlers only. Free-form shell and arbitrary tool calls are denied. |
| Mount / allowlist | Only the named roots below are reachable. The tree root is never mounted. |
| Confirmation flow | Read capabilities run directly. Mutations require an exact confirmation phrase. |
| Audit log | Every request is logged with identity, channel, capability, scope, outcome, and denial reason. |

## Allowed roots

Enumerate narrow roots — never the tree root. Each row must name the capability that justifies it.

| Host path (relative to tree root) | Access | Justifying capability |
|---|---|---|
| `<allowed-root-1>` | read | `<capability>` |
| `<allowed-root-2>` | read-write | `<mutation-capability>` |

Adding a new path later requires naming the capability, the access mode, and the denial behavior that justify it.

## Read-only capabilities

| Capability | Allowed scope | Notes |
|---|---|---|
| `read_status` | `<status-root>` | parsed summaries, not raw dumps |
| `lookup` | named records under allowed roots | request name must be a safe path segment |
| `search` | one explicit allowlisted scope | scope named by caller and allowlisted |
| `<your-capability>` | `<scope>` | `<notes>` |

## Confirmation-gated mutations

| Capability | Allowed target | Confirmation phrase |
|---|---|---|
| `create_record` | `<mutation-scope>` request record | `<exact phrase>` |

No other mutation is allowed. Confirmed mutations write request records only — they do not execute shell, edit repos, call external APIs, deploy, or change settings.

## Denied paths (refused even for the trusted caller)

- Credentials / keys: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.docker`, `.env`, `.netrc`, `.npmrc`, private keys, tokens, secrets, password files.
- Shell / login config: `.zshrc`, `.zprofile`, `.zshenv`, `.bashrc`, `.bash_profile`, `.profile`.
- Settings / secrets within the tree: `<settings-paths>`, credential references.
- Broad source / knowledge roots: `<broad-roots>` and arbitrary worktrees, unless a later approved change adds a narrow read-only mount.
- The sidecar's own security config and channel credentials.

The deny list is defense in depth: a denied path is absent from the allowlist **and** rejected by name.

## Denied actions

- Arbitrary shell commands or command fragments.
- Editing source, committing, pushing, merging, rebasing, opening PRs, changing git config.
- Deploying, publishing packages, mutating external APIs, changing infrastructure.
- Reading, printing, copying, or testing credentials.
- Changing settings, profiles, DNS, or registry configuration.
- Installing packages or broadening mounts from chat.

Denied requests produce an audit entry with `outcome: "denied"` and a specific reason.

## Confirmation flow

```json
{
  "capability": "create_record",
  "summary": "<what this record captures>",
  "targetScope": "<mutation-scope>",
  "affectedPaths": ["<mutation-scope>/record-YYYYMMDD-HHMMSS.json"],
  "riskLevel": "low",
  "confirmationPhrase": "<exact phrase>"
}
```

Nothing is written until the caller replies with the exact phrase. A cancelled, expired, mismatched, missing, or edited confirmation is denied and logged.

## Audit log

Append-only JSON lines the agent cannot rewrite. Each entry records: timestamp; requester identity + channel; capability after classification; scope + affected paths; confirmation state (`none` / `pending` / `confirmed` / `cancelled` / `expired`); outcome (`allowed` / `completed` / `denied` / `failed`); files read / written; denial reason or error.

## Stop conditions

Stop the sidecar path and design a native gateway before expanding scope if any become necessary:

- Mounting the tree root, a broad source/knowledge root, or arbitrary worktrees.
- Running arbitrary shell commands from chat.
- Letting the agent choose paths outside a capability's declared scope.
- Granting write access to repos, settings, credentials, deploy targets, or external API clients.
- Adding more channels before identity, revocation, audit, and offline behavior are solid.
- Depending on prompt instructions instead of explicit handler checks for denial behavior.
