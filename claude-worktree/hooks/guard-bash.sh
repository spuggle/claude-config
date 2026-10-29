#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hook_require_jq
INPUT="$(cat)"
CMD="$(jq -r '.tool_input.command // empty' <<<"$INPUT")"
CWD="$(jq -r '.cwd // empty' <<<"$INPUT")"; CWD="${CWD:-$PWD}"
[ -n "$CMD" ] || exit 0

EFFECTIVE="$CWD"
FIRST_CD="$(grep -oE '^\s*cd\s+("[^"]+"|\S+)' <<<"$CMD" | head -1 | sed -E 's/^\s*cd\s+//; s/^"//; s/"$//')"
if [ -n "$FIRST_CD" ]; then EFFECTIVE="$(hook_expand_path "$FIRST_CD")"; fi

MSG_STORE="'%s' reads a store file (docs/kb/*.json or docs/state.json) directly. Use scripts/kb: 'ls [path]' to drill down, 'find', 'get <path>', 'search <regex>', 'links'; 'add'/'set'/'close' to change (docs/state.json: scripts/state.sh) (instruction-layer)."

if RAW="$(printf '%s' "$CMD" | "${PY:-false}" "$(dirname "${BASH_SOURCE[0]}")/raw-store-read.py" 2>/dev/null)"; then :; else
  [ -n "$RAW" ] && hook_block "$(printf "$MSG_STORE" "$RAW")"
fi

MSG_PUSH="git push is never run by Claude."
MSG_STASH="bare git stash, stash pop, drop, clear, or stash push without -m: the stash stack is shared across worktrees. Use a WIP commit, or 'git stash push -u -m <tag>' and 'git stash apply <sha>'."
msg_sudo() { echo "'$1' needs root, which is in the ask-first tier. Give the user the command to run themselves with the ! prefix (! $1)."; }

# Used only when git-write-dirs.py is missing or fails: quote-blind and conservative.
fallback_checks() {
  local git_word='(^|[^[:alnum:]_./-])git[[:space:]]'
  grep -qE "${git_word}[^;&|]*\bpush\b" <<<"$CMD" && hook_block "$MSG_PUSH"
  grep -qE "${git_word}[^;&|]*\bstash\b" <<<"$CMD" && hook_block "$MSG_STASH"
  grep -qE '(^|[;&|(`[:space:]])(sudo|doas|pkexec|run0|su)([[:space:]]|$)' <<<"$CMD" && hook_block "$(msg_sudo "$(head -c 200 <<<"$CMD")")"
  if grep -qE "${git_word}[^;&|]*\b(commit|merge|rebase|reset|cherry-pick|revert|am|switch|checkout|restore|clean|rm|mv|apply|pull|update-ref|branch|tag|worktree|fetch|symbolic-ref)\b" <<<"$CMD"; then
    if ! hook_is_worktree_path "$CWD/" || grep -qE '(^|[[:space:]])(cd|pushd)[[:space:]]|[[:space:]](-C|--git-dir|--work-tree)\b' <<<"$CMD"; then
      hook_block "this command could not be parsed (python3 is missing or git-write-dirs.py failed), so git writes are blocked unless they run plainly inside a claude worktree."
    fi
  fi
  return 0
}

user_ref() {
  local dir="$1" ref="$2" branch
  USER_REF="$ref"
  case "$ref" in
    --stdin) USER_REF="refs given on stdin"; return 0 ;;
    refs/tags/*) return 0 ;;
    HEAD) branch="$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null)" || return 1 ;;
    refs/heads/*) branch="${ref#refs/heads/}" ;;
    *) return 1 ;;
  esac
  case "$branch" in claude|claude-*) return 1 ;; esac
  USER_REF="branch ${branch}"
  return 0
}

if ! FINDINGS="$(printf '%s' "$CMD" | "${PY:-false}" "$(dirname "${BASH_SOURCE[0]}")/git-write-dirs.py" "$CWD" 2>/dev/null)"; then
  fallback_checks
  FINDINGS=""
fi

while IFS=$'\t' read -r kind dir arg inv; do
  case "$kind" in
    push) hook_block "$MSG_PUSH" ;;
    stash) hook_block "$MSG_STASH" ;;
    alias) hook_block "'${inv}' defines a git alias with -c or --config-env, which can run any subcommand unchecked. Run the subcommand itself." ;;
    sudo) hook_block "$(msg_sudo "$inv")" ;;
  esac
  [ -n "$dir" ] && [ -d "$dir" ] || continue
  main="$(hook_main_checkout "$dir")" || continue
  if [ "$main" = "$HOME/.claude/skills" ] && MIRROR="$(hook_skills_mirror_of)"; then
    hook_block "'${inv}' would change the global skills mirror. Global skills are managed on ${MIRROR}; change them there and they are pushed here."
  fi
  if hook_worktree_opted_out "$main"; then
    case "$kind:$arg" in
      write:rm|write:mv|write:reset-index|write:restore-staged) ;;
      write:reset-one:*)
        if git -C "$dir" rev-parse -q --verify "${arg#reset-one:}^{commit}" >/dev/null 2>&1; then
          hook_block "'${inv} ${arg#reset-one:}': ${main} has claude.worktree=false; this repository is reviewed by the user: stage changes, never commit."
        fi ;;
      write:*|ref:*) hook_block "'${inv}': ${main} has claude.worktree=false; this repository is reviewed by the user: stage changes, never commit." ;;
    esac
    continue
  fi
  hook_has_claude_branch "$main" || continue
  case "$kind" in
    write)
      top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || continue
      if [ "$top" = "$main" ]; then
        hook_block "'${inv}' would change the main checkout ${main}. Run it in $(hook_worktree_of "$main") instead; merging into the user's branch is the user's step."
      fi ;;
    ref)
      if user_ref "$dir" "$arg"; then
        hook_block "'${inv}' would change the user's ${USER_REF} in ${main}. Branches other than claude and claude-*, and tags, belong to the user."
      fi ;;
  esac
done <<<"$FINDINGS"

MAIN="$(hook_main_checkout "$EFFECTIVE" 2>/dev/null || hook_main_checkout "$CWD" 2>/dev/null || true)"
if [ -n "$MAIN" ] && [ -f "$MAIN/.claude/hooks/pre-bash.sh" ]; then
  printf '%s' "$INPUT" | bash "$MAIN/.claude/hooks/pre-bash.sh" "$MAIN" "$(hook_worktree_of "$MAIN")" "$EFFECTIVE"
  rc=$?
  [ "$rc" -eq 2 ] && exit 2
fi
exit 0
