#!/usr/bin/env bash
set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/skill-gate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home/.claude" "$WORK/cwd"
# the gate skips skills that are not installed, so install a stub for each skill the gates name
for s in $(cut -f3 "$(dirname "$GATE")/../skill-gates" | tr ' ' '\n' | grep -v '^agent:' | sort -u); do
  mkdir -p "$WORK/home/.claude/skills/$s"; : > "$WORK/home/.claude/skills/$s/SKILL.md"
done

skill_line() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"%s"}}]}}\n' "$1"; }
boundary_line() { printf '{"type":"system","subtype":"compact_boundary"}\n'; }
padding_lines() { local line; line="$(printf '{"type":"user","pad":"%0500d"}' 0)"; for _ in $(seq "$1"); do printf '%s\n' "$line"; done; }

run_gate() {
  local transcript="$1"
  jq -cn --arg t "$transcript" --arg cwd "$WORK/cwd" --arg c "git -C /x com""mit -m y" \
    '{tool_name:"Bash",cwd:$cwd,transcript_path:$t,session_id:"test",tool_input:{command:$c}}' \
    | HOME="$WORK/home" bash "$GATE" >/dev/null 2>&1
}

failures=0
expect() {
  local name="$1" want="$2" transcript="$3" got
  run_gate "$transcript"; got=$?
  if [ "$got" -eq "$want" ]; then echo "ok    $name"; else echo "FAIL  $name: exit $got, want $want"; failures=$((failures + 1)); fi
}

{ skill_line claude-worktree; padding_lines 2000; } > "$WORK/early-large.jsonl"
expect "invocation early in a transcript larger than a pipe buffer passes" 0 "$WORK/early-large.jsonl"

{ padding_lines 2000; skill_line claude-worktree; } > "$WORK/late-large.jsonl"
expect "invocation late in a large transcript passes" 0 "$WORK/late-large.jsonl"

{ skill_line claude-worktree; padding_lines 3; } > "$WORK/small.jsonl"
expect "invocation in a small transcript passes" 0 "$WORK/small.jsonl"

{ skill_line other-skill; padding_lines 2000; } > "$WORK/missing.jsonl"
expect "transcript without the invocation blocks" 2 "$WORK/missing.jsonl"

{ skill_line claude-worktree; padding_lines 2000; boundary_line; padding_lines 5; } > "$WORK/before-boundary.jsonl"
expect "invocation only before the last compaction blocks" 2 "$WORK/before-boundary.jsonl"

{ padding_lines 5; boundary_line; skill_line claude-worktree; padding_lines 2000; } > "$WORK/after-boundary.jsonl"
expect "invocation early after the last compaction passes" 0 "$WORK/after-boundary.jsonl"

# Edit/Write of a kb topic file is gated on instruction-layer
gate_edit() { # TOOL PATH TRANSCRIPT
  jq -cn --arg t "$3" --arg cwd "$WORK/cwd" --arg tool "$1" --arg p "$2" \
    '{tool_name:$tool,cwd:$cwd,transcript_path:$t,session_id:"test",tool_input:{file_path:$p}}' \
    | HOME="$WORK/home" bash "$GATE" >/dev/null 2>&1
}
expect_edit() {
  local name="$1" want="$2" tool="$3" path="$4" transcript="$5" got
  gate_edit "$tool" "$path" "$transcript"; got=$?
  if [ "$got" -eq "$want" ]; then echo "ok    $name"; else echo "FAIL  $name: exit $got, want $want"; failures=$((failures + 1)); fi
}
{ skill_line instruction-layer; padding_lines 3; } > "$WORK/il.jsonl"
expect_edit "Edit of docs/kb/host.json without instruction-layer blocks" 2 Edit /r/docs/kb/host.json "$WORK/missing.jsonl"
expect_edit "Write of docs/kb/setup.json without instruction-layer blocks" 2 Write /r/docs/kb/setup.json "$WORK/missing.jsonl"
expect_edit "Edit of docs/kb/host.json after instruction-layer passes" 0 Edit /r/docs/kb/host.json "$WORK/il.jsonl"
expect_edit "a nested file under docs/kb is not gated" 0 Edit /r/docs/kb/sub/x.json "$WORK/missing.jsonl"
expect_edit "docs/kb/.lock is not gated" 0 Write /r/docs/kb/.lock "$WORK/missing.jsonl"

