# hq-pack-presenter-mode

Turn any self-contained HTML slide deck into an **hq-deploy–hosted presentation
with two cloud-synced links** — one for the slides, one for your teleprompter —
that stay in sync across devices with **no backend**. Generalized from a
production conference keynote.

## What you get

Point the skill at a deck and it deploys it, then hands you three links:

| Link | URL shape | Use it on |
|---|---|---|
| **Presentation** | `…/?present=1&sync=<room>` | the projector / external screen |
| **Notes / transcript** | `…/?notes&sync=<room>` | your laptop (script + bullets + thumbnails) |
| **Audience** | `…` (no `sync`) | share publicly afterward — never follows or hijacks |

Advance on either device and the other follows within ~1 second. The sync rides
inside the static HTML over PubNub's public REST demo keyset (gated on
`?sync=<room>`), so there's nothing to host and nothing to authenticate — and it
degrades gracefully to manual arrow navigation if the network drops.

## Install

```
hq install github:indigoai-us/hq-packages#packages/hq-pack-presenter-mode
```

After install the skill is exposed as `/hq-pack-presenter-mode:presenter-mode`
(master-sync namespaces packs as `<pack>:<skill>`), and the three deck-authoring
policies auto-load.

## Quick start

```
/hq-pack-presenter-mode:presenter-mode      # then point it at a deck (.html file or dir)
```

The skill will: detect whether the deck already has presenter mode, inject the
machinery if not, build the speaker-notes payload, deploy via `/deploy`, mint a
sync room, and print the three links plus a one-screen run-of-show cheat sheet.

## How it runs at the podium

- Open **Notes** on your laptop, **Presentation** on the audience screen.
- Drive from either with **← / → / Space**; the other follows.
- Keys: **P** present · **N** pop-out notes · **B** script ↔ bullets · **Home/End** jump · **Esc** exit.
- Both Presentation and Notes must carry the **same** `?sync=<room>` to stay linked.

> **Privacy:** the speaker script is embedded in the same deployment, so a
> `public` deploy makes `?notes` world-readable. If the script is sensitive, the
> skill deploys behind a password or company gate instead — it will check with you.

## Layout

```
packages/hq-pack-presenter-mode/
├── README.md                                  ← you are here
├── package.yaml                               ← HQ pack manifest
├── package.json                               ← npm-side manifest
├── skills/
│   └── presenter-mode/
│       ├── SKILL.md                           ← the presenter-mode skill
│       ├── templates/
│       │   ├── presenter-bundle.html          ← injectable presenter machinery
│       │   └── notes-data.example.json        ← speaker-notes schema + example
│       └── scripts/
│           ├── check-deck.sh                  ← deck contract detector
│           └── presenter-links.sh             ← room + three-link + cheat-sheet generator
└── policies/                                  ← deck-authoring guardrails (auto-load)
    ├── hq-deck-present-mode-scale-to-fit.md
    ├── hq-cross-device-deck-sync-pubnub-bridge.md
    └── hq-deck-slide-reorder-three-coordinated-edits.md
```

## Deck contract

The injectable bundle expects slides as `<section class="deck-slide">` elements
inside a `<div class="deck">`, optional progressive reveals as `.frag` elements,
and a `<script id="notes-data" type="application/json">` payload for the notes
view. It exposes `window.__knApplyDeck(n)`, `window.__knApplyNotes(n)`, and
`window.__knPub(n)`. A deck that already satisfies the contract is detected as
`READY` and deployed as-is. See `skills/presenter-mode/SKILL.md` for the full
workflow.

## License

MIT
