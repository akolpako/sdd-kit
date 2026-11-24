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
  - the `## Open Questions` section of `new-requirements.md` and `design.md`
  - nothing else of the feature's spec files — those are the roles' to read
- **Writes,** and nothing else in either file — everything else in their bodies is the roles':
  - the snapshot that precedes the run
  - the `status` markers of the feature's `new-requirements.md`, `design.md`, `tasks.md`
  - the `## Open Questions` section of `new-requirements.md` and `design.md` — the human's answers, appended to the lines they answer
  - never `_docs/requirements.md` — `/sdd-actualize` is what writes it

## Process

1. **Gate:** run `.sdd/scripts/gate.sh review <FeatureName>`. `GATE=ok` reviews. `ANOMALIES:` open the session rather than close it — several of them are exactly what this review exists to settle.

   Then back up: run `.sdd/scripts/spec-edit.sh backup <FeatureName>` — the roles rewrite the spec in place. If it exits non-zero, stop.

   Then reset: run `.sdd/scripts/spec-edit.sh status <FeatureName> draft <file ...>`, naming each file whose `STATUS_*` is `ready`, and skip the call when none is. `ready` is the verdict of this run, never one carried over: the roles are about to change those files, and a run cut short must not leave a rewritten spec marked as reviewed.

2. **Spawn** the `SPAWN:` records one at a time, in the order printed, and the next only once the file of the one before is done (step 3) — the next one as the gate prints it then: per record, run `.sdd/scripts/spawn-prompt.sh review <FeatureName> <scope>`. The design is reviewed against requirements that no longer move — spawned before them, it would ask about text that is about to change and have to run again. A role returns only the `FAIL` items it did not close — what it fixed is on the page. **The questions are read from `## Open Questions` of its file, never out of its report.**

3. **Interview and re-spawn,** one file at a time — requirements, then design. One round over one file:
   - **Read `## Open Questions`** out of that file, with its line numbers. Nothing there, and nothing raised by the round before it, means the file is done — spawn the next record (step 2), or after the last one go on to step 4.
   - **For the design, the matrix first:** run steps 5 and 6 before its first question, so the coverage answers and the answers to `design.md`'s own lines are one round and each file gets one fold for them.
   - **Ask the human** one line of that section at a time, the role's own recommendation first among the options.
   - **Write each answer back** as it arrives: `.sdd/scripts/spec-edit.sh answer <file> <line> -`, the answer on stdin. The script appends `**Answer:**` and the text to that line and to nothing else — the wording of the question is the role's — and adds no line, so the numbers read above hold for every answer of the round.
   - **Run the gate again and spawn every record it prints as a fold, in the order printed** — requirements before design, so a `CHANGED:` line reaches `design.md` (step 6) before the design's fold is spawned — `.sdd/scripts/gate.sh review <FeatureName>`, then `.sdd/scripts/spawn-prompt.sh review <FeatureName> <its scope>` per record; the `requirements-engineer` record is `new-requirements.md`'s, the `architect` record `design.md`'s. A file whose `## Open Questions` holds an answered line comes back as a fold (`fold-requirements`, `fold-design+tasks`): the answers written in and what they touched re-checked, without the checklist. Nothing here picks the assignment — the gate reads it off the page.
   - Then round two, from the top.

   **At most two rounds per file per session.** A round is one fold, spawned after answers were written into the file; the first spawn of a file — its full review — is not a round. What is still open at that ceiling is not asked a third time: it stays on the page, and the verdict of step 7 accounts for it. **A file is spawned for a full review at most once per session, and its first spawn of the session counts as that, whatever its scope** — a file whose first spawn was a fold is not owed the checklist afterwards. When the gate prints the full record (`requirements`, `design+tasks`) for a file already spawned this session — its answered lines folded, an open one left — that record is not spawned: the file is done for this run. The count belongs to this run and the page carries no counter, so a review re-run after an interruption counts from zero.

4. **Conflicts are settled inside the loop of step 3, not after it.** Finding them is the roles': a new requirement that overlaps or contradicts an entry of `_docs/requirements.md`, and a design decision that contradicts the architecture baseline, each arrive as a line of `## Open Questions` like any other question.
   - For a requirement the question is always the same one — is it a **refinement** of the existing entry or its **replacement** — and the answer is written back onto its line by the same `spec-edit.sh answer` call. The role then records it as the `Refines:` / `Supersedes:` line under the requirement's heading; that line is what `/sdd-actualize` applies to the compilation. Nothing is written into `new-requirements.md` by hand here.
   - No conflict is left unresolved: a conflict line still unanswered when the rounds are spent is a critical gap, and the verdict of step 7 is `NOT READY`.

