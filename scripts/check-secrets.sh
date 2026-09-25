#!/usr/bin/env bash
# Refuses to let a real secret reach the remote. The anon key is public and is committed on
# purpose (spec Addendum v7.1), so a JWT-looking string is NOT a finding here: only a JWT whose
# payload actually encodes the service-role claim is. Environment variable NAMES are never a finding;
# only the value shapes below are. A Postgres ROLE name is not a finding either: quoting
# service_role in SQL is ordinary, and the credential that role implies is the JWT, which the
# fourth pattern catches on its own.
#
# usage: check-secrets.sh [<git-log-revision-argument>...]
#   no arguments   scan the working tree (tracked files only), as before
#   arguments      scan the working tree AND every commit those arguments select. They are handed
#                  straight to `git log`, so `.githooks/pre-push` can pass the range it is about
#                  to push. This matters because a secret added in one commit and deleted in a
#                  later one is still on its way to the remote, and the working-tree scan cannot
#                  see it.
#
# Exit codes: 0 clean, 1 a finding, 2 the guard could not run. Anything out of git other than
# "match" or "no match" is an error and never a clean bill: a guard that prints clean when it
# failed is worse than no guard.
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "error: cannot cd to the repo root" >&2; exit 2; }

# The three alternatives in the JWT pattern are base64url of the service-role claim at each of the three
# byte alignments a payload can put it at, so the claim is caught wherever it sits in the payload.
# The password segment of the connection string excludes $, { and }, so documenting the command
# with the password held in an environment variable is not a finding.
PATTERNS=(
  'sb_secret_[A-Za-z0-9_-]{8,}'
  'sbp_[0-9a-f]{40}'
  'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*(c2VydmljZV9yb2xl|cnZpY2Vfcm9s|ZXJ2aWNlX3Jv)[A-Za-z0-9_-]*\.'
  'postgres(ql)?://[^[:space:]/]+:[^[:space:]@${}]+@'
)

# Whole-file exclusions: these three carry the pattern list itself. A secret parked inside one of
# them is invisible to the guard, which is the unavoidable cost of the guard describing itself.
EXCLUDE=(':!scripts/check-secrets.sh' ':!AppTests/SecretGuardTests.swift' ':!App/Sync/SecretPatterns.swift')

found=0

scan_worktree() {
  local pattern out rc
  for pattern in "${PATTERNS[@]}"; do
    out=$(git grep -nIE "$pattern" -- . "${EXCLUDE[@]}")
    rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$out"
      echo "error: the pattern '$pattern' matched above; that looks like a real secret"
      found=1
    elif [ "$rc" -gt 1 ]; then
      echo "error: git grep failed (exit $rc) for the pattern '$pattern'" >&2
      exit 2
    fi
  done
}

# `git log -G` reports every commit whose diff adds or removes a line matching the pattern, so a
# secret that was committed and then deleted still shows up. It exits 0 whether or not anything
# matched, so an empty result is the "no finding" signal and a non-zero exit is an error.
scan_history() {
  local pattern out rc
  for pattern in "${PATTERNS[@]}"; do
    out=$(git log --no-merges --no-color --extended-regexp -G"$pattern" \
                  --format='%h %s' "$@" -- . "${EXCLUDE[@]}")
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "error: git log failed (exit $rc) scanning history for the pattern '$pattern'" >&2
      exit 2
    fi
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      echo "error: the commits above add or remove a line matching '$pattern'; that looks like a real secret"
      found=1
    fi
  done
}

scan_worktree
if [ "$#" -gt 0 ]; then
  scan_history "$@"
fi

if [ "$found" -ne 0 ]; then
  echo "Refusing to push. Remove the secret, rewrite the commit that introduced it, then push again."
  exit 1
fi

echo "check-secrets: clean"
