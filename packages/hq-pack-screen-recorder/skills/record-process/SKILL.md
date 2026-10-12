---
name: record-process
description: >-
  HQ Capture: record a process on this Mac for the active HQ company, then
  trim it, place the camera, export the video and draft a step-by-step guide
  by talking to the agent. Use when the user says /record-process, "record my
  screen", "record how I do this", "make an SOP from a recording", "screen
  record this process", or pastes a "Continue my HQ Capture recording for"
  prompt. Capture, editing and drafting stay on the Mac.
---

# /record-process: HQ Capture

HQ Capture is a small Mac app that only records. Everything after the
recording (summary, trimming, camera placement, export, the guide) happens
here, in this session, through `hq-record-process.sh`. The app never changes
the original layers; every edit is a new revision inside the recording.

**Script (after install):** `core/packages/hq-pack-screen-recorder/scripts/hq-record-process.sh`
**Setup guide:** `core/knowledge/screen-recorder/setup.md`

```bash
R=core/packages/hq-pack-screen-recorder/scripts/hq-record-process.sh
bash "$R" doctor                    # can this Mac build and run HQ Capture?
bash "$R" start                     # build if needed, open HQ Capture for the session's company
bash "$R" wait [--timeout 540]      # follow the recording until it is saved or closed
bash "$R" status                    # one status read
bash "$R" stop                      # finish the recording (saved) or close the app
bash "$R" run <mode> <package> [args]   # headless agent command on a saved recording
bash "$R" resume "<pasted prompt>"  # check a resume prompt and return its package
```

