#!/usr/bin/env bash
# hq-imessage — read and send iMessages from this Mac's Messages account.
# Thin wrapper so skills and bots call one stable path. See hq_imessage.py.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I "$here/hq_imessage.py" "$@"
