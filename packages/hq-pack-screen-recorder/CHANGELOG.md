# Changelog

## 0.3.0

- Vendored HQ Capture from local-screen-recorder 862e59e: middle cuts, guide
  review and approval commands, screenshot frame listing, media length checks,
  and the updated window style. App version 0.3.0 (build 3).
- `/record-process` cuts by words: the agent maps "cut where I said um" to
  `--cut` ranges from the transcript's word times.
- `/record-process` reviews the drafted guide in chat and applies each change
  with `review-sop`, shows candidate screenshots with `list-frames`, records
  approval with `approve-sop --reviewer` only after the user says yes, then
  exports with `export-sop`.
- When a saved recording has media issues, the agent tells the user and
  suggests recording again before editing.
- Launcher: `run` accepts `review-sop`, `approve-sop` and `list-frames` with
  the same company and destination checks. `status` and `wait` return `issue`
  and the recording's `mediaIssues`.
- Removed the 0.2.0 known gaps: middle cuts and guide review are available.

## 0.2.0

- The app is now HQ Capture, built as "HQ Capture.app" in
  `~/Library/Application Support/HQ Capture/`. The bundle id is unchanged.
  Vendored from local-screen-recorder 72f5dc2.
- HQ Capture records the screen, camera and microphone as separate layers and
  saves a `.hqrec` recording to the company's `recordings/` folder. It shows a
  prompt to paste into a new session if the original one was interrupted.
- `/record-process` now covers the whole flow in the session: summary after
  save, trimming with a start and end point, camera presets and hiding, still
  frames before export, video export, and a drafted step-by-step guide that
  refuses when narration is too sparse.
- Launcher: new `wait`, `run` and `resume` subcommands. `run` passes agent
  commands to the app and refuses recordings outside the session's company.
  `resume` checks a pasted prompt. The build is reused while the app is open.
- The 0.1.0 app (HQ Recorder.app or LocalScreenRecorder.app) is removed after
  HQ Capture builds.
- Known gaps: no cutting from the middle of a recording, and no agent command
  to apply guide review changes or record approval.

## 0.1.0

- First development release. `/record-process` skill, `hq-record-process.sh`
  launcher (`doctor`, `build`, `start`, `status`, `stop`), and HQ Recorder
  Swift source built locally with Command Line Tools.
- The recorder opens bound to the session's company and its `recordings/`
  folder and reports status over a file channel. Capture is not built yet.
