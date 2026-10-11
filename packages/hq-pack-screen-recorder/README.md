# hq-pack-screen-recorder

`/record-process` for HQ. Run it in a company session to open **HQ Recorder**,
a local Mac app that records a process with screen, webcam and narration as
separate layers and saves them to that company's vault. Later versions add
trimming, video export and on-device SOP or skill drafts with screenshots.

The app's Swift source ships in `app/`. The pack compiles it on the user's Mac
with Apple's Command Line Tools and signs it locally, so there is no
prebuilt binary to download and no notarization step.

## Status

0.1.0 is a development release. Verified:

- The pack builds the app on a Mac with only Command Line Tools.
- `/record-process` opens the app bound to the session's company and its
  `recordings/` folder, and reports `awaiting-start` without recording.
- `stop` closes the app and the final state is `closed`.

Not built yet: capture, editor, export, transcription, SOP drafting.

## Contents

| Path | Purpose |
|------|---------|
| `skills/record-process/` | The `/record-process` skill |
| `scripts/hq-record-process.sh` | `doctor`, `build`, `start`, `status`, `stop` |
| `knowledge/screen-recorder/` | Setup, permissions, control channel |
| `app/` | Swift source and `Info.plist` for HQ Recorder |
| `tests/` | Launcher tests (any OS) and a macOS end-to-end check |

## Source of truth

The app is developed in the private `local-screen-recorder` repository, which
also holds its Xcode project and unit/UI tests. `app/Sources` is copied from
that repository; `app/SOURCE` records the commit it came from.

## Tests

```bash
bash packages/hq-pack-screen-recorder/tests/record-process.test.sh   # any OS, uses a stub app
bash packages/hq-pack-screen-recorder/tests/e2e-macos.sh             # macOS: real build and launch
```
