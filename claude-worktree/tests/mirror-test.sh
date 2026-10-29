#!/usr/bin/env bash
set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME
mkdir -p "$HOME/.claude"
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main

SK="$HOME/.claude/skills"
git init -q "$SK"
mkdir -p "$SK/demo"
printf -- '---\nname: demo\ndescription: demo\n---\n' > "$SK/demo/SKILL.md"
git -C "$SK" add -A
git -C "$SK" commit -qm initial

failures=0
check() {
  local name="$1" want_exit="$2" want_text="$3" out="$4" got="$5"
  if [ "$got" -ne "$want_exit" ]; then
    echo "FAIL  $name: exit $got, want $want_exit"; echo "$out" | sed 's/^/      /'; failures=$((failures + 1))
  elif [ -n "$want_text" ] && ! grep -qF -- "$want_text" <<<"$out"; then
    echo "FAIL  $name: output lacks '$want_text'"; echo "$out" | sed 's/^/      /'; failures=$((failures + 1))
  else
    echo "ok    $name"
  fi
}
edit() { jq -cn --arg p "$1" --arg cwd "$HOME" '{cwd:$cwd,tool_input:{file_path:$p}}' | bash "$HOOKS/guard-edit.sh" 2>&1; }
bash_cmd() { jq -cn --arg c "$1" --arg cwd "$HOME" '{cwd:$cwd,tool_input:{command:$c}}' | bash "$HOOKS/guard-bash.sh" 2>&1; }
start() { jq -cn --arg cwd "$HOME" '{cwd:$cwd,source:"startup"}' | bash "$HOOKS/session-start.sh" 2>&1; }

out="$(edit "$SK/demo/SKILL.md")"; check "not a mirror: skills repo without a claude branch is editable" 0 "" "$out" $?
out="$(bash_cmd "git -C $SK commit -qm x")"; check "not a mirror: git commit in the skills repo is allowed" 0 "" "$out" $?
out="$(start)"; check "not a mirror: session start offers to bootstrap" 0 "No claude branch" "$out" $?

printf 'desktop-host\n' > "$SK/.git/mirror-of"
out="$(edit "$SK/demo/SKILL.md")"; check "mirror: edit in the skills repo is blocked and names the host" 2 "desktop-host" "$out" $?
out="$(edit "$HOME/.claude/skills-worktrees/claude/demo/SKILL.md")"; check "mirror: edit in a skills worktree path is blocked" 2 "desktop-host" "$out" $?
out="$(bash_cmd "git -C $SK commit -qm x")"; check "mirror: git commit in the skills repo is blocked" 2 "desktop-host" "$out" $?
out="$(bash_cmd "cd $SK && git commit -qm x")"; check "mirror: cd into the skills repo then commit is blocked" 2 "desktop-host" "$out" $?
out="$(bash_cmd "git -C $SK log --oneline")"; check "mirror: read-only git in the skills repo is allowed" 0 "" "$out" $?
out="$(start)"; check "mirror: session start reports the mirror" 0 "managed on desktop-host" "$out" $?
if grep -qF "No claude branch" <<<"$out"; then echo "FAIL  mirror: session start still offers to bootstrap"; failures=$((failures + 1)); else echo "ok    mirror: session start does not offer to bootstrap"; fi
out="$(start)"; check "mirror: specialisation map still lists the mirror's skills" 0 "Skill specialisation map" "$out" $?

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
