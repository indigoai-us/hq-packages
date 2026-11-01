# HQ Capture setup

HQ Capture is the local Mac app behind `/record-process`. It only records.
Summaries, trimming, camera placement, video export and step-by-step guides
happen in the HQ session that opened it, through the agent.

HQ Capture ships inside the HQ desktop app, at
`HQ.app/Contents/Helpers/HQ Capture.app`. The desktop app builds, signs and
updates it; this pack builds nothing. `/record-process` asks the desktop app
to open the recorder through its `hq-desktop://record/<company>` link, and the
editing commands run the HQ Capture inside it.

## Requirements

- A Mac on macOS 26 or later.
- The HQ desktop app, installed and opened once. Install it from
  https://hqforwork.com/install (direct download for Mac:
  https://github.com/indigoai-us/hq-desktop-app/releases/latest/download/HQ.dmg).
  Without it, `/record-process` prints that link and starts nothing.
  `hq-record-process.sh doctor` checks macOS, finds the desktop app (in
  /Applications, ~/Applications, by Spotlight, or the running one) and the HQ
  Capture inside it. An older desktop app without HQ Capture is updated from
  its HQ menu (Check for updates).
- No developer tools, Apple developer account or certificate.

## Permissions

HQ asks macOS for each permission, in its own permission window, the first
time a recording needs it:

- **Screen Recording**, for the screen layer.
- **Camera**, for the separate camera layer.
- **Microphone**, for narration.

macOS lists them under **HQ** in System Settings → Privacy & Security, because
HQ starts HQ Capture. HQ Capture itself never asks: when you press a
permission repair in its window, HQ's permission window opens. If Screen
Recording is off when you start, HQ shows its steps first and opens HQ Capture
once access is on; the session sees `waiting-permission` meanwhile. For Screen
Recording, macOS asks you to choose **Quit and Reopen** for HQ; HQ reopens HQ
Capture for the same company by itself.

Grants given to the standalone HQ Capture that older versions of this pack
built do not carry over; HQ asks once.

## Where recordings go

`/record-process` saves to `companies/<company>/recordings/<name>.hqrec` in the
HQ folder of the session's company. The company is fixed when HQ Capture
opens. The folder follows the company vault's normal access rules, and the
agent uploads a recording only when you agree (`sync-package`).

A `.hqrec` recording keeps the screen, camera and microphone as separate
layers that are never changed. Each edit (trim, cuts, camera placement) is
saved as a new revision inside the recording, and exports are written next to
it. Guide review changes and approval are saved the same way, as new draft
revisions.

## After you save

When you press Stop, HQ Capture shows "Saved. Go back to your HQ session to
edit and turn this into a guide." The agent in that session then:

1. summarizes the recording: length, what was said, pauses and filler words;
2. trims the start or end, cuts out parts you name by what you said (for
   example "cut where I said um"), moves, resizes or hides the camera, and
   shows still frames before export;
3. exports the video and offers to show it in Finder;
4. drafts a step-by-step guide from your narration and the screen, then
   applies your review changes from the chat: reorder, reword, drop or
   restore steps, pick or crop a different screenshot, rename the guide, and
   add or remove prerequisites;
5. records your approval under your name only after you say yes, then exports
   the guide;
6. uploads the recording to the company vault when you agree.

Any change after approval clears it, so the guide has to be approved again
before it can be exported.

If a recorded layer came out shorter or longer than the recording (for
example the narration file is a few seconds short), HQ Capture keeps the
original files and lists the problem in the recording. The agent tells you
which layer is affected and suggests recording again before editing.

## If the session was interrupted

HQ Capture also shows a prompt you can copy. Paste it into a new HQ session
for the same company. Its shape is:

```
Continue my HQ Capture recording for <company> at <absolute path to .hqrec>: show me what was recorded, then trim, place the camera, export the video and draft the step-by-step guide.
```

The agent checks that the company matches the session and that the path is a
recording in that company's `recordings/` folder before it continues.

