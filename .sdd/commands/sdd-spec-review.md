---
name: sdd-spec-review
description: "Review and refine the specification for a feature through interactive Q&A."
argument-hint: "<FeatureName>"
disable-model-invocation: true
---

# /sdd-spec-review <FeatureName>

Turns a `draft` spec into a `ready` one through the checklist and an interview. Safe to re-run: it edits the spec in place, never regenerating it.

## Context

- **Reads:**
  - `.sdd/protocols/orchestration.md`
  - the output of `.sdd/scripts/gate.sh review`
  - the prompts `.sdd/scripts/spawn-prompt.sh` renders
  - `_docs/requirements.md`, for overlaps and conflicts
  - never the feature's spec files — those are the roles' to read
- **Writes,** and nothing else in either file — everything else in their bodies is the roles':
  - the `status` markers of the feature's `new-requirements.md`, `design.md`, `tasks.md`
  - the `## Open Questions` section of `new-requirements.md` and `design.md` — the human's answers, appended to the lines they answer
  - never `_docs/requirements.md` — `/sdd-actualize` is what writes it

## Process

1. **Gate:** run `.sdd/scripts/gate.sh review <FeatureName>`. `GATE=ok` reviews. `ANOMALIES:` open the session rather than close it — several of them are exactly what this review exists to settle.

2. **Spawn** both `SPAWN:` records: per record, run `.sdd/scripts/spawn-prompt.sh review <FeatureName> <scope>`. A role returns its `FAIL` list and what it left on the page. **The questions are read from `## Open Questions` of its file, never out of its report.**

3. **Interview and re-spawn,** requirements first, then design. One round over one file:
   - **Read `## Open Questions`** out of that file. Nothing there, and nothing raised by the round before it, means the file is done — go on to step 4.
   - **Ask the human** one line of that section at a time, the role's own recommendation first among the options.
   - **Write the answers back:** `.sdd/scripts/spec-edit.sh section <file> "Open Questions" "<text>"`. The script replaces the section body whole, so `<text>` carries **every** line of the section, in its own order — a line left out of the call is deleted. Append `**Answer:**` and nothing else; the wording of the question is the role's (`.sdd/protocols/spec-modes.md`).
   - **Spawn the same scope again** — the same `SPAWN:` record, the same `spawn-prompt.sh` call, the same prompt. Nothing here tells the role which round it is on: what it does with an answered line is its own protocol's.
   - Then round two, from the top.

   At most three rounds per file per session, per `.sdd/protocols/interview.md`. What is still open at that ceiling stays on the page, and the verdict of step 7 accounts for it.

4. **Resolve conflicts.** No conflict is left unresolved.
   - A new requirement conflicting with one in `requirements.md` goes to the human, who says which of the two it is: a **refinement** of the existing requirement or its **replacement**. Record the answer in the feature's `new-requirements.md` next to the requirement — `refines REQ-NNN` / `supersedes REQ-NNN` — and `/sdd-actualize` applies it to the compilation.
   - A new architecture decision conflicting with the architecture baseline goes to the human the same way.

5. **Re-run the gate:** the roles have been rewriting `tasks.md` since step 1, so the `TASKS:` records the matrix of step 6 reads come from this run, never from the first one.

6. **Print the coverage matrix** — the orchestrator's own, to the chat, never into a file. Every `REQ-###` declared in `new-requirements.md`, against the `requires` field of the `TASKS:` records of step 5:

     | Requirement | Covered by |
     |-------------|------------|
     | `REQ-001` — Cart total | `TASK-001`, `TASK-004` |
     | `REQ-002` — Promo codes | — |

   **A requirement with no task is a stop.** List every one of them and ask the human which it is. A `requires` entry naming a `REQ-###` that `new-requirements.md` does not declare is reported the same way, with the task that names it.

   Both replies are answers like any other: each is written into the `## Open Questions` of the file whose role applies it, by the same `spec-edit.sh section` call as step 3, and the round that follows applies it.
   - **Missing task** — into `design.md`, where the next round adds the task.
   - **Not in this feature after all** — into `new-requirements.md`, where the next round moves the requirement to `## Out of Scope`. Its number goes with it and is not reused.

   An answer written here sends the run back to step 3 for one more round, inside the same three-round ceiling, and the matrix is printed again off a fresh step 5.

7. **Close with a verdict** — exactly one of three, printed to the chat and never into a spec file, before any `status` marker is set:

      | Verdict | What it means | Status marker |
      |---------|---------------|---------------|
      | **READY** | Every checklist pass is clean, every question is answered, no requirement is uncovered | `status: ready` on all three files |
      | **READY WITH OPEN QUESTIONS** | What is still open is non-critical and written down — the `A-##` assumptions and `## Open Questions` lines, each named in the verdict | `ready` only after the human, having read that list, explicitly agrees |
      | **NOT READY** | A critical gap remains: a question the feature cannot be built without, a requirement no task covers, a contradiction with the architecture baseline | stays `draft`; the blockers are listed, one per line |

   The marker is written by `.sdd/scripts/spec-edit.sh status <FeatureName> ready <file ...>` — the last write of the run, only after every role has returned. A file left with unanswered questions is not named in that call: it keeps `status: draft` and is named in the output instead.

8. **Report the next step:** on `READY`, `/sdd-implement <FeatureName>`. On anything else, what is still open and that re-running `/sdd-spec-review <FeatureName>` is what closes it.
