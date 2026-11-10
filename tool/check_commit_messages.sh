#!/usr/bin/env bash
# Checks every commit in a range (default origin/main..HEAD) against the
# commit message policy. Run it before pushing to dev or main, for example
# after a squash merge:
#   tool/check_commit_messages.sh origin/dev..HEAD
# Exit status 1 lists each offending commit.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=commit_message_policy.sh
source "$here/commit_message_policy.sh"

range="${1:-origin/main..HEAD}"
status=0
count=0
while read -r sha; do
  [[ -z "$sha" ]] && continue
  count=$((count + 1))
  if bad="$(git log -1 --format=%B "$sha" | commit_message_violations)"; then
    echo "$(git log -1 --format='%h %s' "$sha")"
    sed 's/^/    /' <<<"$bad"
    status=1
  fi
done < <(git rev-list "$range")

if [[ $status -ne 0 ]]; then
  echo "Commits above break the commit message policy (CONTRIBUTING.md)." >&2
  echo "Do not merge them as they are: squash merge with a clean message." >&2
else
  echo "$count commit(s) in $range: commit messages are clean."
fi
if [[ "$(git config --get core.hooksPath || true)" != "tool/git-hooks" ]]; then
  echo "Note: the commit-msg hook is not enabled in this clone; run" \
    "tool/install_git_hooks.sh." >&2
fi
exit $status
