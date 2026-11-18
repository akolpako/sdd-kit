---
name: sdd-code-review
description: "Review implemented code against the specification and code style."
argument-hint: "<FeatureName> [<base-ref>]"
disable-model-invocation: true
---

# /sdd-code-review <FeatureName> [<base-ref>]

This command:
- is read-only on the code — no fix is applied here
- runs no build of its own
- may run the tests where that is what judging coverage takes — and tests that come back red are what a `BLOCKED` verdict reads

Safe to re-run: the report is a snapshot of the working tree, overwritten whole each time.
`<base-ref>` is optional — pass it when the base branch cannot be detected.

## Context

- **Reads:**
  - `.sdd/protocols/orchestration.md`
  - the output of `.sdd/scripts/gate.sh code-review`
  - the prompt `.sdd/scripts/spawn-prompt.sh` renders
  - `REVIEW_PATH`, once the role has written it — for the closing report
  - never the spec files or the diff — those are the role's to read
- **Writes,** and nothing else:
  - the backup, and the template of `_docs/<FeatureName>/review.md` with its header and its last section, the markers already in the tree
  - the findings, the coverage and the verdict in it are the role's

## Process

1. **Gate:** run `.sdd/scripts/gate.sh code-review <FeatureName> [<base-ref>]`. `GATE=ok` reviews.

2. **Scaffold the report:** back up first — a stop there leaves the earlier report standing. Then run `.sdd/scripts/spec-edit.sh scaffold review <FeatureName> "<BASE>" "<ROOT>"` with the gate's two values, each passed even when it is empty. It puts the template at `REVIEW_PATH` over whatever an earlier run left there, writes the date, the base and the root into its header, and fills its last section with the `TODO Code Review:` markers standing in the tree — reported, never removed and never re-raised as findings. `MARKERS=failed` is a sweep that did not complete: relay its `NOTES:` line, never a tree reported as having no markers in it. `REVIEW_PREVIOUS` says which report is being replaced; it is named in the closing output, never merged into the new one.

3. **Spawn** the `SPAWN:` record, once: run `.sdd/scripts/spawn-prompt.sh code-review <FeatureName> review-set`, adding `BASE=<base-ref>` when the human passed one. **The role writes its report into `REVIEW_PATH` itself** — the review set, the findings numbered `F-01` upward, the coverage, the verdict. Nothing of it is retyped here: what the role returns is a summary, and the file is the report. The `F-##` numbers in it are what `/sdd-code-fix` triages by.

4. **Verify:** run `.sdd/scripts/gate.sh code-review <FeatureName> --verify`.

5. **Report to the human,** from `REVIEW_PATH` as it now stands on disk — read it here, not the role's summary:
   - The verdict first, then the findings, worst first.
   - If the role's list ended with `N more findings below the reporting threshold`, say so at the same time — what is on screen is the top of the list, not all of it.
   - Then the coverage gaps: the requirements with no code, the requirements with no test, and the conditions of satisfaction no test covers. The full coverage table stays in the report file. The matrix reports and does not block: whether a requirement without a test is acceptable is the human's call.

6. **Report the next step:** the path of the report, then what follows from the verdict — `/sdd-code-fix <FeatureName>` when there is anything to act on, `/sdd-actualize <FeatureName>` when there is not. No code was touched.
