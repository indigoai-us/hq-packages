---
# Ontology entities — leave empty on creation.
entities: []
---
# Handover checklist — {{CLIENT_NAME}}

> **This file lives in the client's own HQ company (`{{CLIENT_SLUG}}`), so it is
> client-visible.** Nothing firm-internal belongs here: no margin, no pipeline
> commentary, no risk notes, no internal owner assignments. Firm-internal state
> stays in the firm's own engagement record and never crosses into this file.
> (Policy `client-service-internal-external-split`.)
>
> Staged by `/new-client` on **{{TODAY}}**. It is the **executable runway** for
> `/handover-client`: every box below is something that must be true before this
> company can stand on its own without {{FIRM_NAME}}. Handover walks this file,
> top to bottom, and refuses to declare handover complete while any box is
> unchecked or any state is unknown.

## How to read this file

- `[ ]` means **not done**. `[x]` means **done and verified**, not "probably fine".
- **Unknown is never done.** If you cannot verify an item, leave the box unchecked
  and write what you checked and what you could not determine. An unverifiable
  item blocks handover; it does not pass by default.
- Every item that has a mechanical check carries the command that performs it.
  Run the command; do not assert from memory.
- Items marked **gated** are outward-facing — a person gets an email, a client
  surface changes, or an access grant moves. They wait for explicit human
  approval in-session, every time (policy
  `client-service-approval-gate-external-actions`).

---

## 1. The client team owns this company

- [ ] At least one **client-side** person has an accepted, active membership in
      `{{CLIENT_SLUG}}` — not a pending invite. A pending invite is not ownership.
- [ ] At least one of those client-side people holds an **owner/admin** role, so
      access can be granted and revoked without the firm.
- [ ] Every invite that was intended has actually been sent **(gated)** and its
      acceptance confirmed. Invites still listed as pending below are unfinished
      work, not a formality.

```bash
hq members list --company {{CLIENT_SLUG}}
```

**Invites staged at creation:** {{INVITE_STATUS}}

## 2. Firm packs are in their intended end state

Firm capability arrived here by copy-with-provenance, recorded in
`.hq-packs/<pack>/.hq-pack-manifest.json`. Decide, per pack, whether it **stays**
(the client keeps using it) or is **removed** at handover. There is no default —
"nobody said" is not "keep".

- [ ] Every applied pack has an explicit stay/remove decision, recorded here.
- [ ] For packs that stay: `client-pack.sh update` has been run, and every
      reported `FORK-skipped` file is intentional (the client edited it; the edit
      survives on purpose).
- [ ] For packs that are removed: `client-pack.sh remove` has been run, and the
      files it **kept** (forks, unknown-sha entries, client-created files) have
      been reviewed — those are the client's bytes and they stay.
- [ ] No pack file remains that the client cannot read or maintain on their own.

```bash
# read-only classification of every manifest-owned file
bash <pack>/scripts/client-pack.sh status --client {{CLIENT_SLUG}} --pack <pack-name>
```

| Pack | Decision (stay / remove) | Run | Forks kept |
|---|---|---|---|
| TODO | TODO | TODO | TODO |

## 3. Secrets are rotated or removed

**Names only, never values, anywhere in this file or in any HQ document.**

- [ ] Every secret the **firm** issued, generated, or held for this engagement is
      either **rotated** (the client holds the new value and the firm never saw
      it) or **deleted**.
- [ ] Every secret the **client** owns is held by a client-side person, not by a
      firm member's account.
- [ ] No credential the firm can still use grants access to a client system.
- [ ] The engagement's adapter bindings that referenced a firm-held secret have
      been re-pointed at a client-held one, or unbound.

```bash
hq secrets list --company {{CLIENT_SLUG}}   # NAMES only — never --reveal, never a value
```

| Secret name | Owned by after handover | Rotated / deleted | Date |
|---|---|---|---|
| TODO | TODO | TODO | TODO |

## 4. File access and ACLs

- [ ] Firm groups and firm individuals have been removed from every grant on this
      company's vault paths, or the remaining access is explicitly agreed in
      writing and recorded below.
- [ ] Every share link the firm minted against this company's paths is expired or
      revoked. A single-use link that was never used is still a capability.
- [ ] The client can grant and revoke access themselves (follows from §1).

```bash
hq files acl list --company {{CLIENT_SLUG}}
```

**Access the firm deliberately retains after handover (must be empty, or agreed):**
TODO

## 5. Client-facing surfaces

- [ ] Every artifact shared to a client-facing surface is either **transferred**
      to the client or **revoked** — `revoke_share` where the portal binding
      declares it, by hand where it does not. An absent `revoke_share` capability
      means it is a manual step, not that there is nothing to revoke.
- [ ] The client-facing surface itself (site, project tool, shared drive) is
      owned by a client account, or has been retired.
- [ ] A final client-facing update has been published **(gated)**, or the decision
      not to publish one is recorded here.
- [ ] The CRM mirror — if the firm kept one — reflects the closed state. It is a
      derived mirror; the firm's engagement record remains the source of truth on
      the firm's side.

## 6. Commercials are closed out

- [ ] Every invoice is sent **(gated)**, paid, voided, or explicitly written off —
      no invoice is left in an unknown state.
- [ ] The final balance is agreed and recorded on both sides.
- [ ] The governing agreement's end state is recorded: completed, terminated, or
      continuing under new terms.
- [ ] The executed copy of every agreement is somewhere the **client** can reach
      without the firm.

## 7. Knowledge and continuity

- [ ] The client company contains what a client-side operator needs to keep going:
      how the work is run, where things live, what to do next.
- [ ] No firm-internal document was copied into this company during the
      engagement. If one was, it is removed **before** handover, not after.
- [ ] Open threads, in-flight work, and known risks that the **client** owns are
      written down here in client-safe language.

**Open threads at handover:**
- TODO

## 8. Sign-off

Handover is complete only when every box above is checked **and** both sides say
so. An unchecked box is not a formality to clear later; it is the reason the
handover is not done.

| | Name | Role | Date |
|---|---|---|---|
| Firm sign-off | TODO | TODO | TODO |
| Client sign-off | TODO | TODO | TODO |

**Residual firm access after sign-off (should be "none"):** TODO

---

*Generated from `templates/handover-checklist.md` in `hq-pack-client-service`.
Edit it freely — this is the client's file now. `/handover-client` reads the
checkboxes and the tables; it never rewrites your edits.*
