#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
MODE="${1:-block}"
INPUT="$(cat)"
if [ "$(jq -r '.stop_hook_active // false' <<<"$INPUT")" = "true" ]; then exit 0; fi
CWD="$(jq -r '.cwd // empty' <<<"$INPUT")"; CWD="${CWD:-$PWD}"

PROBLEMS=()
check_worktree() {
  local main="$1" wt dirty
  hook_has_claude_branch "$main" || return 0
  hook_worktree_opted_out "$main" && return 0
  wt="$(hook_worktree_of "$main")"
  [ -d "$wt" ] || return 0
  dirty="$(git -C "$wt" status --porcelain 2>/dev/null)"
  [ -n "$dirty" ] && PROBLEMS+=("uncommitted changes in ${wt}: $(echo "$dirty" | head -5 | tr '\n' ' ')")
  check_handoff_current "$main" "$wt"
}

check_handoff_current() {
  local main="$1" wt="$2" handoff_rel="docs/HANDOFF.md" last user_head unrecorded
  [ -f "$wt/$handoff_rel" ] || return 0
  last="$(git -C "$wt" log -1 --format=%H -- "$handoff_rel" docs/state.json docs/kb/setup.json 2>/dev/null)"
  [ -n "$last" ] || return 0
  user_head="$(git -C "$main" rev-parse HEAD 2>/dev/null)" || return 0
  unrecorded="$(git -C "$wt" log --no-merges --format='%h %s' "${last}..HEAD" --not "$user_head" 2>/dev/null | head -5)"
  [ -n "$unrecorded" ] && PROBLEMS+=("commits on claude since ${handoff_rel} last changed; record them there (instruction-layer) or confirm none needs recording: $(echo "$unrecorded" | paste -sd ';' | sed 's/;/; /g')")
}

MAIN="$(hook_main_checkout "$CWD" 2>/dev/null || true)"
[ -n "$MAIN" ] && check_worktree "$MAIN"
[ "$MAIN" != "$HOME/.claude/skills" ] && [ -d "$HOME/.claude/skills/.git" ] && check_worktree "$HOME/.claude/skills"
if [ -n "$MAIN" ] && [ -f "$MAIN/.claude/hooks/stop-check.sh" ]; then
  while IFS= read -r line; do [ -n "$line" ] && PROBLEMS+=("$line"); done < <(bash "$MAIN/.claude/hooks/stop-check.sh" "$MAIN" "$(hook_worktree_of "$MAIN")")
fi

# Facts explored this turn (main and subagent transcripts) must be recorded with a probe.
TRANSCRIPT="$(jq -r '.transcript_path // empty' <<<"$INPUT")"
if [ -n "$TRANSCRIPT" ] && [ -n "${PY:-}" ]; then
  line="$("$PY" "$(dirname "${BASH_SOURCE[0]}")/explored-facts.py" "$TRANSCRIPT" 2>/dev/null)"
  [ -n "$line" ] && PROBLEMS+=("$line")
  # Reflection: many lookups or a kb miss then hit, with no kb write this turn (reflect.py)
  line="$("$PY" "$(dirname "${BASH_SOURCE[0]}")/reflect.py" "$TRANSCRIPT" 2>/dev/null)"
  if [ -n "$line" ]; then
    PROBLEMS+=("$line")
    [ "$MODE" = "--warn" ] || jq -cn --arg t "$(date -u +%FT%TZ)" --arg s "$(jq -r '.session_id // empty' <<<"$INPUT")" --arg m "${line%%. Judge*}" \
      '{time:$t,session:$s,event:"reflect-block",detail:$m}' >> "$HOME/.claude/skill-usage.jsonl" 2>/dev/null
  fi
fi

[ "${#PROBLEMS[@]}" -eq 0 ] && exit 0
if [ "$MODE" = "--warn" ]; then
  printf 'Unfinished work before compaction:\n'; printf '  - %s\n' "${PROBLEMS[@]}"
  exit 0
fi
printf 'Before ending the turn, resolve (commit on claude, record in the handoff document or a fact store, or confirm none is needed):\n' >&2
printf '  - %s\n' "${PROBLEMS[@]}" >&2
exit 2
