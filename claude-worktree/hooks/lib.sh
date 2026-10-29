#!/usr/bin/env bash

# A python 3 interpreter: python3 is absent on Windows (python or the py launcher instead) and may be a Store stub.
hook_py_resolve() {
  local c
  for c in python3 python py; do
    command -v "$c" >/dev/null 2>&1 || continue
    "$c" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1 && { echo "$c"; return 0; }
  done
  return 1
}
# shellcheck disable=SC2034 # read by the scripts that source this file
PY="$(hook_py_resolve || true)"

# POSIX form of a path: Windows C:\Users\x or C:/Users/x becomes /c/Users/x (Git Bash), other paths pass through.
hook_norm_path() {
  local p="$1"
  case "$p" in
    [A-Za-z]:[\\/]*|*\\*)
      if command -v cygpath >/dev/null 2>&1; then p="$(cygpath -u "$p")"
      else
        p="${p//\\//}"
        [[ "$p" =~ ^([A-Za-z]):(.*)$ ]] && p="/${BASH_REMATCH[1],,}${BASH_REMATCH[2]}"
      fi ;;
  esac
  printf '%s\n' "$p"
}

# The guards parse their input with jq; without it they would read empty paths and allow everything.
hook_require_jq() {
  command -v jq >/dev/null 2>&1 || hook_block "jq is not installed, so this guard cannot read the tool call and would fail open. Install jq (see claude-worktree/references/mirror.md)."
}

hook_main_checkout() {
  local dir="$1" common
  common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  dirname "$common"
}

hook_has_claude_branch() {
  git -C "$1" rev-parse -q --verify refs/heads/claude >/dev/null 2>&1
}

hook_worktree_opted_out() {
  [ "$(git -C "$1" config --bool claude.worktree 2>/dev/null)" = false ]
}

hook_worktree_of() {
  if [ "$1" = "$HOME/.claude/skills" ]; then
    echo "$HOME/.claude/skills-worktrees/claude"
  else
    echo "$1/.claude/worktrees/claude"
  fi
}

hook_is_worktree_path() {
  case "$1" in
    */.claude/worktrees/*|"$HOME"/.claude/skills-worktrees/*) return 0 ;;
  esac
  return 1
}

hook_nearest_dir() {
  local p="$1"
  while [ ! -d "$p" ] && [ "$p" != "/" ] && [ "$p" != "." ]; do p="$(dirname "$p")"; done
  echo "$p"
}

hook_expand_path() {
  local p="$1"
  # shellcheck disable=SC2088 # the patterns match a literal ~/ prefix
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p:2}" ;;
    '$HOME') p="$HOME" ;;
    '$HOME/'*) p="$HOME/${p:6}" ;;
    '${HOME}') p="$HOME" ;;
    '${HOME}/'*) p="$HOME/${p:8}" ;;
  esac
  printf '%s\n' "$p"
}

hook_block() {
  echo "BLOCKED by hook: $*" >&2
  echo "See the claude-worktree and session-context skills (ask/decide/stop tiers). Do not work around this block; if the user asked for this action, report the block and give them the command to run themselves." >&2
  exit 2
}

hook_skills_mirror_of() {
  local f="$HOME/.claude/skills/.git/mirror-of"
  [ -f "$f" ] && head -1 "$f"
}
