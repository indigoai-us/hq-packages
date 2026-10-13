# HQ Capture setup

HQ Capture is the local Mac app behind `/record-process`. It only records.
Summaries, trimming, camera placement, video export and step-by-step guides
happen in the HQ session that opened it, through the agent.

This pack ships the app's Swift source in `app/`. The first time
`/record-process` runs, the pack compiles the app on the Mac and stores it at
`~/Library/Application Support/HQ Capture/HQ Capture.app`. It rebuilds
automatically when a pack update changes the source. While HQ Capture is open,
the existing build is used as is.

## Requirements

- Apple Silicon Mac running macOS 26 or later.
- Apple Command Line Tools. Install them once with `xcode-select --install`.
  Full Xcode is not needed. `hq-record-process.sh doctor` checks for them.
- No Apple developer account, certificate or download from Indigo. The app is
  built on the Mac and signed locally ("ad-hoc"), so macOS does not need a
  notarized copy.

## Permissions

macOS asks for each permission the first time the app uses it. Approve:

- **Screen Recording**, for the screen layer.
- **Camera**, for the separate camera layer.
- **Microphone**, for narration.

For Screen Recording, macOS asks you to choose **Quit and Reopen**. The
reopened app keeps its company binding for 10 minutes, so you can carry on
without going back to the HQ session. The session keeps following the app
while it reopens. After 10 minutes, run `/record-process` again.

You can review the permissions in System Settings → Privacy & Security.
Because the app is built and signed on your Mac, macOS can treat an updated
build as a new app and ask for Screen Recording permission again after a pack
update. Approve it again when asked.

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

## Updating from 0.1.0

Version 0.1.0 built an app called HQ Recorder (or LocalScreenRecorder) in
`~/Library/Application Support/HQ Recorder/`. After HQ Capture builds, the
launcher removes that old app. Recordings are not stored there and are not
affected.

## Control channel

The HQ session and the app talk through files in
`~/Library/Application Support/HQ Capture/active/`:

- `status.json` is written by the app. Fields: `schema`, `state`
  (`awaiting-start`, `recording`, `finalizing`, `saved`, `failed`, `closed`,
  or `relaunching` when the app quit for **Quit and Reopen**),
  `company`, `destination`, `pid`, `updatedAt`, `paused` and
  `durationSeconds` while recording, `recording` and `resumePrompt` once
  saved, `reason` when it failed or was stopped, and `issue` when a saved
  layer may not line up.
- `stop.request` is created by `hq-record-process.sh stop`. The app watches
  for it, finishes a recording in progress, saves it, and closes.

`status` reports `lost` when the app process is gone without writing a final
state. For a saved recording, `status` and `wait` also return `mediaIssues`
from the recording's `manifest.json`: one entry per layer whose file length
does not match the recording, with `kind`, `relativePath`, `timelineSeconds`,
`fileSeconds` and `message`. When the app did not set `issue`, it is filled
from the first media issue's message.

The agent's editing commands (`hq-record-process.sh run <mode> <recording>`)
run the same app headless, without a window. They work only on recordings
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
