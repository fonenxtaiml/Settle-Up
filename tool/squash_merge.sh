#!/usr/bin/env bash
# Squash merges a branch into the branch that is checked out, with a clean
# commit message: a subject line and the subjects of the merged commits,
# never their bodies (so no trailers are carried over). Use it to bring a
# branch whose history breaks the commit message policy (CONTRIBUTING.md)
# into dev or main without rewriting any shared branch.
#
#   git checkout dev && git pull --ff-only
#   tool/squash_merge.sh origin/qa/integration "Merge QA round 1 fixes"
#   tool/check_commit_messages.sh origin/dev..HEAD && git push origin dev
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=commit_message_policy.sh
source "$here/commit_message_policy.sh"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <source-ref> [subject]" >&2
  exit 2
fi
source_ref="$1"
target="$(git rev-parse --abbrev-ref HEAD)"
subject="${2:-Merge ${source_ref#origin/} into $target}"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "squash_merge: the working tree has changes; commit or stash them." >&2
  exit 1
fi
if [[ -z "$(git rev-list -1 "HEAD..$source_ref")" ]]; then
  echo "squash_merge: $source_ref has nothing that $target lacks."
  exit 0
fi

msg="$(mktemp)"
trap 'rm -f "$msg"' EXIT
{
  printf '%s\n\n' "$subject"
  git log --reverse --no-merges --format='- %s' "HEAD..$source_ref"
} >"$msg"
if bad="$(commit_message_violations <"$msg")"; then
  echo "squash_merge: a commit subject breaks the policy:" >&2
  sed 's/^/  /' <<<"$bad" >&2
  exit 1
fi

git merge --squash "$source_ref"
git commit --file "$msg"
"$here/check_commit_messages.sh" HEAD^..HEAD
