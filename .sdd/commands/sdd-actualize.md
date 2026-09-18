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
  - `_docs/<FeatureName>/new-requirements.md`, for the final wording of the entries
- **Writes,** and nothing else:
  - `_docs/requirements.md`
  - the snapshot that precedes it
  - `_docs/architecture.index.md`, rebuilt from `_docs/architecture/`
  - the architecture baseline itself is the role's

## Process

1. **Gate:** run `.sdd/scripts/gate.sh actualize <FeatureName>`. `GATE=ok` promotes.

2. **Back up:** run `.sdd/scripts/spec-edit.sh backup`. If it exits non-zero, stop.

3. **Update the requirements compilation** — the orchestrator's own. Make one call per `REQ-###` that the feature's `new-requirements.md` declares.
   - A plain new requirement: `spec-edit.sh compile-entry <FeatureName> <REQ-###> final "<short title>. <one-sentence description>."`
   - Marked `refines REQ-NNN`: make the same `final` call, but on `REQ-NNN`, not on the new number. The entry already in the file takes the new wording and keeps its old source.
   - Marked `supersedes REQ-NNN`: `spec-edit.sh compile-entry <FeatureName> REQ-NNN superseded-by:<REQ-###>`.

   `COMPILATION_ENTRIES:` from the gate lists the entries this feature already has in the file. On a re-run, that is what a half-finished run left behind.

4. **Spawn** the `SPAWN:` record: run `.sdd/scripts/spawn-prompt.sh actualize <FeatureName> baseline-from-feature`.

5. **Rebuild the index:** run `.sdd/scripts/spec-edit.sh arch-index` once the spawn returns. It exits 2 on a project whose architecture is the single `_docs/architecture.md`, and that is not a failure — there is no index to rebuild.

6. **Verify:** run `.sdd/scripts/gate.sh actualize <FeatureName> --verify` — an entry left `draft`, or a counter standing on a number already handed out, is what the next feature collides with.

7. **Report the next step:** what changed in the architecture baseline and in `requirements.md`. The feature is done.
