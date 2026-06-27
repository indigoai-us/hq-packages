---
name: draft-followup
description: Compose a follow-up email for a given account/contact from their CRM record + recent activity, written in plain English for the recipient and shown as a draft for human approval. Reads the company's mail silo for thread context (connected) or degrades to a paste-ready body (native). Never sends. Company-agnostic; resolves owner, voice, and silos from companies/{co}/client-management.yaml.
allowed-tools: Bash, Read, Grep
---

# Draft follow-up — Email Operator

Turn "this account needs a touch" into a **ready-to-review follow-up email**,
composed from the account's CRM record and recent activity. The output is always
a **draft** — a human approves before anything is sent.

## Resolve context first

1. Active company `{co}`. Read `companies/{co}/client-management.yaml` for:
   - **`owner`** — the sender identity and the voice the email is written in.
   - **`silos.mail`** — the mailbox backend (or its absence).
   - **`silos.pipeline`** — where the account + contact + stage live.
   - **`stages`** — the company's own pipeline vocabulary.
2. The grounding corpus = the company's qmd collections (from `manifest.yaml`
   `qmd_collections`): the company collection plus its `-meetings` / `-signals`
   collections where they exist. **Search only `{co}`'s collections** —
   cross-company retrieval is a category-1 violation.

## Read before you write

1. **Account + contact + stage.** Pull the named account from the pipeline silo
   (connected → the connection's read capability via `hq secrets exec`; native →
   `/crm`): company, the contact you're writing to, current stage (in the
   company's own `stages`), and any open items.
2. **Recent activity.** What's happened lately — last touch, last meeting, the
   reason a follow-up is due. Pull from the activity timeline and, where it
   exists, the `-meetings` / `-signals` collections (cite what you use).
3. **Thread context (mail silo branch).**
   - `silos.mail.mode: connected` → drive the referenced connection
     (`companies/{co}/connections/<slug>.yaml`) to find the prior thread with
     this contact for read/search, reaching credentials only via
     `hq secrets exec`. Summarize the through-line briefly.
   - `silos.mail.mode: native` or no mail silo → there is no connected mailbox.
     Say so plainly and proceed to a paste-ready body the human can send by hand.

## Compose the draft

Write the follow-up **for the recipient, in plain English**, in the company's
current voice as found in its corpus. Ground every specific in the record —
never invent a fact, a commitment, or a quote. Keep it concise and purposeful:
acknowledge the last interaction, advance the relationship toward the next stage,
and make one clear ask. If the voice or a claim is ambiguous, ask rather than
guess.

## Output

```markdown
# Follow-up draft — {Account} / {Contact}

**Stage:** {stage} · **Last touch:** {date / what} · **Sender:** {owner}
**Mail silo:** {connected:<vendor> | native — paste-ready, not sent}

**To:** {contact email if known}
**Subject:** {subject}

{body — plain English, in the company's voice, grounded in the record}

---
_Grounding:_ {CRM record · thread {mailbox/sender/date} · corpus {doc}}
```

## Rules

- **Draft, never send.** This produces a draft. Sending, replying-for-real,
  archiving, labeling, or any mailbox/CRM state change needs explicit human
  approval naming the exact action.
- **Tenant isolation:** only `{co}`'s config, connection, and collections.
- **Cite everything:** every fact in the body traces to the CRM record, the
  thread, or a corpus doc — no fabricated specifics.
- **Secrets only via `hq secrets exec`:** never read, print, or inline a
  credential.
- **Degrade gracefully:** when the mail silo is native/unconnected, say so and
  still hand back a paste-ready body.
