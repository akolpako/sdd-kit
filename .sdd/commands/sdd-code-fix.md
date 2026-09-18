---
name: sdd-code-fix
description: "Apply the findings of a code review and re-verify the build."
argument-hint: "<FeatureName>"
disable-model-invocation: true
---

# /sdd-code-fix <FeatureName>

Acts on the report `/sdd-code-review <FeatureName>` wrote. It applies findings, it does not find them: a fix that raises a new question goes back through a fresh review, never around it.

## Context

- **Reads:**
  - `.sdd/protocols/orchestration.md`
  - the output of `.sdd/scripts/gate.sh code-fix`
  - the prompts `.sdd/scripts/spawn-prompt.sh` renders
  - `REVIEW_PATH`, for the findings to triage
- **Writes,** and nothing before the human's answer in step 2:
  - the `TODO Code Review:` markers, in the files their findings are about
  - the `verdict-stale` line of `review.md`
  - the code fixes are the roles'

## Process

1. **Gate:** run `.sdd/scripts/gate.sh code-fix <FeatureName>`.
   - `ok` fixes.
   - `ask` is always the same question: this project has not said how a stack of it is verified. No yes answers it — put the line to the human, and go on only once the answer is in `.sdd/sdd.conf`.
   - `ROOT` differing from `REVIEW_ROOT` says the code has moved since the review, and a finding may be about a line that is no longer there.

2. **Triage — the orchestrator's own.** Read `REVIEW_PATH`; its findings, by their `F-##` numbers, are the work of this run.
   - Open with `REVIEW_VERDICT` and `REVIEW_DATE`, then the findings, worst first.
   - **Ask the human for the policy once**, not per finding. The default:

     | Severity | Outcome |
     |---|---|
     | Critical | fix |
     | Major | fix |
     | Minor | TODO marker |
     | Suggestion | TODO marker |

     The answer may take it whole, take it with named exceptions, or replace it. Only the exceptions are then asked about one by one, and an answer that names none ends the conversation: the policy applies to every finding as it stands and no second question is asked.
   - **The finding's own recommendation wins over the policy** where it is to leave the finding alone: the outcome is **leave as-is**, with no question and no marker over a decision that was taken deliberately.
   - Three outcomes per finding, and no fourth: **fix**, **TODO marker**, **leave as-is**. What is left as-is is named again in the closing report.

3. **Spawn** by the `SPAWN:` records, in the order printed. A record whose stack has no finding marked *fix* is dropped whole. For every record left, run `.sdd/scripts/spawn-prompt.sh code-fix <FeatureName> <scope> TRIAGE=<the human's answer, word for word> FINDINGS=<that stack's findings marked fix, with their F-## numbers, locations and recommendations>`. One spawn per role for all of its findings, never one per finding.

4. **Write the markers** — the orchestrator's own. For every finding marked *TODO marker*, run `.sdd/scripts/spec-edit.sh marker <file> <line> <the finding, one line>` — the file and the line the finding is about, never `tasks.md` and never only the chat. A file type the script has no comment syntax for is relayed as the stop it is; the finding then goes back to the human as a fix or a leave-as-is.

5. **Verify:** if any code changed, run the build command of the stacks that changed — `BUILD_BACKEND`, `BUILD_FRONTEND`. Green — the fixes hold. Red — report the failure with the output; the human decides what happens next. A marker is not code: a run that only wrote markers has nothing to re-verify and says so.

6. **Invalidate the report** — the last write of the run. If anything changed, run `.sdd/scripts/spec-edit.sh verdict-stale <FeatureName>`. The findings are left standing — a re-run of `/sdd-code-review` is what replaces them. If nothing changed, the file is left exactly as it was and the script is not run.

7. **Report the next step:** what was fixed, what got a marker and where, what was left as-is, and the build result. Then `/sdd-code-review <FeatureName>` — the verdict on the code as it now stands comes from a fresh review, not from this run.
