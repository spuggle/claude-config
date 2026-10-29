---
name: instruction-layer
description: Maintain CLAUDE.md, memory, skills, host facts, handoffs, open items and decision records. Use on a MISSING: line, when adding or changing a rule or skill, when a correction recurs or instructions look stale or contradictory, after a run, new result or user request, when telling the user something to act on, after exploring system state, when a Stop hook reports unrecorded commits, explored facts or a `reflect:` line, and when the user asks to see the handoff or backlog.
---

# The instruction layer

Each persistent fact has exactly one home; the wrong one makes it stale, invisible, or contradictory.

## Specialisation

A project skill whose description starts "Specialises instruction-layer" gives the project's file names, its handoff layout, and any rule that must stay verbatim. Invoke it alongside this one; without one, this skill applies on its own.

## Where a fact goes

| Store | Holds | Changes |
|---|---|---|
| `CLAUDE.md` (project, checked in) | Non-negotiable rules and the fixed environment | Rarely |
| `~/.claude/CLAUDE.md` | Standing preferences for every project | Rarely |
| Auto-memory (one file per fact, indexed in `MEMORY.md`) | Who the user is, their corrections and confirmed approaches, goals, external pointers. | When learned |
| Handoff/state document | Live state, results and their validity, open problems; decisions and pitfalls only in a project without `kb` | Every session |
| `kb` store (`docs/kb/*.json`) | Open items, decisions, pitfalls, machine and game facts with probes, files Claude or the user wrote; read and changed only through `scripts/kb` | When found |
| Skills | How to do a recurring kind of work | When the method changes |
| Skill references (a project skill's `references/`) | Stable project facts, each with a probe (below) | When found |
| Git history (`claude` branch) | What changed, when, and why | Every commit |

- Process conventions go in skills, not new CLAUDE.md rules, unless the user says otherwise (user's preference, 2026-10-13); CLAUDE.md holds specification rules and the environment.
- Memory is keyed to the directory a session starts in. A preference or fact for more than one project goes in a global skill (or the ask-first `~/.claude/CLAUDE.md`), not in project memory, which holds only project facts that no skill, CLAUDE.md or repository file records.
- The home memory (`~/.claude/projects/<home key>/memory/`, loaded for sessions started in `~`) holds the user profile (who the user is, standing preferences; user's choice, 2026-10-26) plus `kb` pointer lines for machine and setup facts. A cross-project preference is written in the relevant skill first; the home memory gets a one-line summary and that skill's path. When it changes, change the skill, then the summary.
- On the managing desktop `managing-host`, three stores must always exist (user's requirement, 2026-10-26): the global handoff `~/.claude/skills/docs/HANDOFF.md`, the skills repository's `claude` worktree, and a non-empty home `MEMORY.md`. A `MISSING:` line in the SessionStart report means restoring that store in the same session; a skills mirror has none and prints none.
- Do not record what the repository captures (code, fixes, git history).
- Structure data that a script reads as JSON with a validator; keep prose for what Claude reasons over. Anything loaded at every session start is a one-line-per-item index, detail on demand; no filtering may hide an open item that needs the user.
- Scripts that interpret shell commands parse them with `shfmt --to-json`, not hand-written regexes or tokenizers.

## Find and record facts with `kb`

Read and write each store through its tool, never `grep`, `sed`, `cat`, `jq`, `Read` or `Grep` on the file (the Bash hook blocks `docs/kb/` and `docs/state.json`). `references/stores.md` has the tool of each store and the `kb` commands; if the tool lacks a command, add it to the tool in the same change.
- **Find:** the hot sheet (printed at session start) first; else `kb ask WORDS` (one call; `--body` for detail; `AMBIGUOUS:` lists candidates; read a `warnings:` line); then `kb ls <path>` (copy each segment), `kb find WORDS`, `kb search REGEX`. Say "not recorded" only after `kb ask`, `kb find` and `kb search` all exit 1; never invent it. Do this before stating a setup fact.
- **Record:** `kb add PATH --type T --title ...` fills id and date and lists near-duplicates; if the fact exists, `kb set` it (fix, do not duplicate). `kb add --help` lists types and fields.
- **Where:** `references/stores.md` (Recording) lists the path of each kind; decisions are frozen (supersede, do not edit). One entry has one home path; `kb ref` lists it under another topic, `kb link` relates two entries.

## Recording explored facts

When a task needed a fact that no store held and Claude found it by reading system or project state (commands such as `lsblk`, `systemctl`, `sysctl`; files under `/etc`, `/sys`, `/usr/lib`; a service or cluster query), record it before the turn ends. The Stop hook (`explored-facts.py`) blocks once when the turn (or a subagent) read system state and no fact store changed: record the facts, or confirm none needs recording.
- **What:** stable facts the task depended on and a similar task would need again: device identities and mounts, which unit, file or package sets a value, distribution defaults and quirks. Not live values (usage, free space, load), nor what the repository or git history shows, nor one-off output.
- **Where:** machine and game facts in `kb`; project facts in the project's specialising skill references (create one after asking); preferences per "Where a fact goes".
- **Probe:** every fact ends with a read-only probe that exits 0 while it holds and prints the value it found (`--probe '<command>'`, or `--probe-none '<reason>'` for policy, procedure or a measured rate). `kb add` refuses a probe outside the allowlist; `references/stores.md` has the rules and how to extend them. Name devices by UUID, label or by-id path, never by kernel name.
- **Check:** `kb probe <path>` (`--ssh <host>` for another machine) must pass; to see it can fail, change its expected value once and confirm `FAIL`.
- **Enforced:** `kb validate` runs in `scripts/check.sh`. SessionStart lists this host's failing probes; fix the fact or probe in that session.

## Reflect at the end

After a turn that looked things up, ask: which retrieved info was irrelevant; what context would be needed again for this scenario (not only exact facts); how many steps it took (tool calls from the first lookup to the call that returned the info finally used). The Stop hook prints `reflect:` with the count after many lookups, or a kb miss then hit, and no kb write.
- Irrelevant info or many steps: `kb add <topic>/warnings/<id> --type warning` (scenario, kind, steps, optional noise, shortcut).
- Context for a scenario: `kb add <path> --type context` under the topic it concerns (scenario = when it applies; body = the context).
- A stable checkable value: a `fact` with a probe. Otherwise confirm none is needed.

## Writing a rule

- Specific and actionable: name the file, flag, command or number. Verify every reference against the current tree before writing it; recalled memory reflects the past.
- Tier by force: non-negotiable, strong convention, preference. Never weaken or remove a non-negotiable rule to make a result pass; surface it to the user.
- One fact per memory file, with name, one-line description and type; feedback and project entries add **Why:** and **How to apply:**. Link related memories with `[[name]]`.

## Pruning

- Remove a rule once code prevents violating it or a newer decision contradicts it.
- Resolve conflicting rules by the tiers in `session-context`: asked if a non-negotiable rule is involved; otherwise decided, recorded, the loser deleted.
- After adding, renaming or deleting a skill, remove every reference to the old name. A skill changed on a `claude` branch is live only after the user merges.
- Delete a wrong memory.

## Writing a skill

- **Description = when, not how.** Name the triggers: situations, symptoms, file paths, commands, and the user's words. Never summarise the steps: a description that outlines the workflow gets followed instead of the body. No first or second person; the key trigger first; under about 600 characters (hard cap 1,536 with `when_to_use`).
- **Body under about 150 lines and 2k tokens.** Move material needed only sometimes to `references/<topic>.md`, linked with one line saying when to read it. References stay one level deep; one over 100 lines gets a contents list. No `@path` links (they force-load the file).
- **Facts that differ per machine or project** go in `kb` (`host/<hostname>`) or a project skill, not in a global body.
- Deterministic or fragile steps ship as a `scripts/` script the skill runs; judgement stays in prose.
- Names are lowercase-hyphen nouns (`change-safety`); frontmatter is `name` and `description` only unless a documented field (`paths`, `disable-model-invocation`) is needed.
- Cross-reference skills by name in backticks.

## Skill gates

A skill tied to a concrete action (editing certain paths, a kind of command) gets a gate line, which the skill gate hook enforces: in `~/.claude/skills/claude-worktree/skill-gates` for global skills, or the project's `.claude/skill-gates` for project skills. A skill tied to a judgement rather than an action gets no gate; its description's triggers carry it. When adding, renaming or removing a skill, update its gate lines in the same commit. Review `~/.claude/skill-usage.jsonl` with `skill-reviewer` now and then: gates that block unrelated work are too broad; skills that never appear need a gate or sharper trigger. A gate line may require `agent:advisor`: core-workflow edits carry it (hooks reference of `claude-worktree`).

## Testing a skill change

Before asking the user to merge a skill change, run `~/.claude/skills-worktrees/claude/scripts/check.sh` (authoring rules, kb, hook tests) and fix what it reports; then test the behaviour: run the scenario it is meant to change with a subagent without the skill and then with it (or ask `skill-reviewer`), and confirm that only the intended behaviour changes. Record the scenario and result in the commit message. A skill with a non-obvious trigger keeps `evals/triggers.json`: realistic multi-step `{"query": ..., "should_trigger": ...}` pairs, at least three each way, with near-misses from a neighbouring skill (`anthropic-skills:skill-creator` can run and tune them).

## Handoff, plans and decisions

In a project with a handoff document, read `references/handoff.md` and keep it current in the same turn as: a finished run or regenerated report, a request or backlog change, a fact that differs from the document, a new pitfall, something told to the user, a decision, or work of three or more steps that needs a plan. Outside a project (session in `~` or not in a repository) and for work on the setup itself (global skills, hooks, agents, memory, Claude settings), the handoff document is the global one, `~/.claude/skills/docs/HANDOFF.md`, edited in the skills worktree; its items, decisions and pitfalls are `kb` entries. A project without one keeps plans in the conversation, decisions in commit messages.

When the user asks to show or review the handoff, do it interactively in the conversation, not as an artifact or document, unless they ask for one (`AskUserQuestion`, answers written back in the same turn; `references/handoff.md`).

## Procedure

1. State which store the change belongs in and why.
2. If it touches a non-negotiable rule, stop and raise it.
3. Verify every file, flag and field the new text names.
4. Write the smallest specific form; for memory, update the `MEMORY.md` pointer.
5. Commit on `claude` if the store is tracked, and report what changed and where.
