#!/usr/bin/env bash
# Enables the repository's git hooks (tool/git-hooks) for this clone and
# every worktree of it, and checks that they are active. Run it once after
# cloning:
#   tool/install_git_hooks.sh
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root"
git config core.hooksPath tool/git-hooks
chmod +x tool/git-hooks/*

msg="$(mktemp)"
trap 'rm -f "$msg"' EXIT
printf 'Probe\n\nClaude-Session: https://claude.ai/code/session_probe\n' >"$msg"
if tool/git-hooks/commit-msg "$msg" 2>/dev/null; then
  echo "install_git_hooks: the commit-msg hook did not reject a probe." >&2
  exit 1
fi
echo "Git hooks enabled: core.hooksPath=$(git config --get core.hooksPath)"
