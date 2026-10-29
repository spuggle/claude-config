#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hook_require_jq
INPUT="$(cat)"
TOOL="$(jq -r '.tool_name // empty' <<<"$INPUT")"
CWD="$(jq -r '.cwd // empty' <<<"$INPUT")"; CWD="${CWD:-$PWD}"
TRANSCRIPT="$(jq -r '.transcript_path // empty' <<<"$INPUT")"
GLOBAL_GATES="$(dirname "${BASH_SOURCE[0]}")/../skill-gates"

case "$TOOL" in
  Bash) TARGET="$(jq -r '.tool_input.command // empty' <<<"$INPUT")"; DIR="$CWD" ;;
  Edit|Write|MultiEdit|NotebookEdit)
    TARGET="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$INPUT")"
    TARGET="$(hook_norm_path "$TARGET")"
    case "$TARGET" in /*) ;; *) TARGET="$CWD/$TARGET" ;; esac
    TARGET="$(realpath -m "$TARGET")"
    DIR="$(hook_nearest_dir "$(dirname "$TARGET")")" ;;
  *) exit 0 ;;
esac
[ -n "$TARGET" ] || exit 0

MAIN="$(hook_main_checkout "$DIR" 2>/dev/null || true)"
if [ "$TOOL" != Bash ]; then
  TOP="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$TOP" ] && case "$TARGET" in "$TOP"/*) TARGET="${TARGET#"$TOP"/}" ;; esac
fi

GATE_FILES=("$GLOBAL_GATES")
[ -n "$MAIN" ] && [ -f "$MAIN/.claude/skill-gates" ] && GATE_FILES+=("$MAIN/.claude/skill-gates")

required=()
reasons=()
for gf in "${GATE_FILES[@]}"; do
  [ -f "$gf" ] || continue
  while IFS=$'\t' read -r tools pattern skills reason; do
    [ -n "$tools" ] || continue
    case "$tools" in \#*) continue ;; esac
    [[ "$TOOL" =~ ^($tools)$ ]] || continue
    grep -qE -- "$pattern" <<<"$TARGET" || continue
    for s in $skills; do
      # a skill not installed on this machine (a desktop-only skill on a mirror) cannot be invoked, so its gate is skipped
      case "$s" in agent:*) ;; *) [ -f "$HOME/.claude/skills/$s/SKILL.md" ] || continue ;; esac
      required+=("$s")
    done
    reasons+=("$reason")
  done < "$gf"
done
[ "${#required[@]}" -gt 0 ] || exit 0
AGENT_ID="$(jq -r '.agent_id // empty' <<<"$INPUT")"
PARENT="$TRANSCRIPT"
if [ -n "$AGENT_ID" ]; then
  TRANSCRIPT="${TRANSCRIPT%.jsonl}/subagents/agent-${AGENT_ID}.jsonl"
fi
[ -f "$TRANSCRIPT" ] || exit 0

start=1
boundary="$(grep -n '"subtype":"compact_boundary"' "$TRANSCRIPT" | tail -1 | cut -d: -f1)"
[ -n "$boundary" ] && start="$boundary"

# agent:NAME tokens: the Agent tool with that subagent_type since the last compaction and the last human prompt,
# in the main transcript (a subagent's call is judged by its parent's transcript).
agent_start=1
if [ -f "$PARENT" ]; then
  pb="$(grep -n '"subtype":"compact_boundary"' "$PARENT" | tail -1 | cut -d: -f1)"
  hp="$(grep -n '"origin":{"kind":"human"' "$PARENT" | tail -1 | cut -d: -f1)"
  agent_start="$(printf '%s\n%s\n1\n' "${pb:-1}" "${hp:-1}" | sort -n | tail -1)"
fi

missing=()
for s in $(printf '%s\n' "${required[@]}" | awk '!seen[$0]++'); do
  case "$s" in
    agent:*)
      [ -f "$PARENT" ] || continue
      a="${s#agent:}"
      if ! tail -n +"$agent_start" "$PARENT" | grep -qE "\"name\":\"Agent\",\"input\":\{(\"[a-z_]+\":(\"([^\"\\\\]|\\\\.)*\"|true|false|[0-9]+),)*\"subagent_type\":\"${a}\""; then
        missing+=("$s")
      fi ;;
    *)
      if ! grep -qE "\"name\":\"Skill\",\"input\":\{\"skill\":\"${s}\"|<command-name>/?${s}</command-name>" < <(tail -n +"$start" "$TRANSCRIPT"); then
        missing+=("$s")
      fi ;;
  esac
done
[ "${#missing[@]}" -eq 0 ] && exit 0

LOG="$HOME/.claude/skill-usage.jsonl"
jq -cn --arg t "$(date -u +%FT%TZ)" --arg s "$(jq -r '.session_id // empty' <<<"$INPUT")" --arg tool "$TOOL" --arg m "${missing[*]}" '{time:$t,session:$s,event:"gate-block",tool:$tool,missing:$m}' >> "$LOG" 2>/dev/null
skills_missing=(); agents_missing=()
for m in "${missing[@]}"; do case "$m" in agent:*) agents_missing+=("${m#agent:}") ;; *) skills_missing+=("$m") ;; esac; done
[ "${#skills_missing[@]}" -gt 0 ] && echo "BLOCKED by skill gate: invoke these skills with the Skill tool first, then retry: ${skills_missing[*]}" >&2
[ "${#agents_missing[@]}" -gt 0 ] && echo "BLOCKED by gate: consult the ${agents_missing[*]} with the Agent tool (subagent_type ${agents_missing[*]}), then retry. The call must come after the user's latest message." >&2
printf 'Reason: %s\n' "${reasons[@]}" | awk '!seen[$0]++' >&2
echo "Skill gates fire once per session (and again after a compaction); agent gates once per user message." >&2
exit 2
