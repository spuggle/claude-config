---
name: delegate-work
description: Hand work to subagents or a standing worker and pick agent type, model and effort. Use before work with two or more independent parts, a sweep of more than about three files or sources, web research, or output that would flood the context, and when a task pattern keeps repeating.
---

# Delegating work to subagents

Delegate work that is large and does not need what the main session already knows. A subagent starts cold: it re-reads files and re-derives facts the main session holds, and waiting costs nothing but every round it runs does. Keep work inline when describing it costs about as much as doing it.

This applies to the main session only. A subagent does its own task itself and never spawns further agents, even though it also reads the user's CLAUDE.md.

## Delegate or keep inline

Delegate when the task is any of:
- self-contained, with a clear goal and a checkable result;
- parallelizable with other work in flight;
- read-heavy, where the tool output would otherwise flood the main context;
- a match for a standing agent that already exists;
- an independent check of the main session's own work (review), where a fresh context is the point.

Keep inline when:
- it is a small read, edit or lookup (a few files, one to three web fetches), or anything faster to do than to describe;
- it needs the conversation's context: the user's preferences, decisions taken this session, facts already verified (write skills and summaries of this session inline);
- it is the final judgment on correctness or validity, or writing a measured or verified result into a deliverable;
- it could weaken a rule the repository's CLAUDE.md marks as non-negotiable.

Repository rules about what must not be delegated take precedence over this skill.

## Before dispatching

Check that the agent can finish, so it does not spend a round and stop at a wall: the hosts and files it needs are reachable, the tools it needs are allowed, and the final step does not need the user (a passphrase, sudo, a permission the user granted only to the main session). An agent cannot inherit permissions the user gave in conversation.

## Agent type

- `Explore`: read-only fan-out search across many files or naming conventions, when only the conclusion is needed. Pass `model: "haiku"` unless the search needs interpretation.
- `advisor`: an Opus second opinion that picks among options already drafted (triggers below). Never use a fork for this: a fork runs on the main session's model and carries the whole transcript.
- `Plan`: draft an implementation plan or lay out architecture options, read-only.
- `general-purpose`: multi-step work that edits files or runs commands.
- `fork`: the task needs everything the main session currently knows. A fork inherits the full context and always runs on the main session's model and effort; model and effort overrides are ignored.
- A standing custom agent from `.claude/agents/` when one fits the task.

## Model by complexity

The main session runs on `opusplan` (`~/.claude/settings.json`): Opus in plan mode, Sonnet otherwise. Make a plan with three or more stated constraints, or one that is hard to reverse, in plan mode (`EnterPlanMode`). Outside plan mode, judgment the main session would otherwise make alone goes to `advisor`:
- before locking such a plan;
- before writing or changing a standing rule (skill, CLAUDE.md, hook);
- on a check's second failure, identical or not (`session-context`, Stop and report).
Edits to core workflow files are gated on an advisor call (`agent:advisor`; paths in the hooks reference of `claude-worktree`). Brief it with the question, the options, the constraints, `git diff` or excerpts, and the decision record; never the transcript. Keep the brief under about 10k tokens.

- haiku: mechanical, read-only, or checklist work. Lookups, state listing, metric collection, grep sweeps, pre-flight and post-flight checks.
- sonnet: structured moderate work. Generating figures, tables, or documents from known data, drafting scripts, routine debugging with a known symptom.
- opus: judgment. Root-cause classification, validity calls, design under several constraints, reconciling contradictory results.

## Effort by need

- low: one step, no interpretation. A single lookup, one value, a file existence check.
- medium: the default. Several steps or some interpretation.
- high: judgment work only. Subtle correctness, validity, multi-constraint design, contradictory evidence.

Use the lowest effort that does the task reliably. If a result comes back thin or ambiguous, re-run one level higher rather than trusting it.

## Writing the prompt

A fresh agent starts cold. The prompt carries everything it needs:
- the goal and why it matters;
- exact paths, names, commands, and values already known, so it does not re-derive them;
- the constraints it must respect, including repository rules;
- what it must not do;
- the exact shape of the result to return, short enough to read in one pass, including the stable facts it had to discover and the command that showed each, so the main session can record them (`instruction-layer`, Recording explored facts).

A fork already has the context; give it a short directive instead.

## Agents that edit files

