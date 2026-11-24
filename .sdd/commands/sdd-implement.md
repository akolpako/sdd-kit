---
name: sdd-implement
description: "Implement a feature by executing tasks from the specification."
argument-hint: "<FeatureName>"
disable-model-invocation: true
---

# /sdd-implement <FeatureName>

Safe to re-run: `[x]` is the only mark that takes a task out of the work. A blocked task is retried with fresh attempts when the human names it, and held back otherwise. The human may hold back open tasks as well.

## Context

- **Reads:**
  - `.sdd/protocols/orchestration.md`
  - the output of `.sdd/scripts/gate.sh implement`
  - the prompts `.sdd/scripts/spawn-prompt.sh` renders
  - never the spec files — those are the roles' to read
- **Writes:** the feature's starting point, `_docs/<FeatureName>/.implement-start`, once — the code, the tests, and the task marks in `_docs/<FeatureName>/tasks.md` are the roles'

## Process

1. **Gate:** run `.sdd/scripts/gate.sh implement <FeatureName>`.
   - `ask` starts only on an explicit yes to each line. An unreviewed spec accepted this way is named again in the final report, in those words — read off `ACCEPTED:` of the last verify.
   - An `ask` about the build command is the exception: no yes answers it, only the human's command, written with `.sdd/scripts/spec-edit.sh conf-set <KEY> -` (the command on stdin). Nothing is built or spawned until it is there.
   - The `ask` about blocked tasks — the one whose tasks `RETRY:` lists — is not answered by a yes either: the answer is the tasks to retry, all of them, or none. The rest are **held back**: passed to every role as `HELD=` in step 3, and named in the final report as what the human held back. A record is dropped whole when its stack is not in `OPEN_STACKS` and every `RETRY:` task of its type is held back — that role has nothing to do; so is one whose prompt `spawn-prompt.sh` refuses because every task of its stack is held back. When every record is dropped, nothing is built or spawned: report the held tasks and stop.
   - **Open tasks are held back only when the human says so** — in any words, at any gate verdict that goes on: "only TASK-001" holds back every other open task. They join the held-back list above, and nothing about them is asked. A task that builds on a held open one is not held by that: the role leaves it waiting and names it, and the verify reports it open — say that this is why when it does.
   - `done` means every task is `[x]`.

2. **Starting point, then the baseline build:** run `.sdd/scripts/spec-edit.sh start <FeatureName>` first. It records the commit and the files already dirty, so `/sdd-code-review` reviews this feature's code and not whatever else the working tree holds; a re-run keeps the first record (`START=kept`), and `START=none` — no git, or no commit yet — is not a stop. Then the baseline:

   | `BASELINE` | What to run |
   |---|---|
   | set | `.sdd/scripts/build-run.sh root` |
   | empty | `.sdd/scripts/build-run.sh <stack>` for each stack of `ROLE_ORDER`, in that order |

   The script runs the human's command and answers `BUILD=` — the build's own output stays in its `LOG=` file and is not read here.

   | `BUILD` | What happens |
   |---|---|
   | green | start |
   | red | stop, report its `TAIL:` and `LOG=`, and proceed only on the human's explicit go-ahead |

   A bootstrap first task has no baseline to establish: say so and start with it — the baseline is the build it produces.

3. **Spawn** the `SPAWN:` records in the order printed, **once each** for the whole feature, never once per task: per record, run `.sdd/scripts/spawn-prompt.sh implement <FeatureName> <scope> HELD=<the held-back tasks, comma-separated, or none>`. Render each prompt at the moment its role is spawned, not all of them up front — the frontend prompt rendered after the backend role returned is the one carrying what came back blocked.
   - **The orchestrator never writes into `tasks.md`.**
   - Tasks a role reports `blocked` do not stop the run: relay the Blocker Report unabridged, and let the remaining tasks that do not build on them proceed. The human decides what happens to the blocked ones.

4. **Verify:**
   - When a role returns, run `.sdd/scripts/gate.sh implement <FeatureName> --verify --scope=<the scope of that role> --held=<the held-back tasks, comma-separated, or none>` — the same list the roles were given, so a held task still open is not read as one the role failed. The verify after the last role is also the closing count: its `TASKS_DONE`/`TASKS_TOTAL`, `ANOMALIES:` and `ACCEPTED:` are the feature's, so no gate runs after it.
   - When every role has returned, run the build of step 2 again. Green — the feature is implemented. Red — report its `TAIL:` and `LOG=` with the Blocker Reports, and do not restart a loop: a red that traces to a `BLOCKED` task is attempts already spent, and a red that traces to none of them is said to be exactly that.

5. **Report the next step:** `TASKS_DONE`/`TASKS_TOTAL`, any `ANOMALIES:` and every `ACCEPTED:` line from the last verify of step 4, then the tasks the roles reported blocked, by name from their Blocker Reports, and the ones the human held back, then `/sdd-code-review <FeatureName>`. It and `/sdd-actualize <FeatureName>` are optional.
