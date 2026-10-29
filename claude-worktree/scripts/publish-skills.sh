#!/usr/bin/env bash
# Push the global skills repository's main to every read-only mirror.
# Mirrors are git remotes listed in `git config --get-all skills.mirror`; each
# mirror's repository has receive.denyCurrentBranch=updateInstead and
# .git/mirror-of naming this machine. Run by the post-merge and post-commit
# hooks of ~/.claude/skills (the user's merge publishes), or by hand.
set -uo pipefail
REPO="$HOME/.claude/skills"
[ "$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null)" = main ] || exit 0
rc=0
for remote in $(git -C "$REPO" config --get-all skills.mirror); do
  if git -C "$REPO" push --quiet "$remote" main 2>&1 | sed "s/^/[skills → $remote] /"; [ "${PIPESTATUS[0]}" -eq 0 ]; then
    echo "[skills → $remote] main at $(git -C "$REPO" rev-parse --short main)"
  else
    echo "[skills → $remote] push failed; run $0 when the host is reachable" >&2; rc=1
  fi
done
exit $rc
