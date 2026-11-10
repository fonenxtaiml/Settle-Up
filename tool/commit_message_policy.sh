#!/usr/bin/env bash
# Commit message policy shared by the commit-msg hook and the history check.
#
# The repository owner asked that commits carry no AI attribution: the
# author is the owner, and messages have no co-author or session trailers
# and no tool advertisements. A message that matches any pattern below is
# rejected.

# Extended regular expressions, matched case-insensitively per line.
COMMIT_MESSAGE_FORBIDDEN=(
  '^co-authored-by:.*(claude|anthropic)'
  '^claude-session:'
  'noreply@anthropic\.com'
  'claude\.ai/code'
  'generated with .*claude'
)

# Prints the offending lines of the message on stdin, one per line. Like
# grep, the exit status is 0 when it found any and 1 when the message is
# clean. Comment lines (starting with '#') are ignored, as git strips them
# from the message.
commit_message_violations() {
  local found=1 line pattern
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == \#* ]] && continue
    for pattern in "${COMMIT_MESSAGE_FORBIDDEN[@]}"; do
      if grep -qiE -- "$pattern" <<<"$line"; then
        printf '%s\n' "$line"
        found=0
        break
      fi
    done
  done
  return $found
}
