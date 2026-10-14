---
name: handover-client
description: Hand a client HQ company over to the client for real. Verifies every item of their handover-checklist.md — client team invited and ACTIVE, firm packs in their declared end state, secrets rotated or removed — then, behind an explicit approval gate, runs the hq-pro ownership transfer and reads memberships back to prove the firm's access was reduced to exactly what the client agreed. An item it cannot verify is UNKNOWN, and UNKNOWN blocks. Local-only companies get a clear "requires a cloud-backed company" answer, not a failure.
triggers:
  - handover client
  - hand this company over to the client
  - transfer ownership of a client hq
  - finish the engagement and give them their hq
  - client handover checklist
---

# /handover-client — the handover, executed

`/new-client` stages `companies/{client}/handover-checklist.md` as the **runway**.
This skill flies it: it walks that checklist, refuses to move while anything is
unverified, and only then performs the one irreversible act in the whole client
lifecycle — moving ownership of the company to the client.

Implementation: `../../scripts/handover-client.sh`.
Fixture regression suite: `../../scripts/handover-client-verify.sh`.

## The three rules this skill exists to enforce

**1. Unknown is never done.** Every checklist item resolves to `DONE`,
`INCOMPLETE`, or `UNKNOWN`, and the last two block identically. A checked box is
a human's *claim*; the engine looks for corroborating evidence, and when it
cannot find any it says `UNKNOWN` and stops. No roster is not an empty roster. A
pack with no stay/remove row is not "keep". A membership with no `status` field
is not "active". An unfilled secret table is not "there were no secrets". This
is policy `hq-absent-field-never-means-constraining-value` applied to an action
nobody can take back.

**2. The gate is the only door.** The transfer runs if and only if
`--approval approved` was passed, which the skill passes only after an explicit
in-session human yes. `declined` and *absent* both do nothing at all — no
nomination, no role change, no revoked grant — and both say so. Absent is
UNDECIDED, and UNDECIDED is not approval (policy
`client-service-approval-gate-external-actions`).

**3. Read it back.** After the transfer the engine re-reads the membership
roster and compares it against the end state the checklist declares. An exit
code is not evidence about the state of a membership graph. A mismatch is a
failure with the offending rows named.

## What it verifies, and how

| Checklist section | Mechanical check |
|---|---|
| §1 the client team owns this company | the ACTIVE roster must contain ≥1 client-side member and ≥1 client-side owner/admin. Pending ≠ active. Which people are firm-side comes from `--firm-member` / `--firm-domain`; if neither is given, §1 is **UNKNOWN**. |
| §2 firm packs are in their intended end state | every directory under `companies/{client}/.hq-packs/` must have a stay/remove row in the checklist's table. `remove` → no manifest-owned file may remain (verified through `client-pack.sh status`). `stay` → none may be missing. No row, or a `TODO` row → **UNKNOWN**. |
| §3 secrets rotated or removed | every row in the secret table needs a name and a disposition that actually reads as rotated / deleted / removed / revoked. **Names only — this engine never reads, prints, or requests a secret value.** A literal `none` row is an explicit "the firm held none". |
| §8 sign-off | both sign-off rows must name a person. |
| §8 residual access | the `Residual firm access after sign-off` line must be machine-readable: `none`, or a list of `email[:role]`. Prose is **UNKNOWN** — you cannot verify access against an end state nobody wrote down. |
| every other box | unchecked → `INCOMPLETE`. |

`§2` deliberately delegates to `client-pack.sh status` rather than
reimplementing fork/clean/missing classification. There is one definition of
"this pack file is a fork", and it lives in US-006.

## Verbs

Everything runs in a session bound to the **CLIENT** company. The firm side
arrives as *names* (`--firm-member`, `--firm-domain`), never as a path — the
same discipline as `new-client.sh`'s handoff record and `client-pack.sh`'s
`sourceFirm`.

### `verify` — walk the checklist, change nothing

```bash
handover-client.sh verify --client atlas-widgets \
  --firm-domain northgate.example --firm-member dana@northgate.example
```

Prints a per-item ledger and a verdict. Exit 0 either way — a verdict is an
answer, not a failure. Add `--strict` to make `BLOCKED` exit 1 for CI.

```
  DONE       §1  2 active client-side member(s) on the roster
  DONE       §1  1 client-side owner/admin — access is grantable without the firm
  UNKNOWN    §3  secret 'shared-api-token' has no rotated/deleted disposition recorded
  INCOMPLETE §8  Client sign-off has not been recorded

SUMMARY  31 done, 1 incomplete, 1 unknown
VERDICT  BLOCKED — handover is not offered.
```

### `transfer` — verify, gate, execute, read back

```bash
handover-client.sh transfer --client atlas-widgets \
  --firm-domain northgate.example \
  --to ops@atlaswidgets.example \
  --initiator-role remove \
  --approval approved
```

Order of operations, and it is not negotiable:

1. Re-run the **full verification**. `BLOCKED` → `E_CHECKLIST_BLOCKED`, exit 1,
   nothing offered and nothing touched.
2. If the company is not cloud-backed → print the clear notice and exit **0**.
3. Print the **approval gate**: who becomes owner, what happens to the firm's
   own access, and that this is irreversible from the firm's side.
