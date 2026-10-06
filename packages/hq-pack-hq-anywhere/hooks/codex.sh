#!/bin/sh
# Installer-visible Codex hook entry point. Keep gate and dispatch behavior in the shared shim.
case "$0" in
  */*) hook_dir=${0%/*} ;;
  *) hook_dir=. ;;
esac
exec /bin/sh "$hook_dir/codex-hook-shim.sh" --runtime codex "$@"
