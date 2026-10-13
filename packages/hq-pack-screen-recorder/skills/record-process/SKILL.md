---
name: record-process
description: >-
  HQ Capture: record a process on this Mac for the active HQ company, then
  trim it, place the camera, export the video and draft a step-by-step guide
  by talking to the agent. Use when the user says /record-process, "record my
  screen", "record how I do this", "make an SOP from a recording", "screen
  record this process", or pastes a "Continue my HQ Capture recording for"
  prompt. Capture, transcription and guide drafting run on the Mac; the
  session agent reads the transcript, drafts and stills it shows.
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
`extract-screen-evidence`, `draft-sop`, `review-sop`, `list-frames`,
`approve-sop`, `export-sop`, `sync-package`. The
launcher refuses a package outside the bound company's `recordings/` folder,
a `frame --out` path inside another company's folder, and `--company`,
`--destination`, `--hq-root` or a second mode in the arguments.

When HQ Capture is open for another company, `status` and `wait` return only
`{"ok":true,"state":"busy-other-company"}` and `stop` refuses. Tell the user
HQ Capture is in use in another company's session and must be finished there
first. Do not try to find out which company. Once that app has quit, `status`
returns `{"ok":true,"state":"none"}`, `stop` does nothing and `start` opens HQ
Capture for this company as usual. App exit codes: 0 done, 1 refused (read the message), 2 usage or
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
5. `busy` (exit 1) means another session is opening HQ Capture right now.
   Tell the user that in one line, wait a few seconds, then run `status`. If
   it shows the window is open, treat it as `already-open`. If it shows
   `none`, run `start` again.

## 3. Wait for the recording

Run `wait` in the foreground. It returns within the timeout (default 540
seconds) and exits:

- **3 (still open):** the last line is the current status. Report it in one
  line (`recording`, `paused`, `durationSeconds`) and run `wait` again. Keep
  re-arming while the state is `awaiting-start`, `recording` or `finalizing`.
- **0, state `saved`:** go to step 4. The status carries `recording` (the
  package path relative to HQ) and `resumePrompt`. It can also carry `issue`
  and `mediaIssues` (see below).
- **0, state `closed`:** the user closed the app without saving. Say so.
- **0, state `failed` or `lost`:** report `reason` plainly. Recorded files
  that were saved stay in the company's `recordings/` folder.

If the user asks you to stop, run `stop`; a recording in progress is finished
and saved (`reason: "stop-requested"`). If `stop` returns state `finalizing`,
the app is still writing the files: run `wait` and handle its result as
above. If `stop` fails with error `stop-timeout` (exit 1), the app did not act
on the stop within 20 seconds and may still be recording. Tell the user that
plainly, using the status named in `message`, then run `status` and report
what it shows. Do not say the recording was stopped or saved.

