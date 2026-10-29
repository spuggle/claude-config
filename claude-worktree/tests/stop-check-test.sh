#!/usr/bin/env bash
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/stop-check.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main

REPO="$WORK/repo"
WT="$REPO/.claude/worktrees/claude"
git init -q "$REPO"
printf '/.claude/worktrees/\n' > "$REPO/.gitignore"
mkdir -p "$REPO/docs"
printf 'state\n' > "$REPO/docs/HANDOFF.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm initial
git -C "$REPO" worktree add -q -b claude "$WT"

TRANSCRIPT=""
run_hook() {
  jq -cn --arg cwd "$REPO" --arg t "$TRANSCRIPT" --argjson active "${2:-false}" '{cwd:$cwd,transcript_path:$t,stop_hook_active:$active}' | bash "$HOOK" "${1:-block}" 2>&1
}

failures=0
expect() {
  local name="$1" want_exit="$2" want_text="$3" out got
  out="$(run_hook "${4:-block}" "${5:-false}")"; got=$?
  if [ "$got" -ne "$want_exit" ]; then
    echo "FAIL  $name: exit $got, want $want_exit"; echo "$out" | sed 's/^/      /'; failures=$((failures + 1))
  elif [ -n "$want_text" ] && ! grep -qF -- "$want_text" <<<"$out"; then
    echo "FAIL  $name: output lacks '$want_text'"; echo "$out" | sed 's/^/      /'; failures=$((failures + 1))
  elif [ -z "$want_text" ] && [ -n "$out" ]; then
    echo "FAIL  $name: unexpected output"; echo "$out" | sed 's/^/      /'; failures=$((failures + 1))
  else
    echo "ok    $name"
  fi
}

expect "fresh worktree passes" 0 ""

printf 'x\n' > "$WT/code.txt"
git -C "$WT" add code.txt
git -C "$WT" commit -qm "Change code without recording it"
expect "commit after the last handoff change blocks" 2 "Change code without recording it"
expect "same problem only warns before compaction" 0 "Change code without recording it" --warn
expect "second stop attempt is allowed" 0 "" block true

printf 'recorded\n' >> "$WT/docs/HANDOFF.md"
git -C "$WT" commit -qam "Record the change"
expect "handoff commit clears the block" 0 ""

printf 'x2\n' >> "$WT/code.txt"
git -C "$WT" commit -qam "Another unrecorded change"
expect "unrecorded change blocks again" 2 "Another unrecorded change"
printf '{"items":[]}\n' > "$WT/docs/state.json"
git -C "$WT" add docs/state.json
git -C "$WT" commit -qm "Record in state.json only"
expect "state.json-only change counts as a handoff update" 0 ""

printf 'x3\n' >> "$WT/code.txt"
git -C "$WT" commit -qam "Unrecorded after state.json"
expect "unrecorded change blocks again (kb)" 2 "Unrecorded after state.json"
mkdir -p "$WT/docs/kb"
printf '{"_schema":1}\n' > "$WT/docs/kb/setup.json"
git -C "$WT" add docs/kb/setup.json
git -C "$WT" commit -qm "Record in docs/kb only"
expect "docs/kb/setup.json-only change counts as a handoff update" 0 ""

printf 'x4\n' >> "$WT/code.txt"
git -C "$WT" commit -qam "Unrecorded after setup.json"
printf '{"_schema":1}\n' > "$WT/docs/kb/host.json"
printf '{"_schema":1}\n' > "$WT/docs/kb/games.json"
git -C "$WT" add docs/kb/host.json docs/kb/games.json
git -C "$WT" commit -qm "Facts only (host.json, games.json)"
expect "host.json and games.json changes do not count as a handoff update" 2 "Unrecorded after setup.json"
printf '{"_schema":1,"a":1}\n' > "$WT/docs/kb/setup.json"
git -C "$WT" commit -qam "Record in docs/kb/setup.json again"
expect "a later setup.json change clears it" 0 ""

printf 'user\n' > "$REPO/user.txt"
git -C "$REPO" add user.txt
git -C "$REPO" commit -qm "User work on main"
git -C "$WT" merge -q --no-edit main
expect "merging the user's branch does not block" 0 ""

printf 'dirty\n' >> "$WT/code.txt"
expect "uncommitted changes still block" 2 "uncommitted changes"
git -C "$WT" checkout -q -- code.txt

rm "$WT/docs/HANDOFF.md"
git -C "$WT" commit -qam "Remove handoff"
printf 'y\n' >> "$WT/code.txt"
git -C "$WT" commit -qam "Change after removal"
expect "worktree without a handoff document is not checked" 0 ""

