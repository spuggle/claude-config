#!/usr/bin/env bash
set -uo pipefail

REPO="$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || { echo "ensure-worktree: not a git repository: ${1:-.}"; exit 1; }
MAIN="$(dirname "$REPO")"
if [ "$(git -C "$MAIN" config --bool claude.worktree 2>/dev/null)" = false ]; then
  echo "ensure-worktree: ${MAIN} has claude.worktree=false; it is edited in place (stage, never commit), so no worktree is created"
  exit 0
fi
if ! git -C "$MAIN" rev-parse -q --verify HEAD >/dev/null; then
  echo "ensure-worktree: ${MAIN} has no commits; bootstrap it first (claude-worktree skill)"
  exit 1
fi
if [ "$MAIN" = "$HOME/.claude/skills" ]; then
  WT="$HOME/.claude/skills-worktrees/claude"
else
  WT="$MAIN/.claude/worktrees/claude"
fi
BASE="$(git -C "$MAIN" symbolic-ref --short HEAD)"

if [ ! -e "$WT/.git" ]; then
  mkdir -p "$(dirname "$WT")"
  if git -C "$MAIN" rev-parse -q --verify refs/heads/claude >/dev/null; then
    git -C "$MAIN" worktree add -q "$WT" claude || exit 1
  else
    git -C "$MAIN" worktree add -q -b claude "$WT" "$BASE" || exit 1
  fi
  echo "ensure-worktree: created ${WT}"
fi

LINKS="$WT/.claude/worktree-links"
[ -f "$LINKS" ] || LINKS="$MAIN/.claude/worktree-links"
RC=0
if [ -f "$LINKS" ]; then
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    target="$MAIN/$rel"
    link="$WT/$rel"
    if [ -L "$link" ]; then
      if [ "$(readlink "$link")" = "$target" ]; then
        echo "link ok      $rel"
      else
        echo "link WRONG   $rel -> $(readlink "$link"), expected $target"; RC=1
      fi
    elif [ -e "$link" ]; then
      echo "link BLOCKED $rel exists in the worktree as a real path; expected a link to $target"; RC=1
    elif [ ! -e "$target" ]; then
      echo "link MISSING-TARGET $rel: $target does not exist"; RC=1
    else
      mkdir -p "$(dirname "$link")"
      ln -s "$target" "$link"
      echo "link created $rel -> $target"
    fi
  done < "$LINKS"
fi

echo "worktree ${WT} on $(git -C "$WT" rev-parse --abbrev-ref HEAD) at $(git -C "$WT" rev-parse --short HEAD)"
exit $RC
