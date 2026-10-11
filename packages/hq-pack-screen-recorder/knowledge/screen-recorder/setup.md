# HQ Recorder setup

HQ Recorder is the local Mac app behind `/record-process`. This pack ships its
Swift source in `app/`. The first time `/record-process` runs, the pack
compiles the app on the Mac and stores it at
`~/Library/Application Support/HQ Recorder/HQ Recorder.app`. It rebuilds
automatically when a pack update changes the source.

## Requirements

- Apple Silicon Mac running macOS 26 or later.
- Apple Command Line Tools. Install them once with `xcode-select --install`.
  Full Xcode is not needed. `hq-record-process.sh doctor` checks for them.
- No Apple developer account, certificate or download from Indigo. The app is
  built on the Mac and signed locally ("ad-hoc"), so macOS does not need a
  notarized copy.

## Permissions

macOS asks for each permission the first time the app uses it. Approve:

- **Screen Recording**, for the screen track.
- **Camera**, for the separate webcam track.
- **Microphone**, for narration.

You can review them in System Settings → Privacy & Security. Because the app is
built and signed on your Mac, macOS can treat an updated build as a new app and
ask for Screen Recording permission again after a pack update. Approve it again
when asked.

## Where recordings go

`/record-process` saves to `companies/<company>/recordings/` in the HQ folder of
the session's company. The company is fixed when the recorder opens. That
folder follows the company vault's normal access rules and sync.

## Control channel

The HQ session and the app talk through files in
`~/Library/Application Support/HQ Recorder/active/`:

- `status.json` is written by the app. Fields: `schema`, `state`
  (`awaiting-start`, `recording`, `finalizing`, `saved`, `failed`, `closed`),
  `company`, `destination`, `pid`, `updatedAt`, and `reason` when it failed.
- `stop.request` is created by `hq-record-process.sh stop`. The app watches
  for it and stops.

`status` reports `lost` when the app process is gone without writing a final
state.

## Offline check

Capture, transcription, OCR and draft writing are designed to run on the Mac.
To check that a build makes no network requests during a session, open
Activity Monitor → Network, select HQ Recorder, and watch "Sent Bytes" while
recording with Wi-Fi off after Apple's on-device model assets are prepared.
This check is part of the release verification for later versions.
