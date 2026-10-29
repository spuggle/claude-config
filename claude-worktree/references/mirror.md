# Setting up a mirror machine (Windows or other)

A mirror holds the global skills read-only; the skills are managed only on the desktop (`skills-repo.md`). Nothing here needs chezmoi.

## Requirements

Native Windows runs the hooks in Git Bash. Install, all on PATH:
- Git for Windows (provides bash, grep, sed, awk, realpath, cygpath);
- `jq` (`winget install jqlang.jq`);
- Python 3 (`winget install Python.Python.3.12`); the hooks try `python3`, `python`, then `py`;
- `git config --global core.autocrlf false`, so shell scripts keep LF endings (`.gitattributes` also forces them).

Without `jq`, the guards block every edit and command with a message naming it, rather than failing open. Without Python the git-write guard blocks git writes outside a claude worktree, and the kb hot sheet is not printed.

## Steps

1. `git clone git@github.com:<owner>/claude-config.git ~/.claude/skills` (the GitHub remote, private; use whatever SSH or HTTPS credentials the PC has).
2. `echo managing-host > ~/.claude/skills/.git/mirror-of`. The hooks then block edits and git writes there.
3. Merge the `hooks` object of `claude-worktree/references/settings-hooks.json` into `~/.claude/settings.json`. Hooks are skipped silently if a script is missing, so check step 5.
4. Copy the desktop's `~/.claude/CLAUDE.md` to `~/.claude/CLAUDE.md`. Its host-specific rules (remote-host, chezmoi) can be removed.
5. Start `claude` in `~`. The session-start report should list the repository as a read-only mirror, with no `MISSING:` line.

## Updating

The desktop's `publish-skills.sh` pushes over SSH, which needs an SSH server on the PC. Instead pull: `git -C ~/.claude/skills pull --ff-only` after the user merges on the desktop and pushes `main` to GitHub.

## Differences from the desktop

- Gates for skills not installed here (for example private-layer skills) are skipped. Delete those skill folders on the mirror if they are of no use; `host-hygiene` and `linux-diagnosis` describe Linux and the desktop.
- Paths from Claude Code arrive as `C:\Users\...`; the guards convert them with `hook_norm_path` (`lib.sh`).
- Agent symlinks (`~/.claude/agents/*.md`) need Windows developer mode; copy the files from `agents/` instead.
- Host facts (`kb ls host/...`) are per host; add the PC's own with `kb add` only on the desktop (the managing machine).
- Windows behaviour is untested by the suite, which runs on Linux. Run `bash scripts/check.sh` on the PC once.