4. `--approval approved` → run
   `hq company transfer initiate --company <client> --to <target> [...] --yes`.
   `declined` or absent → stop, change nothing.
5. **Read the roster back** and compare it to the declared end state. Mismatch →
   `E_ACCESS_MISMATCH`, exit 1, with the exact rows named.

`--dry-run` prints the exact command it would run and does not run it.

### `verify-access` — the read-back on its own

```bash
handover-client.sh verify-access --client atlas-widgets \
  --firm-domain northgate.example --roster-after /tmp/after.json
```

Use it after a transfer that was accepted later, or after fixing grants by hand.
An unreadable roster is exit 1: **not-read is not not-present.**

### `status` — read-only posture

Cloud posture, roster readability, declared end state, boxes checked. No verdict,
no judgement.

## The approval gate, verbatim

```
APPROVAL GATE — ownership transfer of atlas-widgets
  Becomes owner:  ops@atlaswidgets.example
  The firm will:  be REMOVED from the company entirely
  Declared end state after sign-off: none

  This nominates ops@atlaswidgets.example as owner. Ownership moves when THEY
  accept, and when it does, the owner role, billing authority and vault custody
  all move with it. From the firm's side that is IRREVERSIBLE: the firm cannot
  undo it unilaterally — only the new owner can transfer the company back.
```

Ask the human. One question, plainly, with those three facts in it. Pass
`--approval approved` only on an explicit yes, and `--approval declined` on a no
— declining is a recorded outcome, not a silent skip.

`--initiator-role` is the firm's own disposition and is **omitted by default**,
which lets the server apply its reversible "stay on as admin" default. `remove`
is the only value that takes the firm off the company, and it can only ever
arrive from an explicit flag. `owner` is refused outright: a handover where the
firm keeps `owner` is not a handover.

## Two-party by construction

`initiate` **nominates**. Ownership does not move until the nominee runs
`hq company transfer accept` in their own session. That is the US-010 design and
this skill does not route around it — it cannot accept on the client's behalf,
and it should not try to.

So a real handover is usually two sittings:

1. Firm side: `/handover-client` → verify → gate → `initiate`.
2. Client side: the nominee accepts. Then re-run `verify-access` to confirm the
   firm's access actually landed where the checklist says.

## Local-only companies

```
NOTE   ownership transfer requires a cloud-backed company.
       company.yaml has no 'cloud' key — UNDECLARED, which is unknown, not cloud-backed.
       A local-only HQ company has no membership graph to move: there is no
       owner row, no vault custody and no billing authority to hand over. The
       checklist above is satisfied and NOTHING was changed.
NEXT   run /designate-team atlas-widgets to make this company cloud-backed,
       then re-run /handover-client.
```

Exit 0. A local-only company is a legitimate state, not an error — and an
*undeclared* `cloud:` key resolves to local, because unknown never authorizes a
cloud action.

## Roster sources

| Source | When |
|---|---|
| `--roster <path>` | a JSON array of `{personEmail, role, status}` (the `hq members list` API shape), or the raw text of `hq members list`. Used for review, for CI, and for fixtures. |
| default | read live through `--hq-bin` (`hq members list --company <slug>`). Only attempted on a cloud-backed company. |

Either way, a source that cannot be parsed into an *active-member view* is
`unknown` — never an empty roster. The pending-invite view is rejected outright
rather than mistaken for the active one.

## Errors

| Code | Meaning |
|---|---|
| `E_SESSION_UNKNOWN` / `E_SESSION_SCOPE` | the session is not bound to this client company. Unknown is not authorization. |
| `E_NO_CHECKLIST` | no `handover-checklist.md`. Without it there is no declared end state, and no end state means no transfer. |
| `E_CHECKLIST_BLOCKED` | incomplete and/or unknown items remain. Nothing was offered or changed. |
| `E_TRANSFER_FAILED` | the transfer command failed. State is **unknown**, not unchanged — check `hq company transfer status` before retrying. |
| `E_READBACK_UNKNOWN` | the nomination went in but the roster could not be re-read. Firm access is unverified. |
| `E_ACCESS_MISMATCH` | the world and the checklist disagree about the firm's residual access. |

## Verification

```bash
bash core/packages/hq-pack-client-service/scripts/handover-client-verify.sh
```

Fixture-only, on a throwaway HQ root, with two independent safety nets: a PATH
shim layer that records any attempt to invoke `curl`/`wget`/`hq`/`gh`/`aws`/
`ssh`/`scp`/`nc`/`open`, and a mocked transfer surface behind `--hq-bin` that
records exact argv. It covers the blocking guards, the gate (declining proved
byte-identical with a checksum manifest), the read-back including seeded
mismatches, and the local-only path — and it re-runs the guard scenarios against
deliberately broken copies of the engine to prove the tests can actually fail.

**Not covered: a live/staging smoke test against a throwaway cloud company.**
That is an external, irreversible action needing the owner's explicit approval,
and the US-010 routes cannot deploy yet regardless — `vault-api-hq-prod` is at
the 600-route HTTP API quota and the increase has not landed. Until that smoke
runs, treat the cloud leg of this skill as *unproven against a real stack*.
