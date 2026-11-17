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
  - `REVIEW_PATH`, for what each finding says and recommends — its number, severity, place and stack are the gate's `FINDINGS:` records, never read out of the prose
- **Writes,** and nothing before the human's answer in step 2:
  - the `TODO Code Review:` markers, in the files their findings are about
  - the `verdict-stale` line of `review.md`
  - the code fixes are the roles'

## Process

1. **Gate:** run `.sdd/scripts/gate.sh code-fix <FeatureName>`.
   - `ok` fixes.
   - `ask` is always the same question: this project has not said how a stack of it is verified. No yes answers it — put the line to the human, write the answer with `.sdd/scripts/spec-edit.sh conf-set <KEY> -` (the command on stdin), and go on only then.
   - `ROOT` differing from `REVIEW_ROOT` says the code has moved since the review, and a finding may be about a line that is no longer there.

2. **Triage — the orchestrator's own.** The `FINDINGS:` records — `F-##|severity|category|file|line|stack` — are the work of this run; `REVIEW_PATH` is read for what each one says and recommends.
   - Open with `REVIEW_VERDICT` and `REVIEW_DATE`, then the findings, worst first.
   - A record whose stack is `-` names no role: ask which stack fixes it in the same question as the policy.
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

3. **Write the markers** — the orchestrator's own, and **before any spawn**: a finding's line number is the line as the review saw it, and a fix moves the lines under it. Run `.sdd/scripts/spec-edit.sh marker -` once, with one `<file>|<line>|<text>` record on stdin per finding marked *TODO marker* — the file and the line of its `FINDINGS:` record, the text the finding in one line; never `tasks.md` and never only the chat. The script orders the writes itself. A record with `-` for the file or the line has no place to put a marker: that finding goes back to the human as a fix or a leave-as-is before the call. A stop writes nothing and names each record it refused — a file type with no comment syntax among them; those findings go back to the human the same way, and the call is made again with the rest.

4. **Spawn** by the `SPAWN:` records, in the order printed. A record whose stack has no finding marked *fix* — by the stack of its `FINDINGS:` record, or the human's answer where that was `-` — is dropped whole. For every record left, run `.sdd/scripts/spawn-prompt.sh code-fix <FeatureName> <scope> -` with two blocks on stdin: `TRIAGE:` — the human's answer, word for word; `FINDINGS:` — the `F-##` numbers of that stack's findings marked fix, one per line and nothing else: the role reads each finding in the report itself, so no finding is retyped. One spawn per role for all of its findings, never one per finding.

5. **Verify:** if any code changed, run `.sdd/scripts/build-run.sh <stack>` for each stack a role changed code in — `backend`, `frontend`. `BUILD=green` — the fixes hold. `BUILD=red` — report its `TAIL:` and `LOG=`; the human decides what happens next. A marker is not code: a run that only wrote markers has nothing to re-verify and says so.

6. **Invalidate the report** — the last write of the run. If anything changed, run `.sdd/scripts/spec-edit.sh verdict-stale <FeatureName>`. The findings are left standing — a re-run of `/sdd-code-review` is what replaces them. If nothing changed, the file is left exactly as it was and the script is not run.

7. **Report the next step:** what was fixed, what got a marker and where, what was left as-is, and the build result. Then `/sdd-code-review <FeatureName>` — the verdict on the code as it now stands comes from a fresh review, not from this run.
