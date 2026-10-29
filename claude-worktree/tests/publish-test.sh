#!/usr/bin/env bash
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME/.claude"
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main

SK="$HOME/.claude/skills"
git init -q "$SK"
cp -r "$SRC" "$SK/claude-worktree"
git -C "$SK" add -A
git -C "$SK" commit -qm initial
git -C "$SK" config core.hooksPath claude-worktree/git-hooks
git -C "$SK" worktree add -q -b claude "$HOME/.claude/skills-worktrees/claude"

MIRROR="$WORK/mirror"
git clone -q "$SK" "$MIRROR"
git -C "$MIRROR" config receive.denyCurrentBranch updateInstead
git -C "$SK" remote add m "$MIRROR"
git -C "$SK" config --add skills.mirror m

failures=0
expect_head() {
  local name="$1" want="$2" got
  got="$(git -C "$MIRROR" rev-parse HEAD)"
  if [ "$got" = "$want" ] && [ -z "$(git -C "$MIRROR" status --porcelain)" ]; then echo "ok    $name"
  else echo "FAIL  $name: mirror at $got, want $want; status: $(git -C "$MIRROR" status --porcelain | head -3)"; failures=$((failures + 1)); fi
}

before="$(git -C "$SK" rev-parse main)"
WT="$HOME/.claude/skills-worktrees/claude"
echo x > "$WT/new"; git -C "$WT" add new; git -C "$WT" commit -qm "on claude" >/dev/null 2>&1
expect_head "commit on claude publishes nothing" "$before"

git -C "$SK" merge -q claude >/dev/null 2>&1
expect_head "merge into main publishes main and updates the mirror's files" "$(git -C "$SK" rev-parse main)"

echo y > "$SK/direct"; git -C "$SK" add direct; git -C "$SK" commit -qm "on main" >/dev/null 2>&1
expect_head "commit on main publishes main" "$(git -C "$SK" rev-parse main)"

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
