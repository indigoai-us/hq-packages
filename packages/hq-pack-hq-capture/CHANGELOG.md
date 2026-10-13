# Changelog

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
