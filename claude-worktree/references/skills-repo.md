# The global skills repository

`~/.claude/skills` is itself a repository (Anthropic-managed `synced/` is ignored). Its worktree lives outside it, at `~/.claude/skills-worktrees/claude`, so the skill loader never sees two copies of a skill. Global skill edits are made and committed there, and take effect after the user merges `claude` into `main` in `~/.claude/skills`.

The skills are managed on one machine only, the user's desktop `managing-host`. Every other machine (for example `remote-host`) holds a read-only mirror: its `~/.claude/skills/.git/mirror-of` names the managing host, it has no `claude` branch or worktree, and the hooks block edits and git writes in it. On a mirror, propose a skill change to the user instead of making it. On the desktop, `core.hooksPath` is `claude-worktree/git-hooks`, whose `post-merge` and `post-commit` (on `main` only) run `scripts/publish-skills.sh`, which pushes `main` to each remote in `git config --get-all skills.mirror`; a mirror that was unreachable is caught up by running that script by hand.

## Adding a mirror machine

On the desktop the repository's `origin` is `git@github.com:<owner>/claude-config.git` (private), which chezmoi also clones on a fresh install (`.chezmoiexternal`). To make another machine a mirror (the user runs or approves each step):
1. On that machine, clone or copy the repository to `~/.claude/skills`, remove any `claude` branch and worktree once their commits are in the desktop's `main`, then `git config receive.denyCurrentBranch updateInstead` and `echo managing-host > .git/mirror-of`.
2. On the desktop, `git -C ~/.claude/skills remote add <name> <host>:.claude/skills` and `git -C ~/.claude/skills config --add skills.mirror <name>`.
3. The next merge publishes; to publish now, the user runs `bash ~/.claude/skills/claude-worktree/scripts/publish-skills.sh`.
