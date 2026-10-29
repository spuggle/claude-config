# claude-config

Generic Claude Code setup: skills, agents, hooks and a small knowledge-base tool (`scripts/kb`).

## Install

    git clone <this repo> ~/.claude/skills
    cp ~/.claude/skills/settings.json.example ~/.claude/settings.json   # hook wiring; edit plugins
    cp ~/.claude/skills/CLAUDE.md.example ~/.claude/CLAUDE.md
    git -C ~/.claude/skills config core.hooksPath .githooks

The hooks in `settings.json` expect the checkout at `~/.claude/skills`.

## Private layer

Machine facts, handoffs and personal skills do not belong here. Keep them in a private repository
and point `KB_DIR` at its knowledge-base directory; skills installed from it can sit next to these in
`~/.claude/skills/`, and its gates can be added to a project's `.claude/skill-gates`.
`.githooks/pre-push` blocks pushes containing private addresses, UUIDs, keys or your own denylist
(`~/.config/claude-config/denylist`, one regex per line).

## Check

    scripts/check.sh
