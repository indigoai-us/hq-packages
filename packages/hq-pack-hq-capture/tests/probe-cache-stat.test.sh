#!/usr/bin/env bash
# A failed BSD-stat attempt must not contribute stdout to compiler identity.
# Run the actual toolchain/doctor/cache controls, including compiler replacement.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/stat" <<'PY'
#!/usr/bin/env python3
import os,sys,time
if sys.argv[1] == '-f':
    print('failed-filesystem-output-'+str(time.monotonic_ns()))
    raise SystemExit(1)
assert sys.argv[1:3] == ['-c','%Y:%i'], sys.argv
s=os.stat(sys.argv[3])
print(str(int(s.st_mtime))+':'+str(s.st_ino))
PY
chmod +x "$tmp/bin/stat"
PATH="$tmp/bin:$PATH" /bin/bash "$here/toolchain-selection.test.sh"
echo 'probe cache: failed stat stdout discarded; cache hit and replacement invalidation preserved'
