#!/usr/bin/env bash
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME
mkdir -p "$HOME"
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main

REPO="$WORK/dotfiles"
git init -q "$REPO"
printf 'a\n' > "$REPO/file"
git -C "$REPO" add -A
git -C "$REPO" commit -qm initial
git -C "$REPO" config claude.worktree false

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
lacks() {
  local name="$1" text="$2" out="$3"
  if grep -qF -- "$text" <<<"$out"; then echo "FAIL  $name: output has '$text'"; failures=$((failures + 1)); else echo "ok    $name"; fi
}

out="$(jq -cn --arg cwd "$REPO" '{cwd:$cwd,source:"startup"}' | bash "$SRC/hooks/session-start.sh" 2>&1)"; rc=$?
check "session start notes the opt-out" 0 "claude.worktree=false: edit in place, stage, never commit" "$out" "$rc"
lacks "session start does not offer to bootstrap" "No claude branch" "$out"

out="$(bash "$SRC/scripts/ensure-worktree.sh" "$REPO" 2>&1)"; rc=$?
check "ensure-worktree refuses with a message" 0 "claude.worktree=false" "$out" "$rc"
if [ -e "$REPO/.claude/worktrees/claude" ] || git -C "$REPO" rev-parse -q --verify refs/heads/claude >/dev/null; then
  echo "FAIL  ensure-worktree created a worktree or claude branch"; failures=$((failures + 1))
else
  echo "ok    ensure-worktree created no worktree or claude branch"
fi

out="$(jq -cn --arg p "$REPO/file" --arg cwd "$REPO" '{cwd:$cwd,tool_input:{file_path:$p}}' | bash "$SRC/hooks/guard-edit.sh" 2>&1)"; rc=$?
check "guard-edit allows editing in place" 0 "" "$out" "$rc"

printf 'b\n' >> "$REPO/file"
git -C "$REPO" add file
out="$(jq -cn --arg cwd "$REPO" '{cwd:$cwd,stop_hook_active:false}' | bash "$SRC/hooks/stop-check.sh" 2>&1)"; rc=$?
check "stop-check does not complain about staged in-place edits" 0 "" "$out" "$rc"
[ -z "$out" ] && echo "ok    stop-check prints nothing" || { echo "FAIL  stop-check printed: $out"; failures=$((failures + 1)); }

bash_cmd() { printf '%s' "$1" | jq -Rs --arg cwd "$REPO" '{cwd:$cwd,tool_input:{command:.}}' | bash "$SRC/hooks/guard-bash.sh" 2>&1; }
out="$(bash_cmd "git commit -m x")"; check "guard-bash blocks a commit in place" 2 "reviewed by the user: stage changes, never commit" "$out" $?
out="$(bash_cmd "git -C $REPO merge main")"; check "guard-bash blocks a merge in place" 2 "reviewed by the user" "$out" $?
out="$(bash_cmd "git reset --hard")"; check "guard-bash blocks a reset in place" 2 "reviewed by the user" "$out" $?
out="$(bash_cmd "git branch -D old")"; check "guard-bash blocks branch deletion in place" 2 "reviewed by the user" "$out" $?
out="$(bash_cmd "git add file && git status --short && git diff --cached")"; check "guard-bash allows staging and reading" 0 "" "$out" $?
out="$(bash_cmd "git mv file renamed && git rm -q --cached renamed")"; check "guard-bash allows git mv and git rm" 0 "" "$out" $?
out="$(bash_cmd "git restore --staged file && git restore -S file")"; check "guard-bash allows restore --staged" 0 "" "$out" $?
out="$(bash_cmd "git restore --staged --worktree file")"; check "guard-bash blocks restore of the working tree" 2 "reviewed by the user" "$out" $?
out="$(bash_cmd "git restore file")"; check "guard-bash blocks plain restore" 2 "reviewed by the user" "$out" $?
out="$(bash_cmd "git reset")"; check "guard-bash allows git reset with no arguments" 0 "" "$out" $?
out="$(bash_cmd "git reset -q -- file && git reset HEAD -- file")"; check "guard-bash allows git reset with -- paths" 0 "" "$out" $?
out="$(bash_cmd "git reset file")"; check "guard-bash allows git reset of a path" 0 "" "$out" $?
out="$(bash_cmd "git reset file other")"; check "guard-bash allows git reset of several paths" 0 "" "$out" $?
out="$(bash_cmd "git reset main")"; check "guard-bash blocks git reset to a commit" 2 "reviewed by the user" "$out" $?
out="$(bash_cmd "git reset --soft HEAD")"; check "guard-bash blocks git reset --soft" 2 "reviewed by the user" "$out" $?
out="$(bash_cmd "git reset --mixed -- file")"; check "guard-bash blocks git reset with a mode" 2 "reviewed by the user" "$out" $?

# Opted out although a claude branch and worktree exist (for example from before the opt-out)
git -C "$REPO" config claude.worktree true
git -C "$REPO" worktree add -q -b claude "$REPO/.claude/worktrees/claude"
printf 'dirty\n' > "$REPO/.claude/worktrees/claude/file"
git -C "$REPO" config claude.worktree false
out="$(jq -cn --arg p "$REPO/file" --arg cwd "$REPO" '{cwd:$cwd,tool_input:{file_path:$p}}' | bash "$SRC/hooks/guard-edit.sh" 2>&1)"; rc=$?
check "with a claude branch, guard-edit allows editing in place" 0 "" "$out" "$rc"
out="$(jq -cn --arg cwd "$REPO" '{cwd:$cwd,stop_hook_active:false}' | bash "$SRC/hooks/stop-check.sh" 2>&1)"; rc=$?
check "with a claude branch, stop-check does not block" 0 "" "$out" "$rc"
[ -z "$out" ] && echo "ok    with a claude branch, stop-check prints nothing" || { echo "FAIL  with a claude branch, stop-check printed: $out"; failures=$((failures + 1)); }
out="$(bash "$SRC/scripts/ensure-worktree.sh" "$REPO" 2>&1)"; rc=$?
check "with a claude branch, ensure-worktree refuses" 0 "claude.worktree=false" "$out" "$rc"
out="$(jq -cn --arg cwd "$REPO" '{cwd:$cwd,source:"startup"}' | bash "$SRC/hooks/session-start.sh" 2>&1)"; rc=$?
check "with a claude branch, session start notes the opt-out" 0 "claude.worktree=false: edit in place" "$out" "$rc"
lacks "with a claude branch, session start does not report the worktree" "Unmerged Claude commits" "$out"
out="$(bash_cmd "git commit -m x")"; check "with a claude branch, guard-bash still blocks a commit" 2 "reviewed by the user" "$out" $?

git -C "$REPO" worktree remove --force "$REPO/.claude/worktrees/claude"
git -C "$REPO" branch -q -D claude
git -C "$REPO" config claude.worktree true
out="$(jq -cn --arg cwd "$REPO" '{cwd:$cwd,source:"startup"}' | bash "$SRC/hooks/session-start.sh" 2>&1)"; rc=$?
check "claude.worktree=true keeps the bootstrap offer" 0 "No claude branch" "$out" "$rc"

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
