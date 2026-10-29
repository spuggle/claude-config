#!/usr/bin/env bash
set -uo pipefail
INPUT="$(cat)"
jq -c --arg t "$(date -u +%FT%TZ)" '{time:$t,session:.session_id,event:"invoke",skill:(.tool_input.skill // .tool_input.name // "unknown"),cwd:.cwd}' <<<"$INPUT" >> "$HOME/.claude/skill-usage.jsonl" 2>/dev/null
exit 0