## Updating from 0.1.x

Versions 0.1.0 to 0.1.4 of this pack built HQ Capture on the Mac, in
`~/Library/Application Support/HQ Capture/HQ Capture.app` (and 0.1.0 in
`~/Library/Application Support/HQ Recorder/`). From 0.2.0 that app is not
used, rebuilt or removed; you can delete it. Recordings are not stored there:
the ones it made stay in each company's `recordings/` folder and open,
export and draft guides with the HQ Capture in the desktop app.

## Control channel

The HQ session, the HQ desktop app and HQ Capture talk through files in
`~/Library/Application Support/HQ Capture/active/`. `start` clears the folder,
then sends `hq-desktop://record/<company>` to the desktop app (with `open -a`
and the desktop app's path, so the installed HQ is the one that answers). HQ
checks the company exists in its HQ folder, and its HQ Capture service starts
the recorder as its own child, so start, status and stop never start HQ Capture
from the shell:

- `launch.json` is written by the desktop app before the recorder reports:
  `state` is `waiting-permission` (with `missing`, while its permission
  window is open), `opening`, `open`, or `refused` (with `reason` and
  `message`). `status` and `wait` report `waiting-permission` and `refused`
  from it until `status.json` appears; a waiting note older than five
  minutes is ignored.

- `status.json` is written by the app. Fields: `schema`, `state`
  (`awaiting-start`, `recording`, `finalizing`, `saved`, `failed`, `closed`,
  or `relaunching` when the app quit for **Quit and Reopen**),
  `company`, `destination`, `pid`, `updatedAt`, `paused` and
  `durationSeconds` while recording, `recording` and `resumePrompt` once
  saved, `reason` when it failed or was stopped, and `issue` when a saved
  layer may not line up.
- `start.request` is created by `hq-record-process.sh record` (or
  `start --record`) and holds the requesting company. Once the saved screen,
  camera and microphone are restored, the app accepts it by renaming it to
  `start.accepted`, writes `status.json`, then removes `start.accepted`. The
  status is `recording` when it started, or `awaiting-start` with the blocker
  as `reason` when Start would not work yet (for example, Screen Recording
  access is missing, or `start-company-mismatch` when another company asked).
  `record` waits up to 20 seconds (`HQ_RECORDER_RECORD_WAIT`). If the request
  is still there, `record` removes it and fails with `start-timeout`; the
  rename makes sure the app never acts on a withdrawn request. If the app
  accepted it but has not answered yet, `record` fails with `start-pending`
  and the recording may still start.
- `stop.request` is created by `hq-record-process.sh stop`. The app watches
  for it, finishes a recording in progress, saves it, and closes.

`status` reports `lost` when the app process is gone without writing a final
state. For a saved recording, `status` and `wait` also return `mediaIssues`
from the recording's `manifest.json`: one entry per layer whose file length
does not match the recording, with `kind`, `relativePath`, `timelineSeconds`,
`fileSeconds` and `message`. When the app did not set `issue`, it is filled
from the first media issue's message.

The agent's editing commands (`hq-record-process.sh run <mode> <recording>`)
run the HQ Capture inside the desktop app headless, without a window. They
read and write saved recordings only and touch no screen, camera or
microphone; transcription uses Apple's on-device speech model on the saved
narration file. They work only on recordings
inside the session company's `recordings/` folder.

## What stays on the Mac

Capture, transcription, text recognition and guide drafting run on the Mac.
The HQ session agent you are talking to reads the transcript, the guide
drafts and any still it shows you, so it can edit by conversation. Stills are
opened on your screen; the agent reads one only when you ask it to check it.
Nothing is uploaded to any other service or shared with another company.

To check that HQ Capture itself makes no network requests, open Activity
Monitor → Network, select HQ Capture, and watch "Sent Bytes" while recording
with Wi-Fi off after Apple's on-device model assets are prepared. Only
`sync-package` uploads, to the company vault, and only when you ask.
