---
name: sdd-specify
description: "Write specification for a feature: requirements, design, and tasks."
argument-hint: "<FeatureName>"
disable-model-invocation: true
---

# /sdd-specify <FeatureName>

Generates the three spec files from `raw.md`, each as a draft. Re-running asks before it overwrites anything.

## Context

- **Reads:**
  - `.sdd/protocols/orchestration.md`
  - the output of `.sdd/scripts/gate.sh specify`
  - the prompts `.sdd/scripts/spawn-prompt.sh` renders
  - never the spec files — those are the roles' to read
- **Writes,** and nothing else:
  - the snapshot that precedes the run
  - the templates of the files this run writes
  - `_docs/<FeatureName>/new-requirements.md`, `design.md`, `tasks.md` are the roles'
  - never `_docs/requirements.md` — `/sdd-actualize` is what writes it

## Process

1. **Gate:** run `.sdd/scripts/gate.sh specify <FeatureName>`. `ask` is step 2; `ok` means nothing exists yet — generate without asking, skipping step 2.

2. **What gets overwritten** — the orchestrator's own, start to finish. Put the `ASK:` line to the human, naming per file its `STATUS_*` marker — `draft`, `ready` or `absent`, and an `absent` marker counts as `draft` and is said out loud. Three answers, and no fourth:
   - **Overwrite all three** — regenerate the whole spec from `raw.md`.
   - **Overwrite selected files only** — the human names them; the rest are left untouched.
   - **Cancel** — nothing is written and no `REQ-###` number is handed out.

   Then back up, before anything is spawned.

3. **Scaffold:** run `.sdd/scripts/spec-edit.sh scaffold spec <FeatureName> <the files this run writes, space-separated>` — all three when nothing was there, and on the `ask` path only the ones the human released. The op overwrites every file it is given, so a file the human kept is never named here.

4. **Spawn** by the `SPAWN:` records, in the order printed. A record is dropped whole when the human kept every file it writes — that role is not spawned. For every record left, run `.sdd/scripts/spawn-prompt.sh specify <FeatureName> <scope> KEPT=<the files the human kept, comma-separated, or none>`.

5. **Verify:** run `.sdd/scripts/gate.sh specify <FeatureName> --verify --files=<the files this run wrote, comma-separated>` — the files the human kept are not named.

6. **Report the next step:** the files written and their `status: draft`, then to inspect them and run `/sdd-spec-review <FeatureName>`, which is what turns `draft` into `ready`.
