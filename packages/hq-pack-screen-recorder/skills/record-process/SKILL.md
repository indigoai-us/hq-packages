---
name: record-process
description: >-
  Record a process on this Mac for the active HQ company and turn it into an
  SOP or skill draft. Use when the user says /record-process, "record my
  screen", "record how I do this", "make an SOP from a recording", or "screen
  record this process". Opens the local HQ Recorder app bound to the company's
  recordings folder; capture and processing stay on the Mac.
---

# /record-process — record a process for this company

This skill drives `scripts/hq-record-process.sh`, which builds and opens the
local **HQ Recorder** app. Every command prints one JSON object.

**Script (after install):** `core/packages/hq-pack-screen-recorder/scripts/hq-record-process.sh`
**Setup guide:** `core/knowledge/screen-recorder/setup.md`

```bash
R=core/packages/hq-pack-screen-recorder/scripts/hq-record-process.sh
bash "$R" doctor       # can this Mac build and run the recorder?
bash "$R" start        # open the recorder for the session's company
bash "$R" status       # what is the recorder doing?
bash "$R" stop         # ask the recorder to stop and close
```

## Steps

1. **Confirm the company.** Read the session company with
   `bash core/scripts/hq-session.sh get company_slug`. If it is empty or
   `personal`, ask the user which company the recording belongs to and bind it
   before continuing. Tell the user, in one line, that the recording will save
   to that company's `recordings/` folder.
2. **Check the Mac.** Run `doctor`. If `ok` is false, give the user the `fix`
   line in plain words (usually: run `xcode-select --install`, a one-time Apple
   download). Do not try to install it yourself.
3. **Open the recorder.** Run `start` (pass `--company <slug>` only if the user
   named a different company and you have bound it). The first run compiles
   the app on this Mac, which takes about a minute; say so before starting.
   `start` returns `state: "awaiting-start"`: the app is open and showing the
   company, but **nothing is being recorded**. The user picks sources and
   presses Start in the app. Never describe the recording as started from
   this step.
4. **While it is open,** use `status` when the user asks how it is going.
5. **To finish,** run `stop` when the user asks. Report the final state.

## Rules

- One recorder at a time. If `start` returns `already-open`, show the current
  `status` and ask whether to stop it first.
- The company is fixed for the life of a recording. Changing the session's
  company does not move an open recording.
- Recordings, transcripts and drafts stay on the Mac and in the company vault.
  Do not send recording content, transcripts or screenshots to a cloud model
  or another company.
- Generated SOPs and skills are drafts. Never approve, register or run one
  without the user's explicit review.

## Current limits (0.1.0)

The recorder opens, binds to the company and reports status. Screen, webcam
and narration capture, the editor, export and SOP drafting are not built yet;
the Start button is disabled. Say this plainly if the user expects to record.
