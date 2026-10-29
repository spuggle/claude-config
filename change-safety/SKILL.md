---
name: change-safety
description: Change code without silently changing behaviour, in any project. Use before refactoring, before fixing a bug in code that has callers, before changing anything that produced published or measured results, and when writing tests for new logic.
---

# Change safety

A change is safe when every behaviour it alters was meant to be altered, and that is shown by a test or a measurement, not by reading the diff.

## Specialisation

A project skill whose description starts "Specialises change-safety" (if the project has one) gives the test commands, the integration environment, the generated-code steps, and the style rules that override general habits (for example, a no-comments rule). Invoke it alongside this one. Without one, this skill applies on its own.

## Before changing behaviour

1. **Pin down current behaviour.** If the code to change has no test covering the path, write a characterization test that asserts what it does now, including odd outputs. Run it green on the unchanged code.
2. **State the intended difference** in one sentence: which inputs should now produce which different outputs.
3. Make the change. The characterization tests should fail exactly where the intended difference says, and nowhere else. Update those assertions deliberately and leave the rest alone.

## Adversarial test discovery

For new or changed logic, ask: which inputs would break this but still pass the tests I have? Write tests for the plausible ones. Typical candidates:
- empty, absent and zero, and absent versus zero where a query or API distinguishes them;
- boundaries at and beside each threshold, and the inclusive or exclusive end of a range;
- units and scaling (bits versus bytes, seconds versus milliseconds, a fraction versus a percentage);
- duplicated inputs (double counting, double scraping), stale caches, and ordering;
- partial failure in multi-step or multi-component operations, and the path where the revert runs.

## Fixing a bug

1. **Reproduce it as a test first.** Write a test that fails for the bug's reason, run it, and see it fail. A test that passes before the fix proves nothing.
2. **Find the root cause before changing code.** Trace from the symptom back to its cause; check one hypothesis at a time, cheapest first. Do not stack a second fix on a first one that did not work.
3. **Fix the cause**, see the test pass, then run the project's check script.
4. **Two failed fixes means stop fixing.** Consult `advisor` with both attempts and their outputs (`delegate-work`); if the next step it suggests also fails, stop and report what was tried and what each attempt showed (ask/decide/stop tiers in `session-context`). The problem is probably the design, not the last line changed.

## Receiving a review

- Read every item before acting on any. If any item is unclear, ask about all unclear items first; partial understanding produces wrong fixes.
- Check each item against the code before accepting it. A reviewer, human or agent, can be wrong; if an item is wrong, say so with the evidence.
- Do not agree performatively. State what will change and why, or why not.
- Apply items one at a time, running the tests after each.

## Changes that touch results

- If code that produced reported numbers changes, record which earlier results it may invalidate (`instruction-layer` decision record), and re-measure before citing them again.
- A fix to measurement code is a methodology change. Earlier and later results are not comparable until the earlier ones are re-run (`experiment-integrity`).

## Before calling a change done

- Run the project's check script (named in the specialisation). Without one, run the command that validates what changed: `bash -n`/`fish -n` for shell, `python3 -m py_compile`, `jq empty` for JSON, `chezmoi diff`/`chezmoi apply --dry-run` for dotfiles, `scripts/check.sh` for the global skills repository. The change is done only when it exits 0; report the command and exit code.
- Any claim that something passes, works or is fixed needs the command that showed it, run in the same turn, and its output or exit code. An earlier run, an agent's report, or "should work" is not evidence.
- Exercise the change for real where the project allows it, not only in tests.
- Review the diff for drive-by edits outside the stated intent.
- Commit with a message that states the intended behavioural difference.
