#!/usr/bin/env bash
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/guard-bash.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME
mkdir -p "$HOME"
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main

REPO="$WORK/repo"
WT="$REPO/.claude/worktrees/claude"
git init -q "$REPO"
printf '/.claude/worktrees/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A
git -C "$REPO" commit -qm initial
git -C "$REPO" worktree add -q -b claude "$WT"
git -C "$REPO" branch claude-task
git -C "$REPO" tag v1
OTHER="$WORK/other"
mkdir -p "$OTHER"
TAB=$'\t'

failures=0
expect() {
  local name="$1" want_exit="$2" cwd="$3" cmd="$4" want_text="${5:-}" out got
  out="$(printf '%s' "$cmd" | jq -Rs --arg cwd "$cwd" '{cwd:$cwd,tool_input:{command:.}}' | env PATH="${HOOK_PATH:-$PATH}" "$BASH" "$HOOK" 2>&1)"; got=$?
  if [ "$got" -ne "$want_exit" ]; then
    echo "FAIL  $name: exit $got, want $want_exit"; echo "$out" | sed 's/^/      /'; failures=$((failures + 1))
  elif [ -n "$want_text" ] && ! grep -qF -- "$want_text" <<<"$out"; then
    echo "FAIL  $name: output lacks '$want_text'"; echo "$out" | sed 's/^/      /'; failures=$((failures + 1))
  elif grep -q Traceback <<<"$out"; then
    echo "FAIL  $name: parser crashed"; echo "$out" | sed 's/^/      /'; failures=$((failures + 1))
  else
    echo "ok    $name"
  fi
}

# Tokenisation and command position
expect "git write in the main checkout is blocked" 2 "$REPO" "git commit -m x" "main checkout"
expect "git write in the worktree is allowed" 0 "$WT" "git commit -m x"
expect "read-only git in the main checkout is allowed" 0 "$REPO" "git log --oneline && git status"
expect "cd into the main checkout then write is blocked" 2 "$OTHER" "cd $REPO && git commit -m x"
expect "newline separates commands" 2 "$OTHER" "cd $REPO
git commit -m x"
expect "command substitution is parsed" 2 "$OTHER" "echo \$(git -C $REPO commit -m x)"
expect "git as an argument is not a command" 0 "$REPO" "echo git commit"
expect "quoted text in a commit message is not a command" 0 "$REPO" "git -C $WT commit -m 'fix; git merge main'"
expect "here-document body is not parsed as commands" 0 "$REPO" "cat > /dev/null <<'EOF'
git merge main
EOF
git -C $WT commit -qm x"
expect "command after a here-document is parsed" 2 "$OTHER" "cat > /dev/null <<EOF
text
EOF
git -C $REPO commit -qm x"
expect "unbalanced quote falls back to the conservative parse" 2 "$OTHER" "cd $REPO && git commit -m \"x"

# Remote commands are not local
expect "ssh remote command is not local" 0 "$REPO" "ssh remote-host 'cd ~/x && git merge main'"
expect "mosh remote command is not local" 0 "$REPO" "mosh remote-host -- bash -c 'git commit -m x'"
expect "docker exec command is not local" 0 "$REPO" "docker exec box sh -c 'cd /r && git commit -m x'"
expect "kubectl exec command is not local" 0 "$REPO" "kubectl exec pod -- git commit -m x"
expect "local command after an ssh command is still parsed" 2 "$REPO" "ssh remote-host 'ls' && git commit -m x"

# Inner shells and launchers
expect "bash -c with cd into the main checkout is blocked" 2 "$OTHER" "bash -c 'cd $REPO && git commit -m x'"
expect "sh -c with git -C the main checkout is blocked" 2 "$OTHER" "sh -c \"git -C $REPO merge main\""
expect "zsh -lc with cd and reset is blocked" 2 "$OTHER" "zsh -lc 'cd $REPO; git reset --hard'"
expect "bash -c in the worktree is allowed" 0 "$OTHER" "bash -c 'cd $WT && git commit -m x'"
expect "tmux new with cd is blocked" 2 "$OTHER" "tmux new -d -s s 'cd $REPO && git commit -m x'"
expect "tmux new-window -c start directory is used" 2 "$OTHER" "tmux new-window -c $REPO 'git commit -m x'"
expect "tmux split-window in the worktree is allowed" 0 "$OTHER" "tmux split-window -c $WT 'git commit -m x'"
expect "systemd-run --working-directory is used" 2 "$OTHER" "systemd-run --user --working-directory=$REPO git commit -m x"
expect "systemd-run -d uses the current directory" 2 "$REPO" "systemd-run --user -d git commit -m x"
expect "env -C names the directory" 2 "$OTHER" "env -C $REPO git commit -m x"
expect "env and nohup wrappers are seen through" 2 "$REPO" "FOO=1 nohup env A=b git merge main"