5. **Re-run the gate** after every spawn of the design — its full review and each fold — before its questions are asked (step 3): the roles have been rewriting `tasks.md` since step 1, so the matrix of step 6 comes from this run, never from an earlier one.

6. **Print the coverage matrix** — the orchestrator's own, to the chat, never into a file: the gate's `COVERAGE:` records of step 5, `<REQ>|<title>|<tasks>`, one row each, as they stand:

     | Requirement | Covered by |
     |-------------|------------|
     | `REQ-001` — Cart total | `TASK-001`, `TASK-004` |
     | `REQ-002` — Promo codes | — |

   **A requirement with no task is a stop.** The gate of step 5 lists them under `UNCOVERED:` — that list, not a count made off the table, is what is asked about: every one of them, and the human says which it is. A `requires` entry naming a `REQ-###` that `new-requirements.md` does not declare is under `UNDECLARED:`, with the task that names it, and is reported the same way.

   Both replies are answers like any other, except that no role asked them: each becomes a line of its own in the `## Open Questions` of the file whose role applies it — `.sdd/scripts/spec-edit.sh answer <file> new -`, with `<the requirement or task> — <what is wrong> **Answer:** <the human's words>` on stdin — and the round that follows applies it.
   - **Missing task** — into `design.md`, where the next round adds the task.
   - **Not in this feature after all** — into `new-requirements.md`, where the next round moves the requirement to `## Out of Scope`. Its number goes with it and is not reused. Its tasks are dropped by the design's fold that follows, as the rule below writes it.

   An answer written here belongs to the round of step 3 it was asked in, beside the answers to `design.md`'s own lines — never a round of its own — and counts against the same two-round ceiling of the file it was written into. The matrix is printed again off a fresh step 5 after the design's fold; a matrix with nothing under `UNCOVERED:` or `UNDECLARED:` and no open line left to ask closes the loop.

   **A design decision that changes what a requirement says reaches the requirements the same way the other way round.** The architect does not write `new-requirements.md`: it returns such a decision as a line `REQUIREMENT: <REQ-###> — <the change>, per design A-##`. Each becomes a line of `new-requirements.md` — `.sdd/scripts/spec-edit.sh answer new-requirements.md new -`, with `<the line as returned> **Answer:** carry it into the requirement` on stdin — and the gate prints `fold-requirements` for it next; the `CHANGED:` it returns comes back to the design by the rule below. Such a line belongs to the design's round it came from and spends no round of the requirements.

   **Requirements that change after the design was reviewed reach the design as a fold, not a second full review.** The full review of the design — the checklist — runs once per session, on its first spawn. A `fold-requirements` that returns after it with a `CHANGED:` line naming anything but `none` is followed by one line into `design.md`, written before the design's record is spawned again: `.sdd/scripts/spec-edit.sh answer design.md new -`, with `<the requirements of CHANGED:, as the role listed them> — changed in new-requirements.md after this design was reviewed **Answer:** bring the design and its tasks in line with them as they stand now` on stdin. The gate then reads an answered line in `design.md` and prints `fold-design+tasks`. A `CHANGED:` line before the design's first spawn is not written anywhere: that spawn reads the requirements as they stand.

7. **Close with a verdict** — exactly one of three, printed to the chat and never into a spec file, before any `status` marker is set:

      | Verdict | What it means | Status marker |
      |---------|---------------|---------------|
      | **READY** | The checklist came back clean, or everything it raised was answered and folded in; every question is answered, no requirement is uncovered | `status: ready` on all three files |
      | **READY WITH OPEN QUESTIONS** | What is still open is non-critical and written down — the `A-##` assumptions and `## Open Questions` lines, each named in the verdict | `ready` only after the human, having read that list, explicitly agrees |
      | **NOT READY** | A critical gap remains: a question the feature cannot be built without, a requirement no task covers, a contradiction with the architecture baseline | stays `draft`; the blockers are listed, one per line |

   The marker is written by `.sdd/scripts/spec-edit.sh status <FeatureName> ready <file ...>` — the last write of the run, only after every role has returned. The script refuses a file whose `## Open Questions` still holds a line — open, or answered and not yet folded in — so such a file rules **READY** out: the verdict is one of the other two. On **READY WITH OPEN QUESTIONS**, once the human has agreed, the call carries `--accept-open` and the lines stay on the page as what was accepted.

8. **Report the next step:** on `READY`, `/sdd-implement <FeatureName>`. On anything else, what is still open and that re-running `/sdd-spec-review <FeatureName>` is what closes it.
