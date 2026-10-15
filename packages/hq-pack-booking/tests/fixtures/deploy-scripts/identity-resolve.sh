#!/usr/bin/env bash
# Test stand-in for the /deploy skill's identity-resolve.sh. Always used by the
# tests (never the real one), so no sign-in or token file is touched.
# TEST_IDENTITY=login_required simulates a signed-out user.
if [ "${TEST_IDENTITY:-ok}" = "login_required" ]; then
  echo '{"status":"login_required","reason":"no_tokens"}'
else
  echo '{"status":"ok","jwt":"test-jwt","id_token":"test-id-token","identity":"person","source":"cache"}'
fi