# Git global options
expect "git -c before the subcommand is skipped" 2 "$REPO" "git -c user.name=x commit -m y"
expect "git --git-dir and --work-tree name the target" 2 "$OTHER" "git --git-dir=$REPO/.git --work-tree=$REPO commit -m y"
expect "git --git-dir alone names the target" 2 "$OTHER" "git --git-dir $REPO/.git merge main"
expect "git --no-pager -C is handled" 2 "$OTHER" "git --no-pager -C $REPO merge main"

# Added write operations
expect "git pull in the main checkout is blocked" 2 "$REPO" "git pull"
expect "git worktree remove from the main checkout is blocked" 2 "$REPO" "git worktree remove $WT"
expect "git worktree list is allowed" 0 "$REPO" "git worktree list"
expect "update-ref of the user's branch is blocked from the worktree" 2 "$WT" "git update-ref refs/heads/main HEAD" "user's"
expect "update-ref -d of the user's branch is blocked" 2 "$WT" "git update-ref -d refs/heads/main" "user's branch"
expect "update-ref of a claude branch is allowed" 0 "$WT" "git update-ref refs/heads/claude-task HEAD"
expect "branch -f of the user's branch is blocked from the worktree" 2 "$WT" "git branch -f main HEAD" "user's"
expect "branch -D of the user's branch is blocked" 2 "$OTHER" "git -C $WT branch -D main"
expect "branch -m renaming the main checkout's branch is blocked" 2 "$OTHER" "git -C $REPO branch -m renamed" "user's branch main"
expect "branch -M claude over the user's branch is blocked" 2 "$WT" "git branch -M claude main"
expect "branch -d of a claude task branch is allowed" 0 "$WT" "git branch -d claude-task"
expect "plain branch creation is allowed" 0 "$WT" "git branch claude-new"
expect "branch listing is allowed" 0 "$REPO" "git branch -a"
expect "tag deletion is blocked" 2 "$WT" "git tag -d v1"
expect "tag creation is allowed" 0 "$WT" "git tag claude-mark"

# Push, bare stash and privilege escalation
expect "git push is blocked" 2 "$WT" "git push origin claude" "never run by Claude"
expect "git push inside bash -c is blocked" 2 "$OTHER" "bash -c 'git push origin main'" "never run by Claude"
expect "git push after -c is blocked" 2 "$WT" "git -c http.x=y push" "never run by Claude"
expect "git push after --no-pager is blocked" 2 "$WT" "git --no-pager push" "never run by Claude"
expect "the word push in quoted text is not a push" 0 "$WT" "echo \"do not git push here\""
expect "bare git stash is blocked" 2 "$WT" "git stash" "stash stack is shared"
expect "git stash pop after -c is blocked" 2 "$WT" "git -c a=b stash pop" "stash stack is shared"
expect "git stash with options only is blocked" 2 "$WT" "git stash -u" "stash stack is shared"
expect "bare git stash inside tmux is blocked" 2 "$OTHER" "tmux new -d 'git stash'" "stash stack is shared"
expect "git stash push with a message is allowed" 0 "$WT" "git stash push -u -m tag"
expect "git stash apply of a sha is allowed" 0 "$WT" "git stash apply abc123"
expect "git stash list is allowed" 0 "$WT" "git stash list"
expect "sudo is blocked" 2 "$OTHER" "sudo pacman -Syu" "! prefix"
expect "pkexec is blocked" 2 "$OTHER" "pkexec true" "! prefix"
expect "run0 is blocked" 2 "$OTHER" "run0 true" "! prefix"
expect "doas is blocked" 2 "$OTHER" "doas true" "! prefix"
expect "sudo after env assignments is blocked" 2 "$OTHER" "FOO=1 sudo true" "! prefix"
expect "sudo later in a list is blocked" 2 "$OTHER" "ls && sudo true" "! prefix"
expect "sudo inside bash -c is blocked" 2 "$OTHER" "bash -c 'sudo true'" "! prefix"
expect "sudo as an argument is allowed" 0 "$OTHER" "man sudo; grep -r sudo /dev/null; echo 'sudo x'"
expect "sudo on a remote host is not local" 0 "$OTHER" "ssh remote-host 'sudo true'"

