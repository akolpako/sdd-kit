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
  - the `## Open Questions` section of `new-requirements.md` and `design.md`, and the `REQ-###` headings of `new-requirements.md` for the matrix
  - nothing else of the feature's spec files — those are the roles' to read
- **Writes,** and nothing else in either file — everything else in their bodies is the roles':
  - the snapshot that precedes the run
  - the `status` markers of the feature's `new-requirements.md`, `design.md`, `tasks.md`
  - the `## Open Questions` section of `new-requirements.md` and `design.md` — the human's answers, appended to the lines they answer
  - never `_docs/requirements.md` — `/sdd-actualize` is what writes it

## Process

1. **Gate:** run `.sdd/scripts/gate.sh review <FeatureName>`. `GATE=ok` reviews. `ANOMALIES:` open the session rather than close it — several of them are exactly what this review exists to settle.

   Then back up: run `.sdd/scripts/spec-edit.sh backup` — the roles rewrite the spec in place. If it exits non-zero, stop.

   Then reset: run `.sdd/scripts/spec-edit.sh status <FeatureName> draft <file ...>`, naming each file whose `STATUS_*` is `ready`, and skip the call when none is. `ready` is the verdict of this run, never one carried over: the roles are about to change those files, and a run cut short must not leave a rewritten spec marked as reviewed.

2. **Spawn** both `SPAWN:` records: per record, run `.sdd/scripts/spawn-prompt.sh review <FeatureName> <scope>`. A role returns its `FAIL` list and what it left on the page. **The questions are read from `## Open Questions` of its file, never out of its report.**

3. **Interview and re-spawn,** requirements first, then design. One round over one file:
   - **Read `## Open Questions`** out of that file, with its line numbers. Nothing there, and nothing raised by the round before it, means the file is done — go on to step 4.
   - **Ask the human** one line of that section at a time, the role's own recommendation first among the options.
   - **Write each answer back** as it arrives: `.sdd/scripts/spec-edit.sh answer <file> <line> -`, the answer on stdin. The script appends `**Answer:**` and the text to that line and to nothing else — the wording of the question is the role's — and adds no line, so the numbers read above hold for every answer of the round.
   - **Spawn the same scope again** — the same `SPAWN:` record, the same `spawn-prompt.sh` call, the same prompt. Nothing here tells the role which round it is on: what it does with an answered line is its own protocol's.
   - Then round two, from the top.
   - **The design follows the requirements.** Once a round changed `new-requirements.md`, the design scope is spawned at least once more after the requirements file is done, even when its own `## Open Questions` is empty: the design and the breakdown were written against the text that changed.

   At most three rounds per file per session, per `.sdd/protocols/interview.md`. What is still open at that ceiling stays on the page, and the verdict of step 7 accounts for it.

4. **Conflicts are settled inside the loop of step 3, not after it.** Finding them is the roles': a new requirement that overlaps or contradicts an entry of `_docs/requirements.md`, and a design decision that contradicts the architecture baseline, each arrive as a line of `## Open Questions` like any other question.
   - For a requirement the question is always the same one — is it a **refinement** of the existing entry or its **replacement** — and the answer is written back onto its line by the same `spec-edit.sh answer` call. The role then records it as the `Refines:` / `Supersedes:` line under the requirement's heading; that line is what `/sdd-actualize` applies to the compilation. Nothing is written into `new-requirements.md` by hand here.
   - No conflict is left unresolved: a conflict line still unanswered when the rounds are spent is a critical gap, and the verdict of step 7 is `NOT READY`.

5. **Re-run the gate:** the roles have been rewriting `tasks.md` since step 1, so the `TASKS:` records the matrix of step 6 reads come from this run, never from the first one.

6. **Print the coverage matrix** — the orchestrator's own, to the chat, never into a file. Every `REQ-###` declared in `new-requirements.md`, against the `requires` field of the `TASKS:` records of step 5:

     | Requirement | Covered by |
     |-------------|------------|
     | `REQ-001` — Cart total | `TASK-001`, `TASK-004` |
     | `REQ-002` — Promo codes | — |

   **A requirement with no task is a stop.** The gate of step 5 lists them under `UNCOVERED:` — that list, not a count made off the table, is what is asked about: every one of them, and the human says which it is. A `requires` entry naming a `REQ-###` that `new-requirements.md` does not declare is under `UNDECLARED:`, with the task that names it, and is reported the same way.

   Both replies are answers like any other, except that no role asked them: each becomes a line of its own in the `## Open Questions` of the file whose role applies it — `.sdd/scripts/spec-edit.sh answer <file> new -`, with `<the requirement or task> — <what is wrong> **Answer:** <the human's words>` on stdin — and the round that follows applies it.
   - **Missing task** — into `design.md`, where the next round adds the task.
   - **Not in this feature after all** — into `new-requirements.md`, where the next round moves the requirement to `## Out of Scope`. Its number goes with it and is not reused.

   An answer written here sends the run back to step 3 for one more round, inside the same three-round ceiling, and the matrix is printed again off a fresh step 5.

7. **Close with a verdict** — exactly one of three, printed to the chat and never into a spec file, before any `status` marker is set:

      | Verdict | What it means | Status marker |
      |---------|---------------|---------------|
      | **READY** | Every checklist pass is clean, every question is answered, no requirement is uncovered | `status: ready` on all three files |
      | **READY WITH OPEN QUESTIONS** | What is still open is non-critical and written down — the `A-##` assumptions and `## Open Questions` lines, each named in the verdict | `ready` only after the human, having read that list, explicitly agrees |
      | **NOT READY** | A critical gap remains: a question the feature cannot be built without, a requirement no task covers, a contradiction with the architecture baseline | stays `draft`; the blockers are listed, one per line |

   The marker is written by `.sdd/scripts/spec-edit.sh status <FeatureName> ready <file ...>` — the last write of the run, only after every role has returned. The script refuses a file whose `## Open Questions` still holds a line: on **READY** such a file is not named, keeps `status: draft` and is named in the output instead; on **READY WITH OPEN QUESTIONS**, once the human has agreed, the call carries `--accept-open` and the lines stay on the page as what was accepted.

8. **Report the next step:** on `READY`, `/sdd-implement <FeatureName>`. On anything else, what is still open and that re-running `/sdd-spec-review <FeatureName>` is what closes it.
