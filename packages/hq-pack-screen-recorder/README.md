# hq-pack-screen-recorder

`/record-process` for HQ. Run it in a company session to open **HQ Capture**,
a local Mac app that records a process with screen, camera and narration as
separate layers and saves them to that company's `recordings/` folder.

HQ Capture only records. When you save, you go back to the HQ session and the
agent does the rest by conversation: it summarizes what was recorded, trims
the start or end, places or hides the camera, shows still frames, exports the
video, and drafts a step-by-step guide from the narration and screen. If the
session was interrupted, HQ Capture gives you a prompt to paste into a new
session to pick up the same recording.

The app's Swift source ships in `app/`. The pack compiles it on the user's Mac
with Apple's Command Line Tools and signs it locally, so there is no prebuilt
binary to download and no notarization step.

## Status

0.2.0. Verified:

- The pack builds "HQ Capture.app" on a Mac with only Command Line Tools,
  with its icon, ad-hoc signature, and camera and microphone entitlements.
- `/record-process` opens the app bound to the session's company and its
  `recordings/` folder, and reports `awaiting-start` without recording.
- `stop` closes the app, and a second start reuses the build.
- The 0.1.0 app is removed after the new one builds.
- The launcher passes the agent commands through to the app, keeps them
  inside the session's company, and checks pasted resume prompts.

Not available yet:

- Cutting a section out of the middle of a recording. An edit keeps one range.
- Applying review changes to a drafted guide and recording approval from the
  session. There is no agent command for either, so a drafted guide cannot be
  exported from the session yet.

## Contents

| Path | Purpose |
|------|---------|
| `skills/record-process/` | The `/record-process` skill (HQ Capture) |
| `scripts/hq-record-process.sh` | `doctor`, `build`, `start`, `status`, `wait`, `stop`, `run`, `resume` |
| `knowledge/screen-recorder/` | Setup, permissions, the editing flow, control channel |
| `app/` | Swift source, `Info.plist`, entitlements and icon for HQ Capture |
| `tests/` | Launcher tests (any OS) and a macOS end-to-end check |

## Source of truth

The app is developed in the private `local-screen-recorder` repository, which
also holds its Xcode project and unit and UI tests. `app/Sources` is copied
from that repository; `app/SOURCE` records the commit it came from.

## Tests

```bash
bash packages/hq-pack-screen-recorder/tests/record-process.test.sh   # any OS, uses a stub app
bash packages/hq-pack-screen-recorder/tests/e2e-macos.sh             # macOS: real build and launch
```