When the project uses a `claude` worktree (see the `claude-worktree` skill), agents follow the same rule as the main session: no edits in the user's checkout.
- Who commits: every editing agent works in its own worktree on its own branch, created by the main session from `claude`: `git worktree add -b claude-<task> .claude/worktrees/claude-<task> claude`. The agent does not commit: for each logical change it stages nothing, writes `<scratchpad>/<task>-<n>.patch` (`git diff`) and a commit message file with the session's attribution trailers, and reports them. The main session reviews each patch and commits it unsigned on the agent's branch (`git apply --cached` then `git commit --no-gpg-sign -F`), then merges into `claude` and removes the agent's worktree and branch.
- Review before merging: for every agent branch that changes code, scripts or instruction files, dispatch a read-only reviewer on `git diff claude...claude-<task>` with the stated intended difference (`change-safety`). Use `skill-reviewer` for skills, CLAUDE.md and hooks, and a `general-purpose` reviewer on opus for code. The implementer fixes what the reviewer finds; after two fix rounds that still fail review, run the next round one model tier higher. Merge only when the reviewer reports no blocking issue, and never run two implementers on the same files at once.
- Do not use the Agent tool's `isolation: "worktree"` option for this: it branches from the user's checkout, not from `claude`.
- Read-only agents need no worktree, but must read the `claude` copy of any file that differs from `main`.
- Verify an editing agent's work by its patch and by running the tests yourself, not by its report.

## Running agents

- Prefer continuing an agent with a message over spawning a new one: it keeps what it has read.
- Scope a re-review to the previous findings and the new commits, with a word limit, rather than a full second review.
- Use the lowest model that is reliable for the task; reserve opus for code and correctness review and multi-constraint design.


- Launch independent agents in the same turn so they run in parallel.
- Do not run agents in parallel when they contend for a shared resource whose contention would change the result.
- Never state or predict a result that has not arrived. If asked before an agent finishes, say it is still running.

## Workers per area

Small tasks that recur in one area over a session (the global skills repository, the chezmoi source, one project, one remote host) go to a standing `area-worker` for that area instead of a fresh agent each time, so the area's files are read once. A resumed agent re-sends its whole transcript each turn (cheap while the prompt cache is warm, about an hour), so a worker pays off only while its history stays relevant.
- **Create** one on the second small task in the same area in a session, or on the first if more are clearly coming: brief it with the area's root, its rules (worktree or in place, style rules), its check command, the scratchpad path and the attribution trailers. In a repository with a `claude` worktree, first create its own `claude-<area>` worktree from `claude` (Agents that edit files) and name that in the brief. Use haiku for purely mechanical areas; the default is sonnet. Record each worker in `<scratchpad>/workers.txt` (area, agent id, worktree, start time from `date`, patches not yet committed), so it survives compaction.
- **Use** it by message, not by spawning: batch the tasks that are ready into one message, and keep tasks needing this conversation's context, one-to-three-command tasks, and judgment calls inline.
- **Retire** it, and brief a successor with a short summary if work remains, when the `subagent_tokens` figure in its latest completion notification (cumulative over its rounds) passes about 70k, after an hour idle, when the area or the needed model changes, when it reports that its context no longer fits, or when `workers.txt` is missing after compaction.
- One worker per area at a time; never two editing the same files. Independent areas may have workers running in parallel. Reviews still go to fresh agents (`skill-reviewer` or a `general-purpose` reviewer), never to the worker whose output they check.
- After each batch: review each patch, then
  - in a repository with a `claude` worktree, commit it unsigned on `claude-<area>`, have a fresh reviewer check code or instruction changes, merge into `claude`, and keep the worktree; remove the worktree and branch only when the worker is retired;
  - in a `claude.worktree=false` repository (the chezmoi source), stage the change and do not commit; the user reviews and commits;
  - outside git, check the changed paths it lists.
  Then clear the batch's entries in `workers.txt`.

## Verifying results

An agent's report is an input, not an authority. Before acting on it:
- check any fact it reports that a decision depends on, against the source;
- re-derive any number that will be shown to the user or written into a deliverable;
- treat a vague or incomplete report as a reason to re-run with a sharper prompt or higher effort.

## Creating a standing agent

Create one in `.claude/agents/<name>.md` when the same task with the same scope keeps recurring. Project agents go in the repository's `.claude/agents/` and are committed on `claude`. Agents useful across projects are committed in the global skills repository under `agents/<name>.md`, and `~/.claude/agents/<name>.md` is a symlink to `~/.claude/skills/agents/<name>.md`, so they are versioned and go live when the user merges. Existing global standing agents: `skill-reviewer`, `area-worker` and `advisor`; a project lists its own in its `.claude/agents/`. Use a standing agent instead of writing a fresh prompt for the same task.

Frontmatter fields: `name`, `description`, `tools`, `model`, and `effort`. Keep `tools` to the minimum the task needs, write the description so it states when the agent should be used, and put the agent's standing instructions in the body. Do not create an agent for a one-off task.
