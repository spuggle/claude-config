#!/usr/bin/env bash
# reflect.py: fires on >= 6 lookups or a kb miss then hit; silent below that and after a kb write.
# End-to-end (stop-check.sh adds the line and logs reflect-block): the last cases.
set -uo pipefail
HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME/.claude"
N=0
prompt() { printf '{"type":"user","origin":{"kind":"human"},"timestamp":"2026-10-28T10:00:00Z","message":{"role":"user","content":"do it"}}\n'; }
# call NAME INPUT_JSON RESULT_TEXT [IS_ERROR]: a tool_use and its tool_result
call() {
  N=$((N + 1))
  jq -cn --arg id "t$N" --arg n "$1" --argjson i "$2" '{type:"assistant",message:{content:[{type:"tool_use",id:$id,name:$n,input:$i}]}}'
  jq -cn --arg id "t$N" --arg r "$3" --argjson e "${4:-false}" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:$id,content:$r,is_error:$e}]}}'
}
reads() { local k; for k in $(seq "$1"); do call Read "{\"file_path\":\"/repo/f$k.md\"}" "$(printf 'x%.0s' {1..100})"; done; }
bash_call() { call Bash "$(jq -cn --arg c "$1" '{command:$c}')" "$2" "${3:-false}"; }

failures=0
expect() { # NAME WANT(fires|silent) TRANSCRIPT [TEXT]
  local out; out="$(python3 "$HOOKS/reflect.py" "$3" 2>&1)"
  if [ "$2" = fires ] && grep -q '^reflect: ' <<<"$out" && { [ -z "${4:-}" ] || grep -qF -- "$4" <<<"$out"; }; then echo "ok    $1"
  elif [ "$2" = silent ] && [ -z "$out" ]; then echo "ok    $1"
  else echo "FAIL  $1: got '$out'"; failures=$((failures + 1)); fi
}

