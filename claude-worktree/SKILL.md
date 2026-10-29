---
name: claude-worktree
description: Keep Claude's changes on a `claude` branch worktree for the user to review and merge. Use before the first edit or any commit in a git repository, when a hook blocks an edit or git command, and when a repository has no claude worktree, no commits, no .gitignore, or claude.worktree=false.
---

# Working in a `claude` worktree

Claude edits files only inside `<project>/.claude/worktrees/claude`, on branch `claude`. The user's checkout and its branches belong to the user. The user reviews `git diff <main>..claude` and merges. Claude never merges, rebases, resets or pushes the user's branches.

## Where edits are allowed

Edit and Write go only to:
- a `claude` worktree (`<repo>/.claude/worktrees/claude*`, or `~/.claude/skills-worktrees/claude*` for the global skills repository);
- the session scratchpad;
- the auto-memory directory `~/.claude/projects/<key>/memory/`;
- `~/productivity/`, the working directory of the Productivity plugin (its `CLAUDE.md`, `TASKS.md`, `memory/` and `dashboard.html` live there, never in a repository);
- a path in a repository that has no `claude` branch yet, during **Bootstrap** only;
- a path outside every repository that matches a glob in the machine's `~/.config/claude-worktree/edit-allow` (one glob per line, `~` expands, `#` comments). It exists only on machines whose dotfiles are reviewed another way (on the desktop, chezmoi); it never unblocks Claude's settings, `~/.claude/CLAUDE.md`, the allow file itself, or a main checkout that has a `claude` branch.

Everything else is off limits, including `~/.claude/settings*.json`, `~/.claude/CLAUDE.md` and their chezmoi source copies, the user's checkouts, and the edit-allow file. To change one of these, ask first. The PreToolUse hook enforces this list. List every edit made outside a worktree in the end-of-turn report.

## The global skills repository

`~/.claude/skills` is itself a repository with its worktree at `~/.claude/skills-worktrees/claude`. It is edited only on the desktop `managing-host`; other machines hold a read-only mirror. Read `references/skills-repo.md` before changing a global skill or when a hook mentions the mirror.

## At session start

Skip this section when the working directory is `$HOME` or not a project.
If `git config --bool claude.worktree` is `false` in a repository (the chezmoi source repo), edit it in place, stage the changes (`git add`, `git rm`, `git mv`), and never commit, merge or push; the Bash hook blocks those there. The user reviews `git diff --staged` and commits. The rest of this skill does not apply to that repository.

Run these from the project directory:
1. `git rev-parse --is-inside-work-tree`, `git rev-list --all --count`, and `git worktree list`.
2. Then branch on the result:
   - No repository, or a repository with no commits: go to **Bootstrap**.
   - The worktree exists: read `git -C .claude/worktrees/claude status --short` and `git log --oneline <main>..claude`. That is the record of Claude's unmerged work.
   - Commits exist but there is no worktree: go to **Create the worktree**.
3. Sessions keep starting in the project directory, not in the worktree. Auto-memory, project settings and skills are keyed to that directory.

## Bootstrap (no repository, or no commits)

Read `references/bootstrap.md` and follow it, only after the user has agreed in this conversation: init, identity, `.gitignore`, secret scan, personal files, review, first commit. Its last section covers publishing to GitHub.

## Create or verify the worktree

