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

HQ Capture ships inside the HQ desktop app (`HQ.app/Contents/Helpers/HQ
Capture.app`, macOS 26 or later), signed with HQ. Since 0.2.0 the pack builds
nothing: `/record-process` asks the desktop app to open the recorder, and HQ
asks macOS for Screen Recording, camera and microphone access as HQ. Without
the desktop app, the script prints the install link
(https://hqforwork.com/install) and starts nothing.

## Status

The pack version is declared in `package.yaml` and `package.json`. Verified behavior:

- `start` sends `hq-desktop://record/<company>` to the installed HQ desktop
  app, which opens HQ Capture bound to the session's company and its
  `recordings/` folder (or its permission window first), and reports
  `awaiting-start` without recording.
- Without the HQ desktop app, `start`, `run` and `doctor` print the install
  link and start nothing; an HQ desktop app without HQ Capture asks for an
  update.
- `stop` closes the app; `status`, `wait` and `record` use the control
  folder HQ Capture shares with HQ.
- The launcher passes the agent commands through to the HQ Capture inside
  the desktop app, including repeated cuts, guide review, frame listing and
  approval, keeps them inside the session's company, and checks pasted resume
  prompts. Recordings made with the standalone HQ Capture (0.3.0 to 0.3.2)
  describe the same with the bundled one.
- `status` and `wait` report a saved recording's media issues (a layer whose
  file length does not match the recording).

## Contents

| Path | Purpose |
|------|---------|
| `skills/record-process/` | The `/record-process` skill (HQ Capture) |
| `scripts/hq-record-process.sh` | `doctor`, `start`, `record`, `status`, `wait`, `stop`, `run`, `resume` |
| `knowledge/hq-capture/` | Setup, permissions, the editing flow, control channel |
| `tests/` | Launcher tests (any OS) and a macOS end-to-end check |
| `cover.jpg` | HQ marketplace card image (`hq-night-press-hall` from the HQ "Quiet Machines" wallpaper release) |

## Source of truth

HQ Capture's source lives in the HQ desktop app repository (`apps/capture`),
which builds, signs and ships it with the desktop app. This pack holds only
the session side: the skill, the launcher and the setup notes.

## Tests

```bash
bash packages/hq-pack-hq-capture/tests/record-process.test.sh   # any OS, uses a stub desktop app
HQ_CAPTURE_E2E_PACKAGES=<pkg.hqrec>[:...] \
  bash packages/hq-pack-hq-capture/tests/e2e-macos.sh           # macOS: the real desktop app
```