# agent:advisor token (project gate in a temp repo's .claude/skill-gates)
R="$WORK/repo"; mkdir -p "$R/.claude" "$R/hooks"
git -C "$R" init -q -b main
printf 'Edit|Write|MultiEdit\t^hooks/\tagent:advisor\tcore workflow: consult the advisor\n' > "$R/.claude/skill-gates"
adv_line() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"description":"Advisor review","subagent_type":"advisor","prompt":"x"}}]}}\n'; }
human_line() { printf '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"go"}}\n'; }
gate_adv() { # TRANSCRIPT [AGENT_ID]
  jq -cn --arg t "$1" --arg cwd "$R" --arg p "$R/hooks/x.sh" --arg a "${2:-}" \
    '{tool_name:"Edit",cwd:$cwd,transcript_path:$t,session_id:"test",tool_input:{file_path:$p}} + (if $a != "" then {agent_id:$a} else {} end)' \
    | HOME="$WORK/home" bash "$GATE" 2>"$WORK/adv.err" >/dev/null
}
expect_adv() {
  local name="$1" want="$2" got; shift 2
  gate_adv "$@"; got=$?
  if [ "$got" -eq "$want" ]; then echo "ok    $name"; else echo "FAIL  $name: exit $got, want $want"; failures=$((failures + 1)); fi
}
{ human_line; padding_lines 3; } > "$WORK/adv-none.jsonl"
expect_adv "edit of a gated hook without an advisor call blocks" 2 "$WORK/adv-none.jsonl"
grep -q "subagent_type advisor" "$WORK/adv.err" && echo "ok    block message names the advisor agent" || { echo "FAIL  block message lacks the advisor instruction"; failures=$((failures + 1)); }
{ human_line; adv_line; padding_lines 3; } > "$WORK/adv-ok.jsonl"
expect_adv "advisor call after the human prompt passes (input key order tolerated)" 0 "$WORK/adv-ok.jsonl"
{ adv_line; human_line; padding_lines 3; } > "$WORK/adv-old-turn.jsonl"
expect_adv "advisor call before the latest human prompt blocks (per-turn reset)" 2 "$WORK/adv-old-turn.jsonl"
{ human_line; adv_line; boundary_line; padding_lines 3; } > "$WORK/adv-compact.jsonl"
expect_adv "advisor call before the last compaction blocks" 2 "$WORK/adv-compact.jsonl"
{ adv_line; padding_lines 3; } > "$WORK/adv-nohuman.jsonl"
expect_adv "no human prompt in the transcript: only the compaction boundary counts" 0 "$WORK/adv-nohuman.jsonl"
mkdir -p "$WORK/sub/adv-ok/subagents" "$WORK/sub/adv-none/subagents"
{ human_line; adv_line; } > "$WORK/sub/adv-ok.jsonl"; padding_lines 2 > "$WORK/sub/adv-ok/subagents/agent-a1.jsonl"
{ human_line; padding_lines 2; } > "$WORK/sub/adv-none.jsonl"; { adv_line; padding_lines 2; } > "$WORK/sub/adv-none/subagents/agent-a1.jsonl"
expect_adv "subagent edit passes when the parent transcript has the advisor call" 0 "$WORK/sub/adv-ok.jsonl" a1
expect_adv "subagent edit blocks when only the subagent transcript has the advisor call" 2 "$WORK/sub/adv-none.jsonl" a1

{ human_line; adv_line; printf '{"type":"user","origin":{"kind":"task-notification","producer":"session-task"},"message":{"role":"user","content":"done"}}\n'; printf '{"type":"user","origin":{"kind":"peer"},"message":{"role":"user","content":"hi"}}\n'; padding_lines 2; } > "$WORK/adv-notify.jsonl"
expect_adv "task-notification and peer messages do not reset the gate" 0 "$WORK/adv-notify.jsonl"
# a side-branch worktree (claude-x) maps its paths to repo-relative ones
git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$R" worktree add -q -b claude-x "$R/.claude/worktrees/claude-x"
mkdir -p "$R/.claude/worktrees/claude-x/hooks"
wt_edit() { # TRANSCRIPT
  jq -cn --arg t "$1" --arg cwd "$R/.claude/worktrees/claude-x" --arg p "$R/.claude/worktrees/claude-x/hooks/x.sh" \
    '{tool_name:"Edit",cwd:$cwd,transcript_path:$t,session_id:"test",tool_input:{file_path:$p}}' | HOME="$WORK/home" bash "$GATE" >/dev/null 2>&1
}
wt_edit "$WORK/adv-none.jsonl"; got=$?
if [ "$got" -eq 2 ]; then echo "ok    edit in a claude-x worktree is gated"; else echo "FAIL  claude-x worktree edit: exit $got, want 2"; failures=$((failures + 1)); fi
wt_edit "$WORK/adv-ok.jsonl"; got=$?
if [ "$got" -eq 0 ]; then echo "ok    claude-x worktree edit passes after the advisor call"; else echo "FAIL  claude-x worktree edit with advisor: exit $got, want 0"; failures=$((failures + 1)); fi

# a gate naming a skill that is not installed is skipped (a mirror without the desktop-only skills)
rm -rf "$WORK/home/.claude/skills/claude-worktree"
{ padding_lines 3; } > "$WORK/noskill.jsonl"
expect "a gate for a skill that is not installed does not block" 0 "$WORK/noskill.jsonl"
mkdir -p "$WORK/home/.claude/skills/claude-worktree"; : > "$WORK/home/.claude/skills/claude-worktree/SKILL.md"
expect "the same gate blocks once the skill is installed" 2 "$WORK/noskill.jsonl"

# without jq the guard blocks instead of failing open
NOJQ="$WORK/nojq"; mkdir -p "$NOJQ"
for t in cat dirname basename git env; do ln -sf "$(command -v "$t")" "$NOJQ/$t"; done
echo '{}' | env PATH="$NOJQ" HOME="$WORK/home" "$BASH" "$GATE" >/dev/null 2>"$WORK/nojq.err"; got=$?
if [ "$got" -eq 2 ] && grep -q 'jq is not installed' "$WORK/nojq.err"; then echo "ok    missing jq blocks"; else echo "FAIL  missing jq: exit $got"; failures=$((failures + 1)); fi

[ "$failures" -eq 0 ]
