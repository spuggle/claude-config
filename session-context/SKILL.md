---
name: session-context
description: Keep a session accurate and lean, and decide when to ask the user versus act. Use on the first turn of every session, around detached long-running jobs, when switching tasks, before reading a file over 500 lines or a result file, when a choice might need the user, and when a Stop or PreCompact hook reports unfinished work.
---

# Session context

Correctness first, then cost. A cheap session that acts on a stale fact is wrong; an accurate one that reads everything whole runs out of context before the work is done.

## Specialisation

Projects may add their own facts in a project skill whose description starts "Specialises session-context": which files are never read whole, which state drifts, and the preferred query path. The SessionStart hook prints the map of global skill to specialisation; invoke both. Where the two conflict, the project skill wins on facts and this skill wins on method.

Skill files on disk are picked up during a session; one edited on a `claude` branch is not live until the user merges it.

## At session start

This skill owns the session-start order; other skills only add steps to it.
1. Read the SessionStart hook report. It shows git state of the `claude` worktree (`git status`, `main..claude`, `claude..main`), the handoff summary, and the skill specialisation map. If it is missing, run those commands yourself.
2. If `claude..main` is not empty, merge `main` into `claude` (`claude-worktree`) before editing.
3. Read the project's handoff document (worktree copy), its CLAUDE.md and the recalled memory. Outside a project (cwd `~` or not a repository), the hook prints the global `kb ls` topics and open items (one line each) instead; read the rest only when the task touches the setup. A `MISSING:` line in the report is restored in this session (`instruction-layer`).
4. Verify, do not trust. Handoff notes and memory describe what was true when written. Before building on a live fact (cluster state, running processes, file contents, service status), confirm it with a direct read or query; for a fact recorded with a probe, run `kb probe <path>` (`instruction-layer`) instead of exploring again. When it differs, fix the record in the same turn. A probe failure in the SessionStart report is such a difference.
5. Before stating a fact about the user's setup (launch options, settings, hardware, past decisions), look it up in `kb` (`instruction-layer`: mention, `kb ls <word>`, drill down, `kb get`; `kb find` or `kb search` otherwise), then the handoff headings, then the live config file the fact names. Say "not recorded" only after `kb ls <word>`, `kb find` and `kb search` all exit 1; never invent it.
6. Run the project's pre-flight check, if it has one, before the first operation that touches shared state.

## Ask, decide, or stop

Every choice falls in exactly one tier; this table overrides softer wording elsewhere.

| Tier | Applies to | Action |
|---|---|---|
| **Ask first** | writes to `main` or any user branch; deleting or moving the user's files; changing a rule the project marks non-negotiable; anything involving secrets; anything needing sudo (the Bash hook blocks sudo-like commands: give the user the `!` command) | Ask with `AskUserQuestion` (options plus a recommendation), and wait. |
| **Decide, record, proceed** | architecture, ordering, methodology, tooling and other reversible choices | Choose, record it with `kb add setup/decisions/<id> --type decision` (pitfalls: `setup/pitfalls`; `instruction-layer`), proceed, and mention it in the end-of-turn report. |
| **Stop and report** | a failed precondition; a check that still fails after the `advisor` consult on its second failure, identical or not (`delegate-work`); disk still short after the safe reclaim (`host-hygiene`); a hook block that the user has not explicitly overridden | Stop the affected work, report what failed with its output, and record it for the user's attention (`kb add setup/items/<id> --type item --kind user-action` where the store exists, otherwise the handoff's attention list). |

A skill gate block: invoke the named skills with the Skill tool, then retry the same action. Never work around any other hook block by another route. If it blocks something the user explicitly asked for this turn, report the block and the exact command for the user to run.

## Compact versus clear

Claude gets no turn before `/compact` or `/clear`, so this is advice plus a standing state:
- Recommend `/compact` when continuing the same thread, and `/clear` when switching to an unrelated task.
- At the end of every turn everything that must survive is in the handoff document (the global one outside a project), a memory file, or a commit. Outside a project the Stop hook checks only the skills worktree and its handoff, and everywhere whether a turn that read system state recorded a fact; memory and the conversation's decisions are on Claude. The Stop hook blocks the end of a turn with uncommitted work; the PreCompact hook warns about it.

## Keep large artifacts out of context

- Never read session transcripts end to end. Search them for the specific string.
- Read large source or generator files by line range or by searching for the function in question.
- Query structured results (JSON, CSV) for the keys needed with `jq` or Python, not a dump.
- Read only the pages of a PDF that matter.
- Read a result once and record its numbers.
- Use `git diff`, `git log --stat` and `git show` to see what changed, not whole-file re-reads.
- Hand read-heavy sweeps to a subagent that returns only the conclusion (`delegate-work`).

## Query economy

- Prefer one targeted query over a broad dump.
- Batch independent commands and queries into one turn.
- Reuse a value fetched this turn.

## Around a detached long-running job

1. Before launching: commit the code it runs, and record in the handoff document what is running, from which commit, and the expected outputs.
2. Launch it detached (tmux or `systemd-run --user`) so a dropped connection does not kill it.
3. Hold no live watch. Re-check at a cadence matched to how fast the state changes; a harness notification beats polling.
4. When it finishes, read only the result keys needed to judge it, record the numbers and any decision, and restore the baseline state.

## When the session drifts

- If a recommendation starts conflicting with a standing rule, re-read the rule rather than pushing on.
- If the same correction comes up twice, record it (`instruction-layer`).
