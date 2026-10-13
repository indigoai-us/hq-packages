# Changelog

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
