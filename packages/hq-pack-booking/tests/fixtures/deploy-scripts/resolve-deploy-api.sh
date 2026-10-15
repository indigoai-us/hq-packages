#!/usr/bin/env bash
# Test stand-in for the /deploy skill's resolve-deploy-api.sh: $HQ_DEPLOY_API wins.
printf '%s\n' "${HQ_DEPLOY_API:-https://api.indigo-hq.com}"