**Media issues.** When the saved status (from `wait` or `status`) has an
`issue` or a `mediaIssues` list, a recorded file came out shorter or longer
than the recording, so a layer may not line up. Each `mediaIssues` entry has
`kind` (`screen`, `camera` or `microphone`), `relativePath`, `timelineSeconds`,
`fileSeconds` and a plain `message`. Before any edit, tell the user in plain
words which layer is affected (repeat `message`; the original files are kept)
and suggest recording again. Continue with the summary and edits only if the
user wants to keep this recording.

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
bash "$R" run edit "<package>" --cut 37.9-39.4 --cut 92-95.3 --json   # remove two middle parts
bash "$R" run edit "<package>" --camera 0.8,0.8,0.18 --json
bash "$R" run edit "<package>" --camera-hidden true --json
```

- **Trim the start or end.** Find the times in the transcript `words`
  (`start`/`end` in seconds). To drop everything before a phrase, use
  `--in` at that phrase's first word `start`; to drop everything after, use
  `--out` at the last kept word's `end`. Leave about 0.3 seconds of margin.
- **Cut by words.** For "cut where I said um", "remove the part where I
  looked for the file" or "drop the false start before 'open Settings'", find
  the words in the transcript. Run `describe --json` after `transcribe`; its
  transcript `words` each have `text`, `start` and `end` in seconds on the
  recording timeline, which is the timeline `--cut` uses. For each match:
  - one word or phrase: `--cut <first word start - 0.1>-<last word end + 0.1>`,
  - a stretch between two phrases: from the end of the last word to keep to
    the start of the next word to keep.
  Pass every cut in one `edit` (repeat `--cut`). Don't let a margin reach
  into a neighbouring word you keep. When a phrase occurs more than once,
  list the times and ask which ones to cut. Cuts must sit inside the kept
  range, must not overlap, and each piece left between them must be at least
  0.1 seconds; repeat the app's refusal message plainly if it says otherwise.
  A cut is relative to the current edit: cuts already made stay, and a new
  `edit` with `--cut` adds to them.
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
- After each edit, report `keptStart`, `keptEnd`, `keptSeconds`, the kept
  pieces (`kept`, one start and end per piece) and the camera placement from
  the result, in plain words.

## 6. Preview, then export the video

Before exporting, render one or two stills at moments that show the result
(the first kept second, and a moment with the camera visible). Write them
outside the package, to a temporary folder:

```bash
bash "$R" run frame "<package>" --at 5 --out /tmp/hq-capture-preview-1.png --json
bash "$R" run frame "<package>" --edited-at 30 --out /tmp/hq-capture-preview-2.png --json
```

`--at` is a time on the recording timeline. `--edited-at` is a time in the
edited video, after the trim and cuts, which is easier for checking around a
cut.

Show the stills to the user on their screen with `open "<png>"` and ask
whether to export. Do not read the images into the session yourself unless
the user asks you to check the camera placement; then delegate the image
viewing to a sub-agent when the session already holds several images. Then:

```bash
bash "$R" run export-video "<package>" --json
```

Report the exported `path` and offer to reveal it: `open -R "<path>"`.

## 7. Draft the step-by-step guide

First check for a guide the user already reviewed:

```bash
bash "$R" run review-sop "<package>" --json
```

If it shows steps, the recording already has a guide. Go straight to
"Review the guide in chat" below and do not draft again. Draft only when
`review-sop` refuses with "This recording has no SOP draft yet":

```bash
bash "$R" run extract-screen-evidence "<package>"
bash "$R" run draft-sop "<package>"
```

- `draft-sop` refuses (exit 1, nothing written) when a reviewed guide
  exists, so a new draft never hides the user's edits or approval. Pass
  `--replace-review` only when the user asks to start the guide over.

- `extract-screen-evidence` exit 1 means the screen text was not reliable;
  the draft will use narration alone. Tell the user.
- `draft-sop` exit 0 prints the draft as JSON. Show the steps in chat as a
  numbered list with each step's evidence and any uncertainty flags.
- `draft-sop` exit 1 means it refused (too little narration or too few
  actions), drafted only part, or found no supported steps. Repeat its
  message plainly. Do not write the missing steps yourself and do not invent
  steps from the video; offer to record again with more narration. A partial
  draft can be retried with `draft-sop "<package>" --retry-failed`. When a
  review exists, the retry fills only the empty steps and keeps every edit,
  order and screenshot choice. If the guide was approved, the retry saves a
  new unapproved revision and the user must approve again.
- Never present the draft as approved.

### Review the guide in chat

Run `bash "$R" run review-sop "<package>" --json` with no changes to read the
current review: numbered steps with `id`, `instruction`, `screenshot`,
`crop` and `flags`, plus `removed` steps and `prerequisites`. Show it as a
numbered list. Then apply each change the user asks for with `review-sop`,
one `review-sop` call per request (several flags in one call is fine):

| User says | Flags |
|---|---|
| move step 3 to the top | `--move 3 1` |
| reword step 2 | `--reword 2 "Click Save in the toolbar"` |
| drop step 4 | `--drop 4` |
| bring back the step I dropped | `--restore step-4` (the id from `removed`) |
| use a different screenshot for step 2 | `--screenshot 2 <image from list-frames>` |
| no screenshot for step 5 | `--omit-screenshot 5` |
| crop step 1's screenshot to the top left | `--crop 1 0,0,0.5,0.5` |
| rename the guide | `--title "Send an invoice"` |
| add / remove a prerequisite | `--prerequisite add "Admin access"` / `--prerequisite remove pre-1` |

A step is named by its current number or its id (`step-2`). Numbers change
after a move or a drop, so re-read the result before the next change. Crop
values are fractions of the screenshot from 0 to 1 (x, y, width, height).
Every change saves a new revision and clears any earlier approval. If the
app refuses, repeat its message plainly; nothing was written.

To pick a screenshot, list the candidate frames for that step:

```bash
bash "$R" run list-frames "<package>" --step 2 --json
```

Each frame has `image` (a path inside the package), `timelineSeconds`,
`width` and `height`. Show two or three candidates to the user on their
screen with `open "<image>"`, then pass the chosen `image` to `--screenshot`.
Read a frame into the session only when the user asks you to check it, and
delegate that to a sub-agent when the session already holds several images. No frames means
`extract-screen-evidence` has not run or found nothing.

### Approve and export

When the user is happy, ask plainly whether they approve the guide as shown.
Only after they say yes, run, with their name as the reviewer:

```bash
bash "$R" run approve-sop "<package>" --reviewer "<the user's name>" --json
bash "$R" run export-sop "<package>"
```

Use the user's name from the session or from what they told you; if you
don't know it, ask. Never approve on the user's behalf without that yes.
`approve-sop` approves the newest revision exactly as it is. `export-sop`
writes the guide (exit 0); exit 1 means the newest revision is not approved,
for example because a change came after the approval. Report the exported
path.

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
When the guide step comes, run `review-sop` first as step 7 says; if a
reviewed guide exists, continue the review instead of drafting.

## Rules

- One HQ Capture window at a time.
- The company is fixed for the life of a recording. Changing the session's
  company does not move an open recording.
- Capture, transcription and guide drafting run on the Mac. You, the session
  agent, read the transcript, the guide drafts and any still you are asked to
  check, so the user can edit by conversation; tell the user this if they ask
  where their recording goes. Do not upload recordings, transcripts, stills
  or drafts to any other service, and never share them with another company.
  Copy a recording to the company vault with `sync-package` only when the
  user asks.
- Never edit files inside a `.hqrec` package directly; use `run`.
- Generated guides and skills are drafts until the user approves them.
