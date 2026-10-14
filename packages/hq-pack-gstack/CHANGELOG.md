# Changelog

## Unreleased

- Update worker registry and package scanner references to the `hq core`
  commands. The pack does not call these commands directly at runtime.

## 1.1.4

- Require hq-core >= 15.0.179 because the worker registry and package scanner instructions use `hq core generate-workers-registry` and `hq core scan-packages`, which are unavailable below that floor.
