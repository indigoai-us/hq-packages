---
name: presenter-mode
description: Turn a self-contained HTML deck into an hq-deploy–hosted presentation with TWO cloud-synced links — a presentation link (the slides) and a notes/transcript link (your teleprompter) that stay in sync across devices over a zero-backend PubNub bridge. Use when asked to "set up presenter mode", "present this deck", "give me a synced presentation + notes link", "deploy the deck with speaker notes", or "two links — one for the slides, one for my script".
allowed-tools: Read, Grep, Glob, Edit, Write, Bash(.claude/skills/presenter-mode/scripts/check-deck.sh:*), Bash(.claude/skills/presenter-mode/scripts/presenter-links.sh:*), Bash(bash:*), Bash(cp:*), Bash(mkdir:*), Bash(ls:*), Bash(cat:*), Bash(grep:*), Bash(openssl:*)
---

# Presenter Mode

Take a self-contained HTML deck and ship it as an **hq-deploy–hosted presentation** with **two cloud-synced links**:

- **Presentation link** — the slides, full-screen, for the projector/external screen.
- **Notes / transcript link** — your teleprompter: written script + bullets toggle, current/next slide thumbnails. Keep it on your laptop.

Both links share one `?sync=<room>` so advancing on either device moves the other within ~1 second, over a public PubNub REST channel — **no backend, baked into the static HTML**. A third, sync-free **audience link** is also produced for safely sharing the deck afterward (it can never follow or hijack the room).

This skill generalizes the presenter machinery built for a production conference keynote.

> **Path note.** When installed as a pack, this skill is symlinked to `.claude/skills/presenter-mode/`, so its scripts and templates are referenced below as `.claude/skills/presenter-mode/…`. If you authored it as a personal skill, substitute your `personal/skills/presenter-mode/…` path.

## URL scheme (the contract)

For a deployed base URL `B` and a room code `R`:

| Link | URL | Role |
|---|---|---|
| Presentation | `B/?present=1&sync=R` | Slides, full-screen. Drives + follows. |
| Notes / transcript | `B/?notes&sync=R` | Teleprompter. Drives + follows. |
| Audience | `B` | Clean public deck. Inert — never joins the room. |

In-deck keys: **P** present · **N** pop out notes (carries `sync`) · **B** script/bullets · **← → / Space** navigate · **Home/End** jump · **Esc** exit.

## Workflow

### 1 — Resolve the deck source
Accept a path to a self-contained HTML file, a directory containing `index.html`, or an already-deployed deck's source. Confirm it is one HTML file (hq-deploy serves SPA-style — never split a deck across multiple `.html` files).

### 2 — Inspect the contract
Run the detector:

```
bash .claude/skills/presenter-mode/scripts/check-deck.sh <deck.html>
```

Act on the verdict:
- **READY** — the deck already has the full presenter machinery. Skip to step 4.
- **PARTIAL / NEEDS-BUNDLE** — inject the bundle (step 3).
- **NOT-A-DECK** — the deck has no `.deck-slide` slides. Either wrap each slide in `<section class="deck-slide">…</section>` inside a `<div class="deck">`, or stop and tell the user the deck structure isn't compatible.

### 3 — Inject the presenter bundle (only if not READY)
Insert the contents of `.claude/skills/presenter-mode/templates/presenter-bundle.html` immediately **before `</body>`**. The bundle is self-contained (style + notes panel + nav core + notes view + sync bridge) and idempotent — its `<!-- HQ PRESENTER MODE: bundle start -->` marker means "already injected; don't add twice."

Then build the **notes payload** — a `<script id="notes-data" type="application/json">…</script>` tag (schema in `.claude/skills/presenter-mode/templates/notes-data.example.json`). Source the `spoken` script from a `SCRIPT.md`/teleprompter file if one exists, else from each slide's own content; derive `bullets` from slide bullet markup. `thumb` (a `data:image/jpeg;base64` slide thumbnail) is **optional** — omit it and the notes view simply shows no thumbnail. **`slides.length` must equal `total`,** and entry order must match deck order (see the slide-reorder policy below).

Verify locally: open `<deck>?notes` and `<deck>?present=1` and confirm the notes view renders and slides advance.

### 4 — Deploy
Deploy via the **/deploy** skill (hq-deploy) — do **not** hand-roll uploads. Capture the returned base URL. (Any static host works too; the machinery is pure static HTML.)

**Access decision (surface this).** The notes/script are embedded in the same deployment, so on a `public` deploy **anyone who appends `?notes` can read your speaker script**. Choose:
- Talk content is meant to be public → deploy **public**. The audience link is freely shareable.
- The script is sensitive → deploy with a gate (**password** or **company**) so `?notes` isn't world-readable, and share the gated links only with yourself/your co-presenter.

Confirm the access mode with the user before deploying if there's any doubt.

### 5 — Emit the links
Generate the room and the three URLs (the room is random unless the user wants a memorable one):

```
bash .claude/skills/presenter-mode/scripts/presenter-links.sh <base-url> [room]
```

Surface the **presentation link** and the **notes/transcript link** prominently (plus the audience link and the printed cheat sheet).

## Deck requirements (what the bundle assumes)
- Slides are `<section class="deck-slide">` elements inside `<div class="deck">`.
- Optional progressive reveals are elements with class `frag` (revealed by adding class `shown`).
- The deck does **not** already ship its own slide-navigation keyboard handler (the bundle installs one). A deck whose own nav already exposes the hooks below is detected as READY and skips injection.
- Hooks the bundle exposes/uses: `window.__knApplyDeck(n)`, `window.__knApplyNotes(n)`, `window.__knPub(n)`.

## Gotchas (policies shipped with this pack)
- **Scale-to-fit** (`hq-deck-present-mode-scale-to-fit`): pin any `vw`/`vh` units in slide content to `px` first, or they fight the `scale(var(--fit))` transform and break layout. 720p → `--fit=1`; 1080p → a clean 1.5×.
- **Reordering a slide** (`hq-deck-slide-reorder-three-coordinated-edits`): reorder by content-match in THREE places — the `.deck-slide` elements (+ any hardcoded `NN / TOTAL`), the `notes-data` `slides` array (renumber each `n`), and the source `SCRIPT.md`. Missing one silently desyncs the notes from the slides.
- **Cross-device sync** (`hq-cross-device-deck-sync-pubnub-bridge`): the bridge is gated on `?sync=<room>` so the public audience URL never joins; echo-guarded by a per-client id + `window.__knApplying`; degrades to manual arrow nav if the network is flaky. The public PubNub demo keyset is unauthenticated — fine for ephemeral slide-index pings, but do not put anything sensitive on the channel (it only ever carries a slide number).

## Files in this skill
- `templates/presenter-bundle.html` — the verbatim, idempotent presenter machinery to inject.
- `templates/notes-data.example.json` — the notes payload schema + example.
- `scripts/check-deck.sh` — contract detector (READY / PARTIAL / NEEDS-BUNDLE / NOT-A-DECK).
- `scripts/presenter-links.sh` — room generator, three-link builder, and run-of-show cheat sheet.