# Tabs and newlines in arguments
expect "a tab in an update-ref message does not hide the ref" 2 "$WT" "git update-ref -m \"a${TAB}b\" refs/heads/main HEAD" "branch main"
expect "a newline in an update-ref message does not hide the ref" 2 "$WT" "git update-ref -m \"a
b\" refs/heads/main HEAD" "branch main"
expect "a newline in a tag message does not hide the tag" 2 "$WT" "git tag -f -m \"line1
line2\" v1"
expect "a tab in another branch name does not hide the user's branch" 2 "$WT" "git branch -D \"x${TAB}y\" main" "user's branch"

# Fail closed: large commands, missing or failing python3
PAD="$(head -c 140000 /dev/zero | tr '\0' a)"
expect "push in a command over 128 KB is blocked" 2 "$WT" "git push; : $PAD" "never run by Claude"
expect "a main-checkout commit in a command over 128 KB is blocked" 2 "$WT" "git -C $REPO commit -m x; : $PAD" "main checkout"
mkdir -p "$WORK/nopy" "$WORK/badpy"
for t in jq git cat dirname basename head tail grep sed awk tr cut realpath env mktemp; do ln -sf "$(command -v "$t")" "$WORK/nopy/$t"; done
# passes the interpreter probe (-c), fails on every script
printf '#!/bin/sh\n[ "$1" = -c ] && exit 0\nexit 1\n' > "$WORK/badpy/python3"; chmod +x "$WORK/badpy/python3"
HOOK_PATH="$WORK/nopy"
expect "without python3, push is blocked" 2 "$WT" "git push origin claude" "never run by Claude"
expect "without python3, sudo is blocked" 2 "$OTHER" "sudo true" "! prefix"
expect "without python3, a git write is blocked" 2 "$OTHER" "git -C $REPO commit -m x" "could not be parsed"
expect "without python3, read-only git is allowed" 0 "$REPO" "git log --oneline"
HOOK_PATH="$WORK/badpy:$PATH"
expect "when the parser fails, push is blocked" 2 "$WT" "git push" "never run by Claude"
expect "when the parser fails, a git write is blocked" 2 "$OTHER" "git -C $REPO merge main" "could not be parsed"
expect "when the parser fails, a bare stash is blocked" 2 "$WT" "git stash" "stash stack is shared"
unset HOOK_PATH

