#!/usr/bin/env bash
# Generates .npmrc (credential-free) + pnpm-lock.yaml for the TKA-11076 repro probe.
#
#   read -s PAT
#   ORG=detection-qa FEED=mend-qa-npm PAT="$PAT" ./generate-lockfile.sh
#
# NOTE: pnpm lockfile v9 records integrity hashes only -- never registry/tarball URLs.
# The fetch is routed by the `registry=` line in .npmrc, which is what makes the scan
# hit Azure. Do not look for azure URLs in the lockfile; there will never be any.
set -euo pipefail
: "${ORG:?set ORG}"; : "${FEED:?set FEED}"; : "${PAT:?set PAT}"

REG="https://pkgs.dev.azure.com/${ORG}/_packaging/${FEED}/npm/registry/"
B64_PAT=$(printf '%s' "$PAT" | base64 | tr -d '\n')

sed "s|<ORG>|${ORG}|g; s|<FEED>|${FEED}|g" .npmrc.template > .npmrc

# Local-only auth. NEVER committed (.gitignore) and deleted below.
cat > .npmrc.local <<EOF
registry=${REG}
always-auth=true
//pkgs.dev.azure.com/${ORG}/_packaging/${FEED}/npm/registry/:username=${ORG}
//pkgs.dev.azure.com/${ORG}/_packaging/${FEED}/npm/registry/:_password=${B64_PAT}
//pkgs.dev.azure.com/${ORG}/_packaging/${FEED}/npm/registry/:email=npm requires email to be set but does not use the value
EOF

echo "==> Resolving lockfile through ${REG}"
NPM_CONFIG_USERCONFIG="$PWD/.npmrc.local" pnpm install --lockfile-only
rm -f .npmrc.local

echo
echo "==> Check 1: .npmrc points at the feed"
grep -q "^registry=${REG}$" .npmrc && echo "    OK" || { echo "    FAIL"; exit 1; }

echo "==> Check 2: credential-less install must fail 401 (this is the repro baseline)"
rm -rf node_modules
if pnpm install --ignore-scripts --no-color >/tmp/tka11076-nocred.log 2>&1; then
    echo "    FAIL - install succeeded without credentials; the feed is not requiring auth"
    exit 1
fi
if grep -q 'ERR_PNPM_FETCH_401' /tmp/tka11076-nocred.log; then
    echo "    OK - 401 as expected:"
    grep -m1 'ERR_PNPM_FETCH_401' /tmp/tka11076-nocred.log | sed 's/^/      /'
else
    echo "    FAIL - failed for some other reason:"; tail -15 /tmp/tka11076-nocred.log | sed 's/^/      /'; exit 1
fi
rm -rf node_modules
echo
echo "Probe is ready to commit and push."
