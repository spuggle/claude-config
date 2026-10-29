#!/usr/bin/env bash
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/guard-edit.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME
mkdir -p "$HOME/.config/app" "$HOME/notes"
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main

REPO="$WORK/repo"
git init -q "$REPO"
printf '/.claude/worktrees/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A
git -C "$REPO" commit -qm initial
git -C "$REPO" worktree add -q -b claude "$REPO/.claude/worktrees/claude"

PLAIN="$WORK/plain"
git init -q "$PLAIN"
git -C "$PLAIN" commit -q --allow-empty -m initial

ALLOW="$HOME/.config/claude-worktree/edit-allow"

failures=0
expect() {
  local name="$1" want_exit="$2" path="$3" out got
  out="$(jq -cn --arg p "$path" --arg cwd "$WORK" '{cwd:$cwd,tool_input:{file_path:$p}}' | bash "$HOOK" 2>&1)"; got=$?
  if [ "$got" -ne "$want_exit" ]; then
    echo "FAIL  $name: exit $got, want $want_exit"; echo "$out" | sed 's/^/      /'; failures=$((failures + 1))
  else
    echo "ok    $name"
  fi
}

expect "no allow file: path outside any repository is blocked" 2 "$HOME/.config/app/conf"
expect "repository without a claude branch is allowed" 0 "$PLAIN/file"
expect "main checkout with a claude branch is blocked" 2 "$REPO/file"
expect "claude worktree is allowed" 0 "$REPO/.claude/worktrees/claude/file"
# Windows-style paths (Claude Code on native Windows sends C:\\... or C:/...); cygpath is absent here, so the fallback conversion runs
expect "backslash path into the main checkout is blocked" 2 "${REPO//\//\\}\\file"
expect "backslash path into a worktree is allowed" 0 "${REPO//\//\\}\\.claude\\worktrees\\claude\\file"
expect "project .claude/settings.json is blocked" 2 "$PLAIN/.claude/settings.json"
expect "project .claude/settings.backup.json is blocked" 2 "$PLAIN/.claude/settings.backup.json"
expect "worktree .claude/settings.local.json is blocked" 2 "$REPO/.claude/worktrees/claude/.claude/settings.local.json"
expect "VS Code settings.json in a repository is editable" 0 "$PLAIN/dot_config/Code/User/settings.json"
expect "chezmoi source of Claude's settings.json is blocked" 2 "$PLAIN/dot_claude/settings.json"
expect "chezmoi private source of Claude's settings is blocked" 2 "$PLAIN/private_dot_claude/private_settings.local.json"
expect "chezmoi template of Claude's settings is blocked" 2 "$PLAIN/dot_claude/settings.json.tmpl"
expect "chezmoi source of ~/.claude/CLAUDE.md is blocked" 2 "$PLAIN/dot_claude/CLAUDE.md"
expect "chezmoi source of the edit allow file is blocked" 2 "$PLAIN/dot_config/claude-worktree/edit-allow"
expect "other files in the chezmoi dot_claude source are editable" 0 "$PLAIN/dot_claude/agents/x.md"

mkdir -p "$(dirname "$ALLOW")"
printf '# dotfiles\n\n~/.config/*\n' > "$ALLOW"
expect "allow file: listed path outside any repository is allowed" 0 "$HOME/.config/app/conf"
expect "allow file: unlisted path outside any repository is blocked" 2 "$HOME/notes/todo"
expect "allow file: an application's settings.json is editable" 0 "$HOME/.config/Code/User/settings.json"
expect "allow file: the allow file itself stays blocked" 2 "$ALLOW"
printf '~/.claude/*\n' >> "$ALLOW"
expect "allow file: Claude's settings.json stays blocked" 2 "$HOME/.claude/settings.json"
expect "allow file: Claude's settings.local.json stays blocked" 2 "$HOME/.claude/settings.local.json"
expect "allow file: ~/.claude/CLAUDE.md stays blocked" 2 "$HOME/.claude/CLAUDE.md"
expect "allow file: a backup of Claude's settings stays blocked" 2 "$HOME/.claude/settings.backup.json"
printf '%s/*\n' "$REPO" >> "$ALLOW"
expect "allow file: main checkout with a claude branch stays blocked" 2 "$REPO/file"

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
