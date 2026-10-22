# Changelog

## Unreleased

- Integrate CLT-compatible state wrappers with bounded, cached feature-based developer-tool selection; preserve installed-Xcode fallback, diagnose macOS/SDK prerequisites accurately, and document tool update discovery.


- `doctor` typechecks a small SwiftUI sample with the selected developer tools
  and compiler flags as the real build, and reports the Swift version and
  macOS SDK it used. The check stops after two minutes if the compiler hangs.
  A passing result is remembered for that SDK, including the real directory
  behind the MacOSX.sdk link, and is checked again when the SDK or Swift
  version changes. If the check fails, doctor says the installed Command
  Line Tools cannot build this version, or that the check timed out, and
  tells you to update HQ Capture with `hq install hq-capture`. If it still
  fails, update the Command Line Tools in System Settings > General >
  Software Update. A build that fails because a Swift macro plugin is missing
  says the same thing, instead of only pointing at the build log. The check
  does not ask for a permission.

- Keep local builds working with Command Line Tools and macOS SDK 27. Use the
  existing SwiftUI State property wrapper explicitly so the new State macro
  does not require the Xcode-only SwiftUIMacros plugin. No Xcode install is needed.

- Read the active company with `hq core hq-session get company_slug`, with no
  shell-script fallback. The package requires hq-core 15.0.179 or newer, whose
  CLI floor includes hq-cli 5.99.0.

## 0.3.2

Fixes from the 0.3.0 review that were held back at release. Vendored HQ Capture
from local-screen-recorder 8e32b99. App version 0.3.2 (build 4).

- The macOS "Quit and Reopen" after a Screen Recording grant no longer reads as
  the user closing the app. The app reports `relaunching`. `status` and `wait`
  keep it open while the old app quits and for up to 30 seconds after, until
  the reopened app reports. `start` refuses with `already-open` during that
  time. If no app reopens, the state becomes `closed`.
- Approval applies to the guide revision the user was shown. `review-sop`
  output has `head`, the revision it shows: the review revision, or the draft
  when nobody has reviewed it yet. `approve-sop --revision` accepts that
  `head`, and the launcher refuses `approve-sop` without `--revision`. The
  skill passes the `head` of the last review it showed. If a newer revision
  was saved after that, the approval is refused.
- Launcher locks: a stale lock is taken over under a kernel file lock and
  checked again before the takeover, so two launchers that find the same stale
  lock cannot both take it. A lock records its owner's start time as well as
  the pid, so a pid that macOS has given to another program no longer counts
  as the owner. A build checks it still holds the lock before installing, and
  it moves the old app aside before moving the new one in. If an app shows up
  at that path during the install, the build stops with `install-conflict`
  and does not put one app inside the other.
- `run frame --out` resolves every `companies/<slug>` entry, including
  symlinks that point outside `companies/`. It refuses a path inside another
  company's folder however that path reaches it, including through a symlink
  in the bound company's folder.

## 0.3.1

- Added `cover.jpg`, the HQ marketplace card image (the "night press hall"
  wallpaper from the HQ Quiet Machines release). No skill, launcher or app
  changes.

## 0.3.0

- Vendored HQ Capture from local-screen-recorder da8e7f8: middle cuts, guide
  review and approval commands, screenshot frame listing, media length checks,
  the rounded Liquid Glass window style, the window coming back to the front
  on stop and on launch, and roomier controls. App version 0.3.0 (build 3).
- The app refuses any file path in a recording that points outside the
  recording, with links resolved, before playback, export, frames, describe or
  transcription.
- Agent commands leave a recording that is still being captured alone. It is
  marked interrupted only once the app that owned it is confirmed gone.
- Vault sync checks the recording before and after each upload. If it changed
  during the upload, the upload repeats up to three times and then stays
  pending instead of being marked synced. The sync-state write is uploaded and
  checked too. A crash on failed syncs is fixed.
