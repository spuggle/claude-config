#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hook_require_jq
INPUT="$(cat)"
P="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$INPUT")"
[ -n "$P" ] || exit 0
CWD="$(jq -r '.cwd // empty' <<<"$INPUT")"; CWD="${CWD:-$PWD}"
P="$(hook_norm_path "$P")"
case "$P" in /*) ;; *) P="$CWD/$P" ;; esac
P="$(realpath -m "$P")"

PARENT="$(basename "$(dirname "$P")")"
NAME="$(basename "$P")"
case "$PARENT/$NAME" in
  .claude/settings*.json|*dot_claude/*settings*.json|*dot_claude/*settings*.json.tmpl)
    hook_block "edits to ${P} are in the ask-first tier (settings and permissions)." ;;
  *dot_claude/*CLAUDE.md|*dot_claude/*CLAUDE.md.tmpl)
    hook_block "edits to ${P} (the chezmoi source of ~/.claude/CLAUDE.md) are in the ask-first tier." ;;
  *claude-worktree/*edit-allow|*claude-worktree/*edit-allow.tmpl)
    hook_block "edits to ${P} are in the ask-first tier: it is the list of paths Claude may edit." ;;
esac
case "$P" in
  "$HOME/.claude/CLAUDE.md") hook_block "edits to ${P} are in the ask-first tier." ;;
esac
if MIRROR="$(hook_skills_mirror_of)"; then
  case "$P" in
    "$HOME"/.claude/skills/*|"$HOME"/.claude/skills-worktrees/*) hook_block "${P} is in the global skills mirror. Global skills are managed on ${MIRROR}; change them there and they are pushed here." ;;
  esac
fi
DIR="$(hook_nearest_dir "$(dirname "$P")")"
MAIN="$(hook_main_checkout "$DIR" 2>/dev/null || true)"
if [ -n "$MAIN" ] && [ -f "$MAIN/.claude/hooks/pre-edit.sh" ]; then
  bash "$MAIN/.claude/hooks/pre-edit.sh" "$MAIN" "$(hook_worktree_of "$MAIN")" "$P"
  [ $? -eq 2 ] && exit 2
fi

hook_is_worktree_path "$P" && exit 0
case "$P" in
  /tmp/claude-*/*) exit 0 ;;
  "$HOME"/.claude/projects/*/memory/*) exit 0 ;;
  "$HOME"/productivity/*) exit 0 ;;
esac

ALLOW="${XDG_CONFIG_HOME:-$HOME/.config}/claude-worktree/edit-allow"
if [ -z "$MAIN" ] && [ -f "$ALLOW" ]; then
  while IFS= read -r G || [ -n "$G" ]; do
    case "$G" in ''|'#'*) continue ;; esac
    G="$(hook_expand_path "$G")"
    # shellcheck disable=SC2254 # $G is an allow-list glob
    case "$P" in $G) exit 0 ;; esac
  done < "$ALLOW"
fi
[ -n "$MAIN" ] || hook_block "${P} is outside every allowed edit location (claude worktrees, session scratchpad, memory) and not in a git repository."
if hook_has_claude_branch "$MAIN" && ! hook_worktree_opted_out "$MAIN"; then
  hook_block "${P} is in the main checkout of ${MAIN}. Edit the same file under $(hook_worktree_of "$MAIN") instead."
fi
exit 0