`start`, `wait`, `status` and `stop` print one JSON object (`wait` also
prints one `{"event":"state",...}` line per change). `run` prints whatever
the app prints for that mode and passes its exit code through. Launcher
refusals print `{"ok":false,"error":...,"message":...}` and exit 1 (3 for
`run` and `resume`, so they never collide with the app's own codes).

`run` modes: `describe`, `transcribe`, `edit`, `export-video`, `frame`,
`extract-screen-evidence`, `draft-sop`, `export-sop`, `sync-package`. The
launcher refuses a package outside the bound company's `recordings/` folder
and refuses `--company`, `--destination`, `--hq-root` or a second mode in the
arguments. App exit codes: 0 done, 1 refused (read the message), 2 usage or
error, 130 cancelled.

## 1. Confirm the company

Read the session company with `bash core/scripts/hq-session.sh get company_slug`.
If it is empty or `personal`, ask which company the recording belongs to and
bind it before continuing. Tell the user in one line that the recording saves
to that company's `recordings/` folder. Never record, edit or read a
recording for any other company.

## 2. Check the Mac and open HQ Capture

1. Run `doctor`. If `ok` is false, give the user the `fix` line in plain
   words (usually `xcode-select --install`, a one-time Apple download). Do not
   install it yourself.
2. Run `start`. The first run, and the first run after a pack update, builds
   the app on this Mac (about a minute); say so first. `start` returns
   `state: "awaiting-start"`: the window is open and nothing is recording yet.
   The user picks the screen, camera and microphone and presses Start.
3. If macOS asks for Screen Recording, Camera or Microphone access, the user
   allows it and chooses **Quit and Reopen**. The reopened app keeps the
   company binding for 10 minutes, so no new `start` is needed. If more than
   10 minutes pass, run `start` again.
4. `already-open` means HQ Capture is already open. Show `status` and ask
   whether to keep using it or `stop` it first.

## 3. Wait for the recording

Run `wait` in the foreground. It returns within the timeout (default 540
seconds) and exits:

- **3 (still open):** the last line is the current status. Report it in one
  line (`recording`, `paused`, `durationSeconds`) and run `wait` again. Keep
  re-arming while the state is `awaiting-start`, `recording` or `finalizing`.
- **0, state `saved`:** go to step 4. The status carries `recording` (the
  package path relative to HQ) and `resumePrompt`.
- **0, state `closed`:** the user closed the app without saving. Say so.
- **0, state `failed` or `lost`:** report `reason` plainly. Recorded files
  that were saved stay in the company's `recordings/` folder.

If the user asks you to stop, run `stop`; a recording in progress is finished
and saved (`reason: "stop-requested"`).

## 4. On save: summarize

The package is `<HQ root>/<recording>` from the saved status. Run, in order:

```bash
bash "$R" run describe "<package>" --json
bash "$R" run transcribe "<package>" --json
```

Then tell the user, in a few short lines:

- the length (`durationSeconds`) and which layers were captured (`tracks`),
- what was said, in two or three sentences from the transcript,
- pauses (`pauses`), long silences (`microphoneSilence`), camera or
  microphone gaps, and filler words you can see in `words`
  ("um", "uh", "so", false starts) near the start or end.

If `transcript.status` is `none`, `stale` or `unreadable` after `transcribe`,
say there is no usable narration and skip transcript-based suggestions.

Offer the edits that the summary suggests (trim a slow start, drop a
trailing "ok, that's it", move or hide the camera), then export and the
guide.

## 5. Edit by conversation

Every `edit` writes a new revision; the original layers are never touched.
Edits combine: an edit with only `--camera` keeps the current trim.

```bash
bash "$R" run edit "<package>" --in 4.2 --out 181.5 --json   # keep 4.2s..181.5s
bash "$R" run edit "<package>" --camera 0.8,0.8,0.18 --json
bash "$R" run edit "<package>" --camera-hidden true --json
```

- **Trim the start or end.** Find the times in the transcript `words`
  (`start`/`end` in seconds). To drop everything before a phrase, use
  `--in` at that phrase's first word `start`; to drop everything after, use
  `--out` at the last kept word's `end`. Leave about 0.3 seconds of margin.
- **Cut out a middle part.** Not supported yet: an edit keeps one range, and
  `--cut` is refused with exit 1. If the unwanted part is close to the start
  or end, offer to trim to it instead. Otherwise tell the user plainly that
  removing a section from the middle isn't available yet.
- **Camera.** `x,y` is the top-left corner of the camera bubble and `w` its
  width, all as fractions of the screen (0 to 1). The bubble keeps a 16:9
  shape and is pulled back inside the screen, so `1,1,w` sits flush in the
  bottom-right corner. Presets:

  | User says | `--camera` |
  |---|---|
  | bottom right (default) | `0.8,0.8,0.18` |
  | bottom left | `0.02,0.8,0.18` |
  | top right | `0.8,0.03,0.18` |
  | top left | `0.02,0.03,0.18` |
  | smaller | keep x,y, width `0.12` |
  | larger | keep x,y, width `0.3` |

  Hide it with `--camera-hidden true`; show it again with `false`.
- After each edit, report `keptStart`, `keptEnd`, `keptSeconds` and the
  camera placement from the result, in plain words.

## 6. Preview, then export the video

Before exporting, render one or two stills at moments that show the result
(the first kept second, and a moment with the camera visible). Write them
outside the package, to a temporary folder:

```bash
bash "$R" run frame "<package>" --at 5 --out /tmp/hq-capture-preview-1.png --json
```

Show the stills to the user (delegate image viewing to a sub-agent when the
session already holds several images) and ask whether to export. Then:

```bash
bash "$R" run export-video "<package>" --json
```

Report the exported `path` and offer to reveal it: `open -R "<path>"`.

## 7. Draft the step-by-step guide

```bash
bash "$R" run extract-screen-evidence "<package>"
bash "$R" run draft-sop "<package>"
```

- `extract-screen-evidence` exit 1 means the screen text was not reliable;
  the draft will use narration alone. Tell the user.
- `draft-sop` exit 0 prints the draft as JSON. Show the steps in chat as a
  numbered list with each step's evidence and any uncertainty flags.
- `draft-sop` exit 1 means it refused (too little narration or too few
  actions), drafted only part, or found no supported steps. Repeat its
  message plainly. Do not write the missing steps yourself and do not invent
  steps from the video; offer to record again with more narration. A partial
  draft can be retried with `--retry-failed`.
- Collect the user's changes in chat: reorder, reword, drop a step, or pick a
  different screenshot. Never present the draft as approved.

**Current limit:** HQ Capture has no command yet to apply review changes to a
draft or to record the user's approval, and `export-sop` only exports an
approved draft (exit 1 otherwise). Tell the user the draft is saved in the
recording, list the changes they asked for, and say the guide can be
finalized once that review step is available. Do not edit the draft files by
hand.

When a draft is approved, `bash "$R" run export-sop "<package>"` writes the
guide (exit 0); exit 1 means it is not approved.

## 8. Sync

When the user agrees, upload the recording to the company vault:

```bash
bash "$R" run sync-package "<package>"
```

Exit 1 means try again later (for example, offline); exit 2 is an error to
report.

## Resume from a pasted prompt

When a session ends before the edit, HQ Capture shows a prompt to paste into
a session. Its exact shape is:

```
Continue my HQ Capture recording for <company> at <absolute path to .hqrec>: show me what was recorded, then trim, place the camera, export the video and draft the step-by-step guide.
```

When the user pastes it (line breaks from wrapping are fine), run:

```bash
bash "$R" resume "<the pasted text>"
```

It returns `{"ok":true,"company":...,"package":...}` only when the company
matches the session's bound company and the path is a recording directly
inside that company's `recordings/` folder. On `company-mismatch`, say which
company the recording belongs to and ask the user to open a session for it;
do not rebind. On any other refusal, say the prompt doesn't point to a
recording in this company. On success, continue at step 4 with `package`.

## Rules

- One HQ Capture window at a time.
- The company is fixed for the life of a recording. Changing the session's
  company does not move an open recording.
- Recordings, transcripts, stills and drafts stay on the Mac and in the
  company vault. Do not send them to a cloud model or another company.
- Never edit files inside a `.hqrec` package directly; use `run`.
- Generated guides and skills are drafts until the user approves them.
