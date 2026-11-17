---
name: sdd-actualize
description: "Update the architecture baseline and requirements compilation with decisions from a completed feature."
argument-hint: "<FeatureName>"
disable-model-invocation: true
---

# /sdd-actualize <FeatureName>

Promotes what a finished feature decided into the project-level files. Safe to re-run: an entry already finalized is left as it is.

## Context

- **Reads:**
  - `.sdd/protocols/orchestration.md`
  - the output of `.sdd/scripts/gate.sh actualize`
  - the prompt `.sdd/scripts/spawn-prompt.sh` renders
  - `_docs/<FeatureName>/new-requirements.md`, for the final wording of the entries — the wording only: which entry a requirement becomes is the gate's `DECLARED:`
- **Writes,** and nothing else:
  - `_docs/requirements.md`
  - the snapshot that precedes it
  - `_docs/architecture.index.md`, rebuilt from `_docs/architecture/`
  - the architecture baseline itself is the role's

## Process

1. **Gate:** run `.sdd/scripts/gate.sh actualize <FeatureName>`.
   - `ok` promotes.
   - `ask` says the feature is not finished — a spec nobody reviewed, tasks left open, a review that blocked, a review that fixes have since outdated. It promotes only on an explicit yes to each line, and what was accepted this way is named again in the final report, in those words.

2. **Back up:** run `.sdd/scripts/spec-edit.sh backup`. If it exits non-zero, stop.

3. **Spawn** the `SPAWN:` record: run `.sdd/scripts/spawn-prompt.sh actualize <FeatureName> baseline-from-feature`.

4. **Rebuild the index:** run `.sdd/scripts/spec-edit.sh arch-index` once the spawn returns. It exits 2 on a project whose architecture is the single `_docs/architecture.md`, and that is not a failure — there is no index to rebuild.

5. **Update the requirements compilation** — the orchestrator's own, and **the last write of the run**: the entries are what marks the feature as promoted, so they are written only once the architecture baseline is. A spawn that failed stops the run here, with `requirements.md` untouched.

   One record of the gate's `DECLARED:` is one requirement, `<REQ-###>|<relation>|<REQ-NNN>`. The relation is taken from the record, never re-read out of the spec:

   | Relation | Calls |
   |---|---|
   | `new` | `spec-edit.sh compile-entry <FeatureName> <REQ-###> final -`, with `<short title>. <one-sentence description>.` on stdin |
   | `refines` | `spec-edit.sh compile-entry <FeatureName> REQ-NNN refine -`, the new wording on stdin — on `REQ-NNN`, not on the new number. The entry keeps its number and its source and gains `refined by <FeatureName>`; the new number gets no entry of its own. |
   | `supersedes` | the `new` call for `<REQ-###>`, then `spec-edit.sh compile-entry <FeatureName> REQ-NNN superseded-by:<REQ-###>` |

   The wording goes on stdin, as `orchestration.md` says — it is one line.

   `COMPILATION_ENTRIES:` from the gate lists the entries this feature already has in the file — `refined` marks one it reworded. On a re-run, that is what a half-finished run left behind.

6. **Verify:** run `.sdd/scripts/gate.sh actualize <FeatureName> --verify` — a declared requirement that did not arrive, an entry left `draft`, or a counter standing on a number already handed out, is what the next feature collides with.

7. **Report the next step:** what changed in the architecture baseline and in `requirements.md`, and every `ASK:` line of step 1 that was accepted. The feature is done.
