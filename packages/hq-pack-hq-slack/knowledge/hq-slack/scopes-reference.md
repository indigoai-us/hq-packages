# Scopes reference — what the full-access manifest grants

All scopes below are **user-token scopes** (the app acts as you). They map to
`oauth_config.scopes.user` in [`manifest.full-access.json`](./manifest.full-access.json).

## Minimal set the `hq-slack` skill actually needs

If you'd rather install least-privilege, trim the manifest to just these and
re-install. Everything in the skill (post / read / reply / thread / dm / search
/ upload / channels) works with this set:

| Scope | Why |
|-------|-----|
| `channels:read`, `groups:read` | resolve channel names → IDs; list your channels |
| `channels:history`, `groups:history`, `im:history`, `mpim:history` | read messages & thread replies |
| `im:read`, `mpim:read` | enumerate DMs / group DMs you're in |
| `chat:write` | post messages, replies, and DMs as you |
| `search:read` | `search` command |
| `users:read` | resolve `@handle` → user ID for DMs |
| `users:read.email` | resolve an email → user ID for DMs |
| `files:write` | `upload` command |

## Everything else in the full-access manifest (the headroom)

These aren't required by the current skill but make the app genuinely
"full access" so you can extend it without re-installing:

| Scope | Unlocks |
|-------|---------|
| `channels:write`, `groups:write` | create/archive/rename channels, set topic/purpose, invite |
| `im:write`, `mpim:write` | open DMs / group DMs |
| `users.profile:read`, `users.profile:write` | read & update your Slack profile / status |
| `usergroups:read`, `usergroups:write` | read & manage user groups (@-groups) |
| `files:read` | list & download files |
| `reactions:read`, `reactions:write` | read & add/remove emoji reactions |
| `pins:read`, `pins:write` | read & pin/unpin messages |
| `bookmarks:read`, `bookmarks:write` | read & manage channel bookmarks |
| `stars:read`, `stars:write` | read & manage your saved items |
| `emoji:read` | list custom emoji |
| `dnd:read`, `dnd:write` | read & set your Do-Not-Disturb |
| `links:read`, `links:write` | read & unfurl links |
| `team:read` | read workspace/team info |

## Not included — Enterprise Grid administration (`admin.*`)

The manifest deliberately omits `admin.*` scopes (e.g. `admin.users:write`,
`admin.conversations:write`). These are **Enterprise Grid only**, require an org
owner to approve the app at the org level, and are rarely needed for personal
messaging. If you administer an Enterprise Grid org and need them, add the
specific `admin.*` scopes you need under **OAuth & Permissions → User Token
Scopes**, then re-install — but prefer the narrowest set that does the job.

## Changing scopes after install

Add or remove scopes any time under your app's **OAuth & Permissions** page.
Slack requires a **re-install** ("Reinstall to Workspace") for new scopes to
take effect, which mints a fresh token — overwrite your vault key afterward:

```bash
printf '%s' 'xoxp-NEW-TOKEN' | hq secrets --personal set SLACK_TOKEN_<SLUG>_USER --from-stdin
```