- When the app quits after a stop request, it keeps the saved or failed status,
  with the recording path, resume prompt and any issue, instead of reporting
  closed.
- Launcher: a saved or failed HQ Capture whose window is still open counts as
  open. `start` refuses with `already-open`, `build` will not replace it, and
  `stop` asks it to quit and waits for it to exit. A saved or failed status
  whose app has already quit works as before.
- Saves from different commands no longer overwrite each other's changes to a
  recording. Each save locks the recording, re-reads the newest manifest and
  changes only its own fields. A save waits while another process holds the
  lock.
- Extracting screen frames again keeps every frame that a saved guide draft or
  an exported guide uses. Only frames nothing uses are deleted.
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
- Privacy wording in the skill, `package.yaml` and setup guide now says what
  happens: capture, transcription and guide drafting run on the Mac; the
  session agent reads the transcript, guide drafts and stills it shows;
  nothing goes to another service or company; vault sync only on request.
  Stills are shown with `open` and read into the session only when the user
  asks for a placement check.
- `status`, `wait` and `stop` check the session's company. When HQ Capture is
  open for another company, `status` and `wait` return only
  `busy-other-company` and `stop` refuses.
- `start --company` is refused when the session has no company.
- `run frame --out` refuses a path inside another company's folder.
- Concurrent builds share a lock, and a lock left by a dead process is
  cleared. The build hash now covers the compile recipe and handles paths
  with spaces.
- `doctor` works without python3 and uses the same developer directory as the
  build.
- The skill tells the agent to run `wait` when `stop` returns `finalizing`.
- `draft-sop` no longer hides a reviewed or approved guide. When a review
  exists it refuses with exit 1 and writes nothing, unless the user asked to
  start over and the agent passes `--replace-review`. `--retry-failed` fills
  only the empty steps of the current review and keeps edits, order and
  screenshots; an approved guide gets a new unapproved revision. The app's
  guide button opens the existing review instead of drafting again, and
  export and vault sync use the current review.
- The skill runs `review-sop` before drafting, and on resume continues an
  existing review instead of drafting again.
- A leftover edit or guide revision file no longer blocks saves. The next free
  revision number is used.
- Export renders the newest saved edit, read under the recording lock, and
  records which edit it rendered.
- The package is private.
- Stopping while a capture is still starting waits for the start and then
  stops it, so no capture keeps running after a stop.
- Transcripts, guide export folders, screen evidence, video exports, kept
  screenshots, skill sources and edit or draft revisions are created only
  when their name is still free. If another command took the name first, the
  next free number is used or the save is refused. A file written by another
  command is never replaced or removed. Screen evidence goes into its own
  numbered folder, and the manifest switches to it under the recording lock.
- Launcher: `stop` fails with `stop-timeout` (exit 1) when HQ Capture is still
  open after 20 seconds and is not finalizing. The message says the recorder
  may still be recording and gives its current status. `finalizing` is still
  reported as success. The skill tells the agent to say this plainly and run
  `status`.
- `approve-sop`, `review-sop` and `export-sop` refuse when a newer revision
  of the guide was saved after the one being approved or exported, so an
  approval never covers an edit the reviewer did not see.
- Launcher: `start` holds a lock from the open check until the app writes its
  first status. A second `start` at the same time waits briefly, then reports
  `already-open` or the new `busy` (exit 1). Only one app opens. The skill
  tells the agent to wait and run `status` on `busy`.
- Launcher: a status file whose pid now belongs to a different program no
  longer counts as HQ Capture being open. The launcher checks the process
  name as well as the pid.
- Launcher: the build lock writes its pid in one step. A lock with no pid
  that is 30 seconds old or more is treated as stale and cleared.
- Launcher: another company's saved, failed or closed status only blocks this
  company while that company's app is still running. Once it has quit,
  `status` returns `none`, `stop` does nothing and `start` proceeds. While it
  is running, `status` and `wait` still return only `busy-other-company`.
- Tests: checks that could not fail now fail the suite.

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