# Command substitution, here-documents, pipes into shells, subshells
expect "substitution inside double quotes is parsed" 2 "$OTHER" "echo \"\$(git -C $REPO commit -m x)\"" "main checkout"
expect "cd inside a double-quoted substitution is followed" 2 "$OTHER" "out=\"\$(cd $REPO && git reset --hard)\"" "main checkout"
expect "stash inside a double-quoted substitution is blocked" 2 "$OTHER" "echo \"\$(git -C $REPO stash)\"" "stash stack is shared"
expect "push inside a double-quoted substitution is blocked" 2 "$WT" 'echo "$(git push)"' "never run by Claude"
expect "backticks inside double quotes are parsed" 2 "$WT" 'echo "`git push`"' "never run by Claude"
expect "substitution inside single quotes is text" 0 "$WT" "echo '\$(git push)' '\`git push\`'"
expect "here-document fed to bash is parsed" 2 "$OTHER" "bash <<EOF
cd $REPO && git merge main
EOF" "main checkout"
expect "here-document with push fed to bash is blocked" 2 "$WT" "bash <<EOF
git push
EOF" "never run by Claude"
expect "quoted here-document fed to sh after env is parsed" 2 "$OTHER" "env A=1 sh <<'EOF'
git -C $REPO commit -m x
EOF" "main checkout"
expect "here-string fed to bash is parsed" 2 "$WT" 'bash <<< "git push"' "never run by Claude"
expect "substitution in an unquoted here-document is parsed" 2 "$WT" 'cat <<EOF
$(git push)
EOF' "never run by Claude"
expect "substitution in a quoted here-document is text" 0 "$WT" "cat <<'EOF'
\$(git push)
EOF"
expect "commit message from a quoted here-document is text" 0 "$WT" "git commit -m \"\$(cat <<'EOF'
Fix git push detection; git merge main
sudo whatever
EOF
)\""
expect "<<WORD in single quotes is not a here-document" 2 "$OTHER" "echo '<<EOF'
git -C $REPO commit -m x" "main checkout"
expect "<<WORD in double quotes is not a here-document" 2 "$WT" 'echo "<<EOF"
git push' "never run by Claude"
expect "an unclosed here-document is parsed as commands" 2 "$WT" "cat <<EOF
git push" "never run by Claude"
expect "echo piped into bash is parsed" 2 "$WT" "echo git push | bash" "never run by Claude"
expect "printf piped into sh is parsed" 2 "$OTHER" "printf 'git -C $REPO merge main' | sh" "main checkout"
expect "a leading redirection does not hide the command" 2 "$WT" "2>/dev/null git push" "never run by Claude"
expect "cd inside a subshell does not leak out" 0 "$WT" "(cd $REPO && git log); git commit -m x"
expect "cd inside a subshell applies inside it" 2 "$OTHER" "( cd $REPO && git merge main )" "main checkout"
expect "a comment ends at the newline" 2 "$WT" "ls #x
git push" "never run by Claude"
expect "a comment is not a command" 0 "$REPO" "ls # git commit"
expect "process substitution is parsed" 2 "$WT" "diff <(git push) x" "never run by Claude"
expect "bash -c -- runs its operand" 2 "$WT" 'bash -c -- "git push"' "never run by Claude"
expect "bash -o pipefail -c runs its operand" 2 "$WT" 'bash -o pipefail -c "git push"' "never run by Claude"
expect "bash running a script file does not parse its stdin" 0 "$WT" "bash script.sh <<< 'git push'"
expect "nested substitutions are parsed" 2 "$OTHER" "echo \"\$(echo \"\$(git -C $REPO commit -m x)\")\"" "main checkout"
expect "a parenthesis inside a quoted substitution argument is text" 0 "$WT" "git commit -m \"\$(printf '%s' 'a (b')\""

# Launchers
expect "time -p is a launcher" 2 "$WT" "time -p git push" "never run by Claude"
expect "time -p with a main-checkout commit is blocked" 2 "$OTHER" "time -p git -C $REPO commit -m x" "main checkout"
expect "/usr/bin/time with options is a launcher" 2 "$WT" "/usr/bin/time -f %e git push" "never run by Claude"
expect "a launcher named by path is seen through" 2 "$REPO" "/usr/bin/nohup git merge main" "main checkout"
expect "su -c runs its command and needs root" 2 "$WT" 'su -c "git push"'
expect "su is in the sudo tier" 2 "$OTHER" "su - root" "! prefix"
expect "flock -c runs its command" 2 "$WT" 'flock /tmp/l -c "git push"' "never run by Claude"
expect "flock with options before the lock file runs its command" 2 "$REPO" "flock -w 5 /tmp/l git merge main" "main checkout"
expect "script -c runs its command" 2 "$WT" 'script -qc "git push" /dev/null' "never run by Claude"
expect "find -exec runs its command" 2 "$WT" 'find . -maxdepth 0 -exec git push \;' "never run by Claude"
expect "find -execdir with + runs its command" 2 "$OTHER" "find . -execdir git -C $REPO commit -m x {} +" "main checkout"
expect "find without -exec is allowed" 0 "$REPO" "find . -name git -o -name commit"
expect "parallel runs its command" 2 "$WT" "parallel git push ::: a" "never run by Claude"
expect "a function defined with the function keyword is parsed" 2 "$WT" "function f { git push; }; f" "never run by Claude"
expect "sudo -n true probe is allowed" 0 "$OTHER" "sudo -n true 2>/dev/null || echo no"
expect "sudo -n with a real command is blocked" 2 "$OTHER" "sudo -n lspci -vv" "! prefix"
expect "sudo true without -n is blocked" 2 "$OTHER" "sudo true" "! prefix"