1. Run `bash ~/.claude/skills/claude-worktree/scripts/ensure-worktree.sh <repo>`. It creates the worktree if it is missing (from branch `claude` if it exists, otherwise from the main checkout's current branch), creates the shared-state links listed in `.claude/worktree-links`, and reports every link as `ok`, `created`, `WRONG`, `BLOCKED` or `MISSING-TARGET`. A non-zero exit is a stop-and-report condition. Run it at session start and whenever a link looks wrong.
2. Check that `/.claude/worktrees/` is ignored in the main checkout. If it is not, ask before committing that line to the main branch.
3. **Shared ignored state.** Ignored files do not exist in a new worktree. List every path the work must share with the main checkout (results, caches, tag files) in `.claude/worktree-links`, one path relative to the repository root per line, and commit that file on `claude`. The script links each one to the main checkout's copy. Never copy shared state.
4. **Hard-coded paths.** Search scripts for hard-coded project paths (`$HOME/<project>`, `~/<project>`, absolute paths). Such a script run from the worktree silently uses the main checkout's code. Make scripts resolve their own root with `git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel`, or `__file__` in Python. Commit that fix on `claude`.

## Working on `claude`

- Every Edit, Write and build happens under `.claude/worktrees/claude`. Run commands from there with absolute paths. Never edit tracked files in the main checkout.
- Only the main session commits on `claude` and merges agents' `claude-<task>` branches into it (`delegate-work`). Commit after each logical change, with a message that says why, followed by the session's attribution trailers. The commit log on `claude` is the record of what Claude did. Do not batch a whole session into one commit, and do not leave work uncommitted at the end of a turn that changed files.
- **Commits are unsigned:** always `git commit --no-gpg-sign` on `claude` and `claude-*` branches, even when a GPG key is cached, so a signature from the user's key always means the user vouched for the commit (user's standing choice, 2026-10-14). The user signs before merging (below).
- Never stage ignored data, binaries or credentials. Check `git status --short` before each commit.
- Never use a bare `git stash`, because the stash stack is shared across worktrees. Use a WIP commit instead.
- **When the main branch moves** (the user committed or merged): merge `<main>` into `claude` inside the worktree. Do not rebase, because the user may already have reviewed those commits. Resolve conflicts in favour of the user's changes. If that breaks Claude's work, stop and report (ask/decide/stop tiers in `session-context`).
- Skills, CLAUDE.md and other instruction files edited on `claude` take effect only after the user merges them, because sessions load them from the main checkout. Say so when such an edit matters immediately.

## Handing work to the user

End every turn that changed anything with this report, in this order, leaving out empty sections:

```
Commits        <repo>: <hash> <subject>        (one line each, every repository touched)
Checks         <command> -> exit <code>        (the project's check script, and any other check run)
Outside worktrees  <path>: <what changed>      (memory, scratchpad, anything else edited)
Handoff        <sections changed>
Decisions      <decision> (record in <file> §<n>)
Attention      <category>: <item>              (as recorded in the handoff document)
To sign        git -C <worktree> rebase --rebase-merges --exec 'git commit --amend --no-edit -S' <main>   (user runs; keeps merges of agent branches)
To merge       git -C <main checkout> log --format='%h %G? %s' main..claude && git -C <main checkout> merge claude
```

- Before any merge into the main branch, ask the user to sign the unsigned commits with the To sign line, and check afterwards that `git log --format='%G?' <main>..claude` shows only `G`. Never sign them for the user.
- Tell the user the range to review: `git log --oneline <main>..claude` and `git diff --stat <main>..claude`.
- The user merges, for example with `git merge claude` from the main checkout. Claude may suggest the command but does not run it unless asked in that turn.
- Never push, never force anything, and never delete the `claude` branch or worktree while it has unmerged commits.

## Hooks that enforce this skill

Hooks in `~/.claude/settings.json` enforce this skill (edit allowlist, git write guard, skill gates, Stop check). A block is final for that route: never retry the same action another way. If the user asked for it, report the block and give them the command. Read `references/hooks.md` when a hook blocks unexpectedly, when adding a project hook, or when changing a hook.

## Cleanup

- `git worktree prune` removes records of worktree directories that no longer exist.
- Build outputs inside the worktree (its own `bin/` and similar) can be reclaimed safely. Never `rm -rf` a path in the worktree that is a symlink to shared data with a trailing slash: `rm -rf experiments/results/` deletes the shared target's contents. Remove the link itself with `rm experiments/results`.
