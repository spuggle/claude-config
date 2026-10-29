---
name: experiment-integrity
description: Run and diagnose measurement experiments without corrupting results (benchmarks, load tests, evaluations, attack/mitigation trials). Use before launching or shortening a run, when a result is NA, INCONCLUSIVE, implausible or differs from an earlier run, when a metric or component is missing, and before trusting or reporting a suspect number.
---

# Experiment integrity

A number is only worth reporting if it was measured, from known code, under known conditions, by a procedure that measured what it claims. Everything here protects one of those four.

## Specialisation

A project skill whose description starts "Specialises experiment-integrity" (if the project has one) holds the testbed facts: contexts, namespaces, queries, recovery criteria, window lengths, scenario parameters, and the usual suspects in order. A project with more than one testbed keeps one fact block per testbed. First identify which testbed produced the result; never apply one testbed's criterion to another's result.

## Non-negotiable

- Every reported number comes from an actual measurement. A value that was not collected is written "Not collected". A scenario that cannot be judged reliably is "INCONCLUSIVE".
- Never change a threshold, filter, window or criterion to make a result pass, and never drop observations that look bad.
- Never present a predicted, assumed or provisional value as a reading. Mark provisional values the way the project specifies.
- A single run is a single observation. Report ranges only from repeated, seeded trials, and never rank arms from one trial.

## Provenance

- Launch only from committed code. Each results directory records the commit, branch, worktree, any uncommitted changes (with a diff), and the artifact or image versions. If the project has no recorder, add one before the next run.
- A result without provenance has an unknown code version. Say so rather than guessing from file dates.
- To explain a difference between two runs, compare their commits first (`git diff <a> <b> -- <source paths>`, `git log <a>..<b>`). If the code changed, the comparison is not like for like until that change is ruled out.

## Diagnosing a suspect result

1. **Reproduce the observation, not the run.** Re-run the exact query or measurement against the live system and read the raw output before re-running the whole scenario.
2. **List hypotheses and rank them** by likelihood and cost to check. Check the cheapest high-likelihood one first. Keep the list in the conversation so a refuted hypothesis is not revisited.
3. **Classify the cause:**
   - *Methodology bug*: the procedure measured the wrong thing. Fix the procedure and re-run. Never edit the number.
   - *Real behaviour*: the system genuinely did this. Record it as a finding, with the evidence that makes it defensible.
   - *Infrastructure drift*: the testbed was not in the assumed state. Restore it and re-run.
   - *Code change*: provenance shows different code. Attribute the difference before comparing.
4. **Self-correct.** If a fix does not change the observation as predicted, the hypothesis was wrong. Return to step 2; do not stack a second fix on top.
5. Record the classification and evidence in the handoff document (`instruction-layer`).

## Making runs faster

Allowed:
- Reuse warm state (a running cluster or service, loaded caches) when nothing that affects it changed.
- Skip a rebuild or redeploy when the source diff since the last run's commit is empty for the paths that feed it.
- Run independent scenarios back to back on the same warm setup.
- Stop a recovery poll as soon as its criterion is met.

Forbidden:
- Shortening warm-up, settle, measurement or query windows below what the procedure specifies.
- Running arms or scenarios in parallel when they share a contended resource (a link, CPU, a database). Both results become invalid.
- Changing scenario parameters (load, intensity, concurrency) to finish sooner.
- Launching from uncommitted code to save the commit.

Before speeding up, state which allowed levers apply and why nothing forbidden is touched. Afterwards, record the wall-clock time saved, because the speedup is itself a measured claim.

## Comparing approaches

- Every arm runs the same procedure: same preparation, baseline, load, windows and recovery criterion.
- Systems under test that are not in the current arm are verified off, so they cannot act in another arm.
- Arm order is seeded or recorded. One arm should not always run first.
- A failed precondition marks the trial not comparable and INCONCLUSIVE.