# Git aliases, fetch refspecs, symbolic-ref, stash, help
expect "an alias defined with -c is blocked" 2 "$WT" "git -c alias.p=push p" "alias"
expect "an alias hiding a main-checkout commit is blocked" 2 "$REPO" "git -c alias.c=commit c -m x" "alias"
expect "an alias defined with --config-env is blocked" 2 "$WT" "git --config-env=alias.x=GIT_X x" "alias"
expect "other -c settings are allowed" 0 "$WT" "git -c user.name=x commit -m y"
expect "fetch into the user's branch is blocked" 2 "$WT" "git fetch . claude:main" "branch main"
expect "forced fetch into the user's branch is blocked" 2 "$WT" "git fetch origin +main:refs/heads/main" "branch main"
expect "fetch into a claude branch is allowed" 0 "$WT" "git fetch . main:claude-sync"
expect "fetch into remote-tracking refs is allowed" 0 "$WT" "git fetch origin main:refs/remotes/origin/main && git fetch origin"
expect "symbolic-ref pointing HEAD at the user's branch is blocked" 2 "$WT" "git symbolic-ref HEAD refs/heads/main" "branch main"
expect "symbolic-ref in the main checkout is blocked" 2 "$REPO" "git symbolic-ref HEAD refs/heads/claude" "main checkout"
expect "reading symbolic-ref is allowed" 0 "$REPO" "git symbolic-ref --short HEAD"
expect "git stash drop is blocked" 2 "$WT" "git stash drop" "stash stack is shared"
expect "git stash clear is blocked" 2 "$WT" "git stash clear" "stash stack is shared"
expect "git stash push without a message is blocked" 2 "$WT" "git stash push -u" "stash stack is shared"
expect "git stash push with --message is allowed" 0 "$WT" "git stash push --message=tag"
expect "git stash show is allowed" 0 "$WT" "git stash show -p stash@{0}"
expect "help for a blocked subcommand is allowed" 0 "$REPO" "git push --help; git commit -h; git help push"

# Linear time on many unclosed here-documents (a hook that times out does not block)
HEREDOCS="$(for i in $(seq 1 24000); do printf 'cat <<A%d\n' "$i"; done)"
start_ns="$(date +%s%N)"
expect "240 KB of unclosed here-documents ending in push is blocked" 2 "$WT" "${HEREDOCS}
git push" "never run by Claude"
elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))
if [ "$elapsed_ms" -lt 2000 ]; then echo "ok    240 KB of unclosed here-documents parses in ${elapsed_ms} ms"
else echo "FAIL  240 KB of unclosed here-documents took ${elapsed_ms} ms, want under 2000"; failures=$((failures + 1)); fi

# printf piped into a shell
expect "printf format and arguments piped into bash are parsed" 2 "$WT" "printf '%s\\n' 'git push' | bash" "never run by Claude"
expect "printf piped into a non-shell is not parsed" 0 "$WT" "printf 'git push' | grep y"