# Explored facts: a transcript whose current turn reads system state must record a fact.
TRANSCRIPT="$WORK/session.jsonl"
mkdir -p "$WORK/session/subagents"
prompt() { jq -cn --arg t "$1" --arg ts "$2" '{type:"user",timestamp:$ts,message:{role:"user",content:$t}}'; }
tool() { jq -cn --arg n "$1" --argjson i "$2" --arg ts "$3" '{type:"assistant",timestamp:$ts,message:{content:[{type:"tool_use",name:$n,input:$i}]}}'; }
{ prompt "old" 2026-01-01T00:00:00Z; tool Bash '{"command":"lsblk -f"}' 2026-01-01T00:00:01Z; prompt "new" 2026-01-01T00:01:00Z; tool Bash '{"command":"git status"}' 2026-01-01T00:01:01Z; } > "$TRANSCRIPT"
expect "exploration in an earlier turn does not block" 0 ""
tool Bash '{"command":"cat /etc/fstab | grep swap"}' 2026-01-01T00:01:02Z >> "$TRANSCRIPT"
expect "reading /etc without recording blocks" 2 "read system state"
expect "second stop attempt passes after exploring" 0 "" block true
tool Bash '{"command":"pip install x; zip -r a b; umount /mnt"}' 2026-01-01T00:01:03Z > "$WORK/t2"
{ prompt "q" 2026-01-01T00:02:00Z; cat "$WORK/t2"; } > "$TRANSCRIPT"
expect "pip, zip and umount are not state reads" 0 ""
tool Edit '{"file_path":"/x/references/host.md"}' 2026-01-01T00:02:02Z > "$WORK/t3"
{ prompt "q" 2026-01-01T00:02:00Z; tool Read '{"file_path":"/usr/lib/udev/rules.d/30-zram.rules"}' 2026-01-01T00:02:01Z; } > "$TRANSCRIPT"
expect "Read of a system file blocks" 2 "Read /usr/lib/udev"
cat "$WORK/t3" >> "$TRANSCRIPT"
expect "editing a references file clears it" 0 ""
{ prompt "q" 2026-01-01T00:03:00Z; tool Bash '{"command":"python3 ~/.claude/skills/scripts/kb probe --cat host/h --budget 3 --stale 30d"}' 2026-01-01T00:03:01Z; } > "$TRANSCRIPT"
expect "running kb probe is not exploration" 0 ""
{ tool Bash '{"command":"sysctl vm.swappiness"}' 2026-01-01T00:02:59Z; tool Bash '{"command":"VAR=1 timeout 5 swapon --show"}' 2026-01-01T00:03:05Z; } > "$WORK/session/subagents/agent-x.jsonl"
expect "subagent exploration in this turn blocks, earlier is ignored" 2 "1 calls: VAR=1 timeout 5 swapon"
rm "$WORK/session/subagents/agent-x.jsonl"
turn() { { prompt "q" 2026-01-01T00:04:00Z; tool "$1" "$2" 2026-01-01T00:04:01Z; } > "$TRANSCRIPT"; }
turn Bash '{"command":"git commit -m \"Read /etc/fstab and lsblk output\""}'
expect "paths and commands in a commit message are not reads" 0 ""
turn Bash '{"command":"bash -c '"'"'cat /etc/fstab'"'"'"}'
expect "a script given to bash -c is checked" 2 "read system state"
turn Bash '{"command":"ssh remote-host '"'"'lsblk -f'"'"'"}'
expect "a command run over ssh is checked" 2 "read system state"
turn Bash '{"command":"grep -rn swap ~/.claude/skills/references/ 2>/dev/null; lsblk -f"}'
expect "a read of a fact store with 2>/dev/null is not a record" 2 "read system state"
turn Grep '{"pattern":"/etc/fstab","path":"/home/u/project"}'
expect "a Grep pattern naming a system path is not a read" 0 ""
turn Bash '{"command":"df -h /; free -h"}'
expect "live values (df, free) do not block" 0 ""
{ prompt "q" 2026-01-01T00:05:00Z; tool Bash '{"command":"lsblk"}' 2026-01-01T00:05:01Z; jq -cn '{type:"user",origin:{kind:"task-notification"},timestamp:"2026-01-01T00:05:02Z",message:{content:"<task-notification>done</task-notification>"}}'; } > "$TRANSCRIPT"
expect "a task notification does not start a new turn" 2 "read system state"
{ prompt "q" 2026-01-01T00:06:00Z; tool Bash '{"command":"zcat /proc/config.gz | grep ZSWAP"}' 2026-01-01T00:06:01Z; tool Bash '{"command":"sed -i s/a/b/ host-hygiene/references/h.md && python3 kb probe --cat host/h && git commit -qam x"}' 2026-01-01T00:06:02Z; } > "$TRANSCRIPT"
expect "an edit that also runs kb probe counts as recorded" 0 ""
{ prompt "q" 2026-01-01T00:07:00Z; tool Bash '{"command":"zcat /proc/config.gz | grep ZSWAP"}' 2026-01-01T00:07:01Z; tool Bash '{"command":"kb probe host/h; kb ls host/h"}' 2026-01-01T00:07:02Z; } > "$TRANSCRIPT"
expect "kb probe and kb ls are not a record" 2 "1 calls: zcat"
tool Bash '{"command":"~/.claude/skills/scripts/kb add host/h/f --type fact --title T --value v --probe true --source-path p --source-locator l"}' 2026-01-01T00:07:03Z >> "$TRANSCRIPT"
expect "kb add counts as recorded" 0 ""
TRANSCRIPT=""

[ "$failures" -eq 0 ]
