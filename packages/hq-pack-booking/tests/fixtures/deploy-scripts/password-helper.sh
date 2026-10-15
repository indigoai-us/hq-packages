#!/usr/bin/env bash
# Test stand-in for the /deploy skill's password-helper.sh (gen and persist only).
set -eu
case "${1:-}" in
  gen) echo "quiet-meadow-42" ;;
  persist)
    mkdir -p "$HOME/.hq"
    SLUG="$2" PW="$3" F="$HOME/.hq/deploy-passwords.json" node -e '
      const fs = require("fs"); const f = process.env.F;
      const o = fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")) : {};
      o[process.env.SLUG] = { password: process.env.PW };
      fs.writeFileSync(f, JSON.stringify(o), { mode: 0o600 });'
    ;;
  *) exit 64 ;;
esac