# Direct reads of docs/state.json
expect "grep on state.json is blocked" 2 "$WT" "grep x docs/state.json" "scripts/state.sh"
expect "sed on state.json is blocked" 2 "$WT" "sed -n 5p $WT/docs/state.json" "scripts/state.sh"
expect "redirect from state.json is blocked" 2 "$WT" "cat < docs/state.json"
expect "bash -c on state.json is blocked" 2 "$WT" "bash -c 'jq . docs/state.json'"
expect "state.sh with state.json is allowed" 0 "$WT" "scripts/state.sh -f docs/state.json show x"
expect "bash state.sh with state.json is allowed" 0 "$WT" "bash scripts/state.sh -f docs/state.json list"
expect "git diff on state.json is allowed" 0 "$WT" "git diff docs/state.json"
expect "ls on state.json is allowed" 0 "$WT" "ls -l docs/state.json"
# Direct reads of docs/kb/*.json
KBHOME="$HOME/.claude/skills/docs/kb"
expect "cat on a kb file is blocked" 2 "$WT" "cat docs/kb/host.json" "scripts/kb"
expect "grep on a kb file is blocked" 2 "$WT" "grep -n launch docs/kb/games.json" "scripts/kb"
expect "jq on a kb file is blocked" 2 "$WT" "jq . $WT/docs/kb/setup.json"
expect "sed on the main kb store is blocked" 2 "$WT" "sed -n 1,20p $KBHOME/host.json"
expect "a kb glob is blocked" 2 "$WT" "cat docs/kb/*.json"
expect "redirect from a kb file is blocked" 2 "$WT" "cat < docs/kb/host.json"
expect "bash -c on a kb file is blocked" 2 "$WT" "bash -c 'jq . docs/kb/host.json'"
expect "cp of a kb file is blocked" 2 "$WT" "cp docs/kb/host.json /tmp/h.json"
expect "scripts/kb with a kb path is allowed" 0 "$WT" "scripts/kb get games/deadlock/launch/options"
expect "kb run from the skills path is allowed" 0 "$WT" "~/.claude/skills/scripts/kb ls host/managing-host"
expect "KB_DIR with kb is allowed" 0 "$WT" "KB_DIR=$WT/docs/kb $WT/scripts/kb validate"
expect "python3 scripts/kb is allowed" 0 "$WT" "python3 scripts/kb search 'docs/kb'"
expect "git diff on kb files is allowed" 0 "$WT" "git diff docs/kb/host.json"
expect "git add of the kb dir is allowed" 0 "$WT" "git add docs/kb"
expect "ls on the kb dir is allowed" 0 "$WT" "ls -l docs/kb"
expect "wc on a kb file is allowed" 0 "$WT" "wc -c docs/kb/host.json"
expect "check.sh is allowed" 0 "$WT" "scripts/check.sh"
expect "docs/kbx is not the store" 0 "$WT" "cat docs/kbx/a.txt"
# Path tricks, parent directories, git show of a revision's store file, cd into the store
expect "double slash in a kb path is blocked" 2 "$WT" "cat docs//kb/host.json" "scripts/kb"
expect "/./ in a kb path is blocked" 2 "$WT" "cat docs/./kb/host.json"
expect "/../ in a kb path is blocked" 2 "$WT" "cat docs/x/../kb/host.json"
expect "recursive grep on docs is blocked" 2 "$WT" "grep -rn launch docs"
expect "recursive grep on the skills docs dir is blocked" 2 "$WT" "grep -R x ~/.claude/skills/docs/"
expect "rg on docs is blocked" 2 "$WT" "rg launch docs"
expect "grep on docs/* is blocked" 2 "$WT" "grep x docs/*"
expect "cat docs/* is blocked" 2 "$WT" "cat docs/*"
expect "find docs -exec cat is blocked" 2 "$WT" "find docs -name '*.json' -exec cat {} +"
expect "recursive grep on a variable path to docs is blocked" 2 "$WT" 'grep -r x "$HOME/.claude/skills/docs"'
expect "git show of a revision's kb file is blocked" 2 "$WT" "git show claude:docs/kb/host.json" "scripts/kb"
expect "git -C show of a revision's kb file is blocked" 2 "$WT" "git -C $WT show HEAD:docs/kb/setup.json"
expect "git show of the handoff is allowed" 0 "$WT" "git show claude:docs/HANDOFF.md"
expect "recursive grep on src is allowed" 0 "$WT" "grep -rn docs src"
expect "grep on one docs file is allowed" 0 "$WT" "grep x docs/HANDOFF.md"
expect "find docs -name is allowed" 0 "$WT" "find docs -name '*.md'"
expect "cd docs/kb && ls is allowed" 0 "$WT" "cd docs/kb && ls"
expect "cd docs/kb/ ; ls; wc is allowed" 0 "$WT" "cd docs/kb/ ; ls -l ; wc -c host.json"
expect "cd docs/kb && cat is blocked" 2 "$WT" "cd docs/kb && cat host.json"
expect "cd docs && ls is allowed" 0 "$WT" "cd docs && ls"

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
