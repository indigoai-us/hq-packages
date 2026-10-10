#!/usr/bin/env bash
# Runs the hq-imessage suite against a fixture database. Safe on any OS: no
# real Messages data is read and osascript is mocked.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -I "$here/test_hq_imessage.py"
