#!/usr/bin/env bash
# Every non-merge commit in BASE..HEAD must carry "Signed-off-by:" matching its author (DCO).
# Usage: scripts/check-dco.sh <base> [<head>]
set -euo pipefail
base="$1"; head="${2:-HEAD}"
fail=0
for sha in $(git rev-list --no-merges "$base..$head"); do
  email=$(git log -1 --format='%ae' "$sha")
  if ! git log -1 --format='%(trailers:key=Signed-off-by,valueonly)' "$sha" | grep -qiF "<$email>"; then
    echo "::error::commit $sha has no 'Signed-off-by:' for its author <$email>. Use 'git commit -s' (see CONTRIBUTING.md)."
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "DCO: ok"
exit "$fail"
