#!/usr/bin/env bash
# Exercises scripts/check-secrets.sh and .githooks/pre-push against a throwaway repository under
# $TMPDIR. These are shell behaviours (a commit range, a git failure, the hook's stdin protocol)
# that an XCTest case in the app target cannot reach, so they live here instead.
#
# It never pushes anything and it never writes a secret to disk in this repo: every fixture value
# is assembled at run time out of fragments, so this file itself carries no matchable shape.
#
# usage: scripts/check-secrets-selftest.sh    (exit 0 if every check passes)
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)" || exit 2

tmp="$(mktemp -d)" || exit 2
trap 'rm -rf "$tmp"' EXIT

fails=0
check() { # check <name> <expected exit> <actual exit>
  if [ "$2" = "$3" ]; then
    echo "ok   $1 (exit $3)"
  else
    echo "FAIL $1: expected exit $2, got $3"
    fails=$((fails + 1))
  fi
}

# A secret-API-key value shape, built here so the shape exists only in the temporary repo.
secret="sb""_secret_""abcdef0123456789abcdef"
zero="0000000000000000000000000000000000000000"

mkdir -p "$tmp/repo/scripts" "$tmp/repo/.githooks" "$tmp/outside/scripts" "$tmp/nogitbin"
cp "$here/scripts/check-secrets.sh" "$tmp/repo/scripts/"
cp "$here/.githooks/pre-push" "$tmp/repo/.githooks/"
cp "$here/scripts/check-secrets.sh" "$tmp/outside/scripts/"
ln -s /usr/bin/dirname "$tmp/nogitbin/dirname"

cd "$tmp/repo" || exit 2
git init -q .
git config user.email selftest@example.invalid
git config user.name selftest
echo "nothing to see" > readme.txt
git add readme.txt
git commit -qm "base"
base="$(git rev-parse HEAD)"

# 1. A secret sitting in the working tree is still caught, exactly as before.
printf 'KEY=%s\n' "$secret" > leak.txt
git add leak.txt
./scripts/check-secrets.sh >/dev/null 2>&1
check "working tree scan catches a tracked secret" 1 "$?"
git commit -qm "add the leak"

# 2. Deleting it in a later commit makes the working tree clean, which is the fail-open the
#    range scan exists to close.
git rm -q leak.txt
git commit -qm "remove the leak"
./scripts/check-secrets.sh >/dev/null 2>&1
check "working tree scan alone reports clean after the delete" 0 "$?"

# 3. The same two commits, scanned as a range, are a finding.
./scripts/check-secrets.sh "$base..HEAD" >/dev/null 2>&1
check "range scan catches the secret that was added and then deleted" 1 "$?"

# 4. The hook's stdin protocol, updating an existing remote branch.
printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$base" \
  | ./.githooks/pre-push origin "$tmp/repo" >/dev/null 2>&1
check "pre-push blocks an update whose range carries the secret" 1 "$?"

# 5. The hook's stdin protocol, pushing a brand new branch (all-zero remote sha).
printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$zero" \
  | ./.githooks/pre-push origin "$tmp/repo" >/dev/null 2>&1
check "pre-push blocks a new branch whose history carries the secret" 1 "$?"

# 6. A deletion (all-zero local sha) has nothing to scan and must not be an error.
printf 'refs/heads/gone %s refs/heads/gone %s\n' "$zero" "$(git rev-parse HEAD)" \
  | ./.githooks/pre-push origin "$tmp/repo" >/dev/null 2>&1
check "pre-push lets a branch deletion through" 0 "$?"

# 7. A clean range is clean.
git checkout -q -b clean "$base"
echo "still nothing" >> readme.txt
git commit -qam "a harmless commit"
./scripts/check-secrets.sh "$base..HEAD" >/dev/null 2>&1
check "range scan passes a range with no secret" 0 "$?"

# 8. Outside a git repository the guard must fail closed, not print clean.
cd "$tmp/outside" || exit 2
./scripts/check-secrets.sh >/dev/null 2>&1
check "outside a git repository the guard fails closed" 2 "$?"

# 9. A malformed pattern makes git grep exit 128; that is an error, not a clean bill.
cd "$tmp/repo" || exit 2
sed 's/\[0-9a-f\]{40}/[0-9a-f{40}/' scripts/check-secrets.sh > scripts/broken.sh
chmod +x scripts/broken.sh
./scripts/broken.sh >/dev/null 2>&1
check "a malformed pattern fails closed" 2 "$?"

# 10. git missing from PATH is an error too.
PATH="$tmp/nogitbin" /bin/bash scripts/check-secrets.sh >/dev/null 2>&1
check "git missing from PATH fails closed" 2 "$?"

echo
if [ "$fails" -ne 0 ]; then
  echo "check-secrets-selftest: $fails check(s) failed"
  exit 1
fi
echo "check-secrets-selftest: all checks passed"
