---
name: sdd-implement
description: "Implement a feature by executing tasks from the specification."
argument-hint: "<FeatureName>"
disable-model-invocation: true
---

# /sdd-implement <FeatureName>

Safe to re-run: `[x]` is the only mark that takes a task out of the work, so a blocked task is retried with fresh attempts.

## Context

- **Reads:**
  - `.sdd/protocols/orchestration.md`
  - the output of `.sdd/scripts/gate.sh implement`
  - the prompts `.sdd/scripts/spawn-prompt.sh` renders
  - never the spec files — those are the roles' to read
- **Writes:** nothing — the code, the tests, and the task marks in `_docs/<FeatureName>/tasks.md` are the roles'

## Process

1. **Gate:** run `.sdd/scripts/gate.sh implement <FeatureName>`.
   - `ask` starts only on an explicit yes to each line. An unreviewed spec accepted this way is named again in the final report, in those words.
   - An `ask` about the build command is the exception: no yes answers it, only the line landing in `.sdd/sdd.conf`. Nothing is built or spawned until it is there.
   - `done` means every task is `[x]`.

2. **Baseline build:**

   | `BASELINE` | What to run |
   |---|---|
   | set | `BASELINE` |
   | empty | `BUILD_BACKEND`, then `BUILD_FRONTEND` |

   | Result | What happens |
   |---|---|
   | green | start |
   | red | stop, report the failing output, and proceed only on the human's explicit go-ahead |

   A bootstrap first task has no baseline to establish: say so and start with it — the baseline is the build it produces.

3. **Spawn** the `SPAWN:` records in the order printed, **once each** for the whole feature, never once per task: per record, run `.sdd/scripts/spawn-prompt.sh implement <FeatureName> <scope>`. Render each prompt at the moment its role is spawned, not all of them up front — the frontend prompt rendered after the backend role returned is the one carrying what came back blocked.
   - **The orchestrator never writes into `tasks.md`.**
   - Tasks a role reports `blocked` do not stop the run: relay the Blocker Report unabridged, and let the remaining tasks that do not build on them proceed. The human decides what happens to the blocked ones.

4. **Verify:**
   - When a role returns, run `.sdd/scripts/gate.sh implement <FeatureName> --verify --scope=<the scope of that role>`.
   - When every role has returned, run the build of step 2 again. Green — the feature is implemented. Red — the failure belongs to a `BLOCKED` task whose role has already spent its attempts; do not restart that loop, and report the red build with the Blocker Report.

5. **Report the next step:** re-run `.sdd/scripts/gate.sh implement <FeatureName>` for `TASKS_DONE`/`TASKS_TOTAL` and any new `ANOMALIES:`, then the tasks the roles reported blocked, by name from their Blocker Reports, then `/sdd-code-review <FeatureName>`. It and `/sdd-actualize <FeatureName>` are optional.
