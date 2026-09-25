#!/usr/bin/env bash
# Refuses to let a real secret reach the remote. The anon key is public and is committed on
# purpose (spec Addendum v7.1), so a JWT-looking string is NOT a finding here: only a JWT whose
# payload actually encodes the service-role claim is. Environment variable NAMES are never a finding;
# only the value shapes below are.
set -uo pipefail
cd "$(dirname "$0")/.."

# The three alternatives in the JWT pattern are base64url of the service-role claim at each of the three
# byte alignments a payload can put it at, so the claim is caught wherever it sits in the payload.
PATTERNS=(
  'sb_secret_[A-Za-z0-9_-]{8,}'
  'sbp_[0-9a-f]{40}'
  "[\"']service_role[\"']"
  'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*(c2VydmljZV9yb2xl|cnZpY2Vfcm9s|ZXJ2aWNlX3Jv)[A-Za-z0-9_-]*\.'
  'postgres(ql)?://[^[:space:]/]+:[^[:space:]@]+@'
)

found=0
for pattern in "${PATTERNS[@]}"; do
  if git grep -nIE "$pattern" -- . ':!scripts/check-secrets.sh' ':!AppTests/SecretGuardTests.swift' ':!App/Sync/SecretPatterns.swift'; then
    echo "error: the pattern '$pattern' matched above; that looks like a real secret"
    found=1
  fi
done

if [ "$found" -ne 0 ]; then
  echo "Refusing to push. Remove the secret, rewrite the commit that introduced it, then push again."
  exit 1
fi

echo "check-secrets: clean"
