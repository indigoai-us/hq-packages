# HQ Capture (hq-pack-hq-capture)

`/record-process` for HQ. Run it in a company session to open **HQ Capture**,
a local Mac app that records a process with screen, camera and narration as
separate layers and saves them to that company's `recordings/` folder.

HQ Capture only records. When you save, you go back to the HQ session and the
agent does the rest by conversation: it summarizes what was recorded, trims
the start or end, cuts out parts you name by what you said, places or hides
the camera, shows still frames, exports the video, drafts a step-by-step guide
from the narration and screen, applies your review changes to it, and exports
it once you approve. If the
session was interrupted, HQ Capture gives you a prompt to paste into a new
session to pick up the same recording.

The app's Swift source ships in `app/`. The pack compiles it on the user's Mac
with Apple's developer tools (the Command Line Tools, or Xcode when they
cannot build it) and signs it locally, so there is no prebuilt
binary to download and no notarization step.

## Status

0.3.0. Verified:

- The pack builds "HQ Capture.app" on a Mac with only Command Line Tools,
  with its icon, ad-hoc signature, and camera and microphone entitlements.
- `/record-process` opens the app bound to the session's company and its
  `recordings/` folder, and reports `awaiting-start` without recording.
- `stop` closes the app, and a second start reuses the build.
- The 0.1.0 app is removed after the new one builds.
- The launcher passes the agent commands through to the app, including
  repeated cuts, guide review, frame listing and approval, keeps them inside
  the session's company, and checks pasted resume prompts.
- `status` and `wait` report a saved recording's media issues (a layer whose
  file length does not match the recording).

## Contents

| Path | Purpose |
|------|---------|
| `skills/record-process/` | The `/record-process` skill (HQ Capture) |
| `scripts/hq-record-process.sh` | `doctor`, `build`, `start`, `status`, `wait`, `stop`, `run`, `resume` |
| `knowledge/hq-capture/` | Setup, permissions, the editing flow, control channel |
| `app/` | Swift source, `Info.plist`, entitlements and icon for HQ Capture |
| `tests/` | Launcher tests (any OS) and a macOS end-to-end check |
| `cover.jpg` | HQ marketplace card image (`hq-night-press-hall` from the HQ "Quiet Machines" wallpaper release) |

## Source of truth

The app is developed in the private `local-screen-recorder` repository, which
also holds its Xcode project and unit and UI tests. `app/Sources` is copied
from that repository; `app/SOURCE` records the commit it came from.

## Tests

```bash
bash packages/hq-pack-hq-capture/tests/record-process.test.sh   # any OS, uses a stub app
bash packages/hq-pack-hq-capture/tests/e2e-macos.sh             # macOS: real build and launch
```