{ prompt; reads 6; } > "$WORK/six.jsonl"
expect "six lookups fire, with steps and chars" fires "$WORK/six.jsonl" "lookups=6"
python3 "$HOOKS/reflect.py" "$WORK/six.jsonl" | grep -qF "chars=600" && echo "ok    chars sums the tool results" || { echo "FAIL  chars not 600"; failures=$((failures + 1)); }
python3 "$HOOKS/reflect.py" "$WORK/six.jsonl" | grep -qF "kb add <topic>/warnings/<id> --type warning" && echo "ok    message names the record command" || { echo "FAIL  record command missing"; failures=$((failures + 1)); }
{ prompt; reads 5; } > "$WORK/five.jsonl"
expect "five lookups are silent" silent "$WORK/five.jsonl"
{ prompt; reads 6; bash_call "kb add host/x/warnings/w --type warning --title T --scenario s --kind slow-lookup --steps 6" "added"; } > "$WORK/written.jsonl"
expect "silent after a kb write" silent "$WORK/written.jsonl"
{ prompt; reads 6; bash_call "kb set host/x/f --value v" "ok"; } > "$WORK/set.jsonl"
expect "silent after kb set" silent "$WORK/set.jsonl"
{ prompt; reads 6; bash_call "kb add --help" "usage"; } > "$WORK/help.jsonl"
expect "kb add --help is not a write" fires "$WORK/help.jsonl"
{ prompt; bash_call "kb find swapx" "Exit code 1
kb: no match for swapx (not recorded)" true; bash_call "kb find swap" "host/x/swap  Swap"; } > "$WORK/misshit.jsonl"
expect "kb miss then hit fires below the threshold" fires "$WORK/misshit.jsonl" "a kb miss was followed by a hit"
{ prompt; bash_call "kb find swap" "host/x/swap  Swap"; bash_call "kb find swapx" "Exit code 1
kb: no match for swapx (not recorded)" true; } > "$WORK/hitmiss.jsonl"
expect "kb hit then miss is silent" silent "$WORK/hitmiss.jsonl"
{ prompt; bash_call "kb find swapx" "Exit code 1
kb: no match (not recorded)" true; } > "$WORK/missonly.jsonl"
expect "a kb miss alone is silent" silent "$WORK/missonly.jsonl"
{ prompt; bash_call "ls /repo" "a"; bash_call "cat /repo/a | head" "a"; bash_call "git log --oneline" "a"; bash_call "kb ls host" "a"; bash_call "kb get host/x" "a"; bash_call "grep -rn foo /repo" "a"; } > "$WORK/bash6.jsonl"
expect "read-only Bash and kb reads count" fires "$WORK/bash6.jsonl" "lookups=6"
{ prompt; bash_call "rm -f /repo/a" "a"; bash_call "git commit -m x" "a"; bash_call "echo hi > /repo/a" "a"; bash_call "sed -i s/a/b/ /repo/a" "a"; bash_call "make" "a"; bash_call "cp a b" "a"; } > "$WORK/bashw.jsonl"
expect "writing Bash does not count" silent "$WORK/bashw.jsonl"
{ prompt; reads 3; call Agent '{"subagent_type":"Explore","prompt":"x"}' "found"; call Agent '{"subagent_type":"general-purpose","prompt":"x"}' "done"; reads 3; } > "$WORK/agents.jsonl"
expect "Explore agents count, other agents do not" fires "$WORK/agents.jsonl" "lookups=7"
{ reads 8; prompt; reads 2; } > "$WORK/old.jsonl"
expect "lookups before the last human prompt do not count" silent "$WORK/old.jsonl"
{ prompt; reads 3; } > "$WORK/sub.jsonl"; mkdir -p "$WORK/sub/subagents"; reads 3 | jq -c '. + {timestamp:"2026-10-28T10:05:00Z"}' > "$WORK/sub/subagents/agent-a.jsonl"
expect "subagent lookups are not counted (Explore would double count)" silent "$WORK/sub.jsonl"
{ prompt; reads 3; } > "$WORK/subw.jsonl"; mkdir -p "$WORK/subw/subagents"
{ reads 3; bash_call "kb add host/x/c --type context --title T --scenario s --body b" "added"; } | jq -c '. + {timestamp:"2026-10-28T10:05:00Z"}' > "$WORK/subw/subagents/agent-a.jsonl"
expect "a kb write in a subagent silences it" silent "$WORK/subw.jsonl"
{ prompt; reads 6; bash_call "kb close setup/items/x" "closed"; } > "$WORK/close.jsonl"
expect "kb close does not silence" fires "$WORK/close.jsonl"
{ prompt; reads 6; bash_call "kb add setup/items/x --type item --title T" "added"; } > "$WORK/additem.jsonl"
expect "kb add of an item does not silence" fires "$WORK/additem.jsonl"
{ prompt; reads 6; bash_call "kb add host/x/f --type fact --title T --probe-none p" "added"; } > "$WORK/addfact.jsonl"
expect "kb add of a fact silences" silent "$WORK/addfact.jsonl"
{ prompt; bash_call "cd /repo" "" ; bash_call "echo a" "a"; bash_call "printf a" "a"; bash_call "nl /repo/f" "a"; bash_call "kb ls host" "a"; bash_call "kb get host/x" "a"; } > "$WORK/cd.jsonl"
expect "cd, echo, printf and nl count as lookups" fires "$WORK/cd.jsonl" "lookups=6"
{ prompt; bash_call "kb get host/nope" "kb: not found: host/nope" true; bash_call "kb get host/x" "ok"; } > "$WORK/nf.jsonl"
expect "kb: not found: is a miss" fires "$WORK/nf.jsonl" "a kb miss was followed by a hit"
{ prompt; for w in a b c d e f; do bash_call "kb ask word$w" "host/x/f | v"; done; } > "$WORK/ask6.jsonl"
expect "kb ask counts as a lookup" fires "$WORK/ask6.jsonl" "lookups=6"
expect "missing transcript is silent" silent "$WORK/nope.jsonl"

# end to end through stop-check.sh
REPO="$WORK/repo"; mkdir -p "$REPO"; git init -q "$REPO"
run_stop() { jq -cn --arg cwd "$REPO" --arg t "$1" '{cwd:$cwd,transcript_path:$t,session_id:"s1",stop_hook_active:false}' | bash "$HOOKS/stop-check.sh" 2>&1; }
out="$(run_stop "$WORK/six.jsonl")"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF "reflect: lookups=6" <<<"$out"; then echo "ok    stop-check blocks with the reflect line"; else echo "FAIL  stop-check: rc=$rc $out"; failures=$((failures + 1)); fi
grep -q '"event":"reflect-block"' "$HOME/.claude/skill-usage.jsonl" 2>/dev/null && echo "ok    block logged as reflect-block" || { echo "FAIL  no reflect-block log"; failures=$((failures + 1)); }
out="$(run_stop "$WORK/five.jsonl")"; rc=$?
[ "$rc" -eq 0 ] && echo "ok    stop-check passes below the threshold" || { echo "FAIL  stop-check below threshold rc=$rc $out"; failures=$((failures + 1)); }

[ "$failures" -eq 0 ]
