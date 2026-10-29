#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HOME="${HOME%/}"
INPUT="$(cat)"
CWD="$(jq -r '.cwd // empty' <<<"$INPUT")"; CWD="${CWD:-$PWD}"
SOURCE="$(jq -r '.source // empty' <<<"$INPUT")"
ENSURE="$HOME/.claude/skills/claude-worktree/scripts/ensure-worktree.sh"

repo_report() {
  local main="$1" wt base
  wt="$(hook_worktree_of "$main")"
  base="$(git -C "$main" symbolic-ref --short HEAD 2>/dev/null || echo main)"
  echo "## Repository ${main} (${base} at $(git -C "$main" rev-parse --short HEAD 2>/dev/null || echo 'no commits'))"
  if [ "$main" = "$HOME/.claude/skills" ] && MIRROR="$(hook_skills_mirror_of)"; then
    echo "Read-only mirror: global skills are managed on ${MIRROR} and pushed here. Do not edit or commit here; propose skill changes to the user for ${MIRROR}."
    return
  fi
  if hook_worktree_opted_out "$main"; then
    echo "claude.worktree=false: edit in place, stage, never commit."
    return
  fi
  if ! hook_has_claude_branch "$main"; then
    echo "No claude branch: bootstrap or create the worktree (claude-worktree skill)."
    return
  fi
  [ -x "$ENSURE" ] && bash "$ENSURE" "$main" 2>&1 | sed 's/^/  /'
  echo "Unmerged Claude commits (${base}..claude):"
  git -C "$main" log --oneline "${base}..claude" 2>/dev/null | head -20 | sed 's/^/  /'
  echo "User commits not yet in claude (claude..${base}):"
  git -C "$main" log --oneline "claude..${base}" 2>/dev/null | head -20 | sed 's/^/  /'
  echo "Uncommitted in worktree:"
  git -C "$wt" status --short 2>/dev/null | head -20 | sed 's/^/  /'
}

KB="$(dirname "${BASH_SOURCE[0]}")/../../scripts/kb"
# Hot sheet first: static text that changes only with the hot kb entries, ahead of everything volatile (cache-friendly).
# Any kb failure, including exit 3 (schema too new), prints nothing here.
if [ -f "$KB" ] && [ -n "${PY:-}" ]; then
  HOT="$("$PY" "$KB" hot 2>/dev/null)" && [ -n "$HOT" ] && echo "$HOT"
fi

echo "# SessionStart report (${SOURCE:-unknown})"
MAIN="$(hook_main_checkout "$CWD")" && repo_report "$MAIN"
[ "${MAIN:-}" != "$HOME/.claude/skills" ] && [ -d "$HOME/.claude/skills/.git" ] && repo_report "$HOME/.claude/skills"

echo "## Skill specialisation map (invoke both)"
SKILL_DIRS=("$HOME/.claude/skills")
if [ -n "${MAIN:-}" ]; then
  WT="$(hook_worktree_of "$MAIN")"
  if [ -d "$WT/.claude/skills" ]; then SKILL_DIRS+=("$WT/.claude/skills"); else SKILL_DIRS+=("$MAIN/.claude/skills"); fi
fi
for d in "${SKILL_DIRS[@]}"; do
  for f in "$d"/*/SKILL.md; do
    [ -f "$f" ] || continue
    name="$(sed -n 's/^name: //p' "$f" | head -1)"
    base="$(sed -n 's/^description: Specialises \([a-z0-9-]*\).*/\1/p' "$f" | head -1)"
    [ -n "$base" ] && echo "  ${base} -> ${name}"
  done
done

