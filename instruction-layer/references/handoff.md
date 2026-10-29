# Handoff document, plans, attention items and decision records

For projects that keep a handoff/state document. The project's specialisation names its path (the hooks default to `docs/HANDOFF.md`). The global handoff, for sessions outside a project and for setup work, is the skills repository's own `docs/HANDOFF.md` and follows the same layout; its §1 also carries a skills, agents and hooks status table, and its items, decisions and pitfalls are `kb` entries (`setup/items`, `setup/decisions`, `setup/pitfalls`).

## Contents
- Showing and reviewing the handoff with the user
- Open items (`kb`, or a project's `docs/state.json`)
- Keeping the handoff document current
- Items for the user's attention
- Plans for multi-step work
- Decision records

## Open items (`kb`, or a project's `docs/state.json`)

In the global store (`docs/kb/`; the script's lookup follows its own repo, or its sibling `claude` worktree, see `stores.md`), open items are `kb` entries under `setup/items`: attention items as kind `user-action` or `waiting`, the backlog as kind `backlog` with a priority. SessionStart prints `kb ls` and `kb render --open` (one line per user item, a backlog count), so the handoff's §0 is a pointer and its prose sections are read on demand. The skills repository itself has no `docs/state.json` (deleted when `kb` became the only store); a project that keeps its own `docs/state.json` uses `state.sh` the same way.
- Read and change them only through `~/.claude/skills/scripts/kb` (`add setup/items/<id> --type item --kind ...`, `set <id>`, `close <id>`, `get <id>`, `ls setup/items`, `search <regex>`; commands in `stores.md`) or, for a project's `state.json`, `state.sh -f <file>`; never with `cat`, `grep`, `sed`, `jq` or by hand (the Bash hook blocks it). `kb validate` runs in `check.sh`.
- One record per item; never merge two items into one. The title (100 characters at most) names the action; `body` holds the files, commands and context. Split steps, facts and measurements that a later lookup needs into linked `kb` entries instead of free text.
- Close an item in the same turn it is resolved; a closed item stops loading.
- Wherever this reference says "attention list" or "backlog", it means these records when the store exists.

## Keeping the handoff document current

Update it in the same turn as any of these events, without being asked:
- A run, sweep or campaign finishes: record the results location, the script, the commit, seeds and trial count, and its validity status.
- A report or table is regenerated: record which results feed it.
- The user or a stakeholder makes a request or adds backlog work: record it with its source, and add it to the backlog in priority order.
- A backlog item is finished or partly done: close it, or `set` its detail, naming the file that proves it.
- A live fact differs from what the document says: correct it.
- A new pitfall costs time: add it.
- When the Stop hook reports claude commits made since the handoff document last changed: record what they change, or confirm none needs recording, before ending the turn.

Format:
- A dated "State as of YYYY-MM-DD" summary at the top. Replace it each time rather than stacking dated sections.
- One prioritised backlog, edited in place.
- Every number cites its source file. Inferred statements are marked as inferred. Use absolute dates. Cite the commit when an entry depends on a code change.

## Items for the user's attention

Anything told to the user as something they should know goes into a "For the user's attention" list in the summary, in the same turn. Remove an item only once it is resolved. Describe a secret's location, never its value. Every item names the file that shows it. Categories:
- Security
- Work at risk
- Host resources
- Errors in deliverables
- Validity caveats
- Code defects found, not yet fixed
- Decisions waiting on the user (only choices in the ask-first tier of `session-context`)
- Needs the user to act

## Plans for multi-step work

Work with three or more steps, or work that will span sessions, gets a plan file before the first change, in the location the specialisation names, linked from its backlog item. A plan contains:
- the goal and the intended differences (`change-safety`);
- questions that must be answered first, answered from the code and documents where possible; only questions in the ask-first tier go to the user;
- numbered steps, each with the files touched, the exact commands, the check that shows the step worked, and the commit message;
- a status per step, updated as each step is committed.
Execute the plan step by step; a step that fails its check twice goes to `advisor` (`delegate-work`); if it still fails after that, the plan stops (ask/decide/stop tiers).

## Decision records

When a design or methodology decision is made (a testbed redesign, a changed criterion, an option chosen over another), add a short record (a `decision` entry under `setup/decisions` in the global store, otherwise the handoff document's decision section): date, decision, alternatives considered, the evidence or reason, and what it invalidates. Results produced before a decision that invalidates them are marked as such where they are cited.

## Showing and reviewing the handoff with the user

A request to show, review or go through the handoff (or its state, backlog, attention list or decisions) is answered in the conversation, not with an artifact, page or document, unless the user asks for one.
1. Read the document (worktree copy) and give a short summary: the "State as of" date, what changed since the user last reviewed it (`git log` on the document), and counts of attention items, open decisions and backlog entries.
2. Walk the items that need the user, most urgent first, with `AskUserQuestion`: up to four questions per call, each with concrete options and a recommendation marked first. Attention items ask resolve / keep / act now; decisions ask which option; backlog asks reorder, drop or start.
3. Items that need no input are listed in one line each, not asked.
4. Write every answer back into the document in the same turn (resolved items closed, decisions recorded with the date, backlog reordered with `kb set <id> --field priority=N` where `kb` or `state.json` exists), commit it on `claude`, and finish with the remaining open items.
