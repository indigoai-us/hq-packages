# Changelog

## 0.1.4

- Preserve feature-based developer-tool fallback: try `$DEVELOPER_DIR`,
  xcode-select's choice, Command Line Tools and an installed Xcode in order.
  Each candidate needs SDK 26 or newer and must pass the bounded probe using
  CaptureState, Observation, Binding and Liquid Glass. Doctor and build use
  that same selection; Xcode is optional rather than a prerequisite for CLT27.
  The existing `swiftui_macros` diagnostic remains alongside `compile_probe`.
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

## 0.1.3

- HQ can now start a recording without the user pressing Start. `record`
  asks the open HQ Capture to start, and `start --record` opens it and starts
  in one step. `start.request` holds the requesting company. The app accepts
  it by renaming it to `start.accepted`, writes its status (`recording`, or
  `awaiting-start` with the blocker as `reason`), then removes
  `start.accepted`. It ignores requests until the saved screen, camera and
  microphone are restored, and refuses a request from another company with
  `start-company-mismatch`. When the app has not accepted the request in
  time, `record` withdraws it and fails with `start-timeout`; when the app
  accepted it but is still starting, `record` fails with `start-pending` and
  the start goes on. Other failures are `start-blocked`, `not-open`,
  `already-recording`, `not-ready` and `other-company`. Requests are written
  under the start lock, so `record` and `start` cannot race.
- `app/Sources` (`HQControl.swift`, `LocalScreenRecorderApp.swift`) is ahead
  of upstream `bcc4af8` by the start request; it needs the same change in the
  `local-screen-recorder` repository.

## 0.1.2

- Internal cleanup with no user-visible change. Removed the unused SOP review
  window code: `SOPReviewView.swift` (`SOPReviewModel`, `SOPReviewSection`,
  `CropSurface` and the `--review-package` launch), and `SOPReviewSeek` /
  `SOPSeekTarget` from `SOPReview.swift`. Nothing in the app, launcher or skill
  used them. Guide review and export through the launcher are unchanged.
- The vendored app now tracks upstream `bcc4af8`, keeping the 0.1.1 build
  fixes. The app version is unchanged.

## 0.1.1

- The app builds again with current Command Line Tools (Swift 6.2.3, macOS
  26.2 SDK), which the launcher uses whenever they are installed. Before this
  release `start` and `build` failed with "HQ Capture did not compile":
  - Three long expressions timed out in the type checker: the list of files a
    recording refers to and the time ranges checked on load
    (`RecordingPackage.swift`), and the next export folder number
    (`SOPReview.swift`). They are now built step by step with explicit types.
  - `SystemLanguageModel.contextSize` is not in the 26.2 SDK
    (`SOPDraft.swift`). On older compilers the guide-drafting budget uses the
    on-device model's 4,096-token window instead.
- Behaviour is unchanged. The app also still builds with Xcode 26.5 (Swift 6.3.3).

## 0.1.0

First release under the slug `hq-capture`. This pack continues
`hq-pack-screen-recorder` 0.3.2 with the same code: HQ Capture vendored from
local-screen-recorder 8e32b99, app version 0.3.2 (build 4). The pack version
restarts at 0.1.0; the app version inside it does not.

Changes from `hq-pack-screen-recorder` 0.3.2:

- Pack name `hq-pack-hq-capture`, installed at `core/packages/hq-pack-hq-capture/`.
- Knowledge id `hq-capture` (was `screen-recorder`), installed at
  `core/knowledge/hq-capture/`, so it does not overwrite the old pack's
  knowledge when both are installed.
- The skill is still `/record-process`.

For history before this release, see the `hq-pack-screen-recorder` changelog.