HOST="$(hostname -s 2>/dev/null || uname -n | cut -d. -f1)"
# Host facts live in kb (host/<hostname>); re-check their probes (3 s budget, only those unverified for 30 days).
# Facts without a probe are not listed here: that is by design, not a failure.
if [ -f "$KB" ] && [ -n "${PY:-}" ]; then
  "$PY" "$KB" ls "host/${HOST}" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "Host facts: kb ls host/${HOST}"
    STALE="$("$PY" "$KB" probe --cat "host/${HOST}" --budget 3 --stale 30d 2>&1 | grep -v -e '^UNCHECKED .* -> Probe: none' -e '^probe: ')"
    [ -n "$STALE" ] && { echo "Host facts whose probe failed (fix the fact or the probe this session; instruction-layer):"; sed 's/^/  /' <<<"$STALE"; }
  elif [ "$rc" -eq 3 ]; then
    echo "Host facts: kb store schema is newer than scripts/kb understands (exit 3); not probed"
  else
    echo "Host facts: none for ${HOST}"
  fi
else
  echo "Host facts: none for ${HOST} (no kb)"
fi

print_handoff() {
  local main="$1" handoff dir
  handoff="$(hook_worktree_of "$main")/docs/HANDOFF.md"; [ -f "$handoff" ] || handoff="$main/docs/HANDOFF.md"
  [ -f "$handoff" ] || return 0
  dir="$(dirname "$handoff")"
  local state st rendered top
  # kb store: topics and open items. Exit 3 (schema too new) or any failure falls back to section 0.
  if [ -f "$dir/kb/setup.json" ]; then
    if [ -f "$KB" ] && [ -n "${PY:-}" ] \
       && top="$(KB_DIR="$dir/kb" "$PY" "$KB" ls 2>&1)" && rendered="$(KB_DIR="$dir/kb" "$PY" "$KB" render --open 2>&1)"; then
      echo "## Knowledge base (kb ls <topic> to drill down, kb get <path>; not found = not recorded)"
      echo "$top"
      echo "$rendered"
      echo "Handoff: ${handoff} (§1 where state lives; read on demand). Decisions and pitfalls: kb ls setup/decisions, kb ls setup/pitfalls; record new ones with kb add"
      return 0
    fi
    echo "kb unavailable ($(head -1 <<<"${rendered:-${top:-no kb script}}")); falling back to the handoff"
  fi
  state="$dir/state.json"
  if [ ! -f "$dir/kb/setup.json" ] && [ -f "$state" ]; then
    st="$(dirname "${BASH_SOURCE[0]}")/../../scripts/state.sh"
    if [ -f "$st" ] && rendered="$(bash "$st" -f "$state" render 2>&1)"; then
      echo "$rendered"
      echo "Handoff: ${handoff} (§1 where state lives, §2 decisions, §3 pitfalls; read on demand)"
      return 0
    fi
  fi
  echo "## ${handoff} section 0 (first 80 lines)"
  awk '/^## 0\./{p=1} /^## 1\./{p=0} p' "$handoff" | head -80
}

SKILLS="$HOME/.claude/skills"
# The managing host must keep these stores; a mirror has none to restore.
if [ -d "$SKILLS/.git" ] && ! hook_skills_mirror_of >/dev/null; then
  [ -f "$(hook_worktree_of "$SKILLS")/docs/HANDOFF.md" ] || [ -f "$SKILLS/docs/HANDOFF.md" ] \
    || echo "MISSING: global handoff $SKILLS/docs/HANDOFF.md (instruction-layer)"
  HOME_MEMORY="$HOME/.claude/projects/$(sed 's/[^A-Za-z0-9]/-/g' <<<"$HOME")/memory/MEMORY.md"
  [ -s "$HOME_MEMORY" ] || echo "MISSING: home memory index $HOME_MEMORY (instruction-layer)"
fi

if [ -n "${MAIN:-}" ]; then
  WT="$(hook_worktree_of "$MAIN")"
  print_handoff "$MAIN"
  [ -f "$MAIN/.claude/hooks/session-start.sh" ] && bash "$MAIN/.claude/hooks/session-start.sh" "$MAIN" "$WT"
fi
# Outside a project, the global skills handoff is the session's state.
if { [ -z "${MAIN:-}" ] || [ "${CWD%/}" = "${HOME%/}" ]; } && [ "${MAIN:-}" != "$SKILLS" ]; then
  print_handoff "$SKILLS"
fi
exit 0
