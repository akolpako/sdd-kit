---
name: sdd-init
description: "Initialize the SDD architecture baseline, requirements compilation, and code style for the project."
disable-model-invocation: true
---

# /sdd-init

Writes the project-level spec files. No arguments. Safe to re-run: a file that already holds content is never discarded.

## Context

- **Reads:**
  - `.sdd/protocols/orchestration.md`
  - the output of `.sdd/scripts/gate.sh init`
  - the prompt `.sdd/scripts/spawn-prompt.sh` renders
- **Writes,** and nothing else:
  - the templates of the architecture baseline, `_docs/code-style.md` and `_docs/requirements.md` — what goes into them is the role's on brownfield and the human's on greenfield
  - `_docs/architecture.index.md`, rebuilt from `_docs/architecture/` — generated, never written by hand
  - `.sdd/sdd.conf`, the human's answer on how the project is verified — the only write outside `_docs/`

## Process

1. **Gate:** run `.sdd/scripts/gate.sh init`. `GATE=ok` goes on.
   - `ask` is the build question, on brownfield only: one line per stack this project has and no answer for. No yes answers it — put each line to the human and write the answer with `.sdd/scripts/spec-edit.sh conf-set <KEY> -`, the key the line names and the command on stdin, before anything else happens. Whatever comes back is the answer, unread and unjudged: a different command, a profile, a wrapper, a flag. `.sdd/sdd.conf` itself is never opened here: it may hold a `JIRA_TOKEN`.
   - On greenfield nothing is asked: the first `/sdd-implement` asks it, once there is a build to name.

2. **Scaffold:** run `.sdd/scripts/spec-edit.sh scaffold init`. Both branches, and before anything is spawned. `COPIED:` and `UNTOUCHED:` are the files waiting to be written into; `SKIPPED:` already holds answers of its own. `MODE=` says which shape the architecture baseline is in: `split`, a folder of sections under `_docs/architecture/` entered through `_docs/architecture.index.md`, or `mono`, the single `_docs/architecture.md`. A project that wants the single file on a fresh setup gets it from `scaffold init --mono`.

3. **Greenfield** — `PROJECT=greenfield`, the orchestrator's own. Relay the scaffold's sections, report that no codebase was found, and ask the human to fill in the architecture baseline and the code style.

4. **Spawn** the `SPAWN:` record, if one is printed: run `.sdd/scripts/spawn-prompt.sh init baseline-from-codebase`. On greenfield the section is empty and nobody is spawned.

5. **Rebuild the index:** on `MODE=split`, run `.sdd/scripts/spec-edit.sh arch-index` once the spawn returns. The role deletes the sections this project has nothing to say about and adds the ones the starting set has no file for, and the index is what says which sections it ended up with. Skipped on `MODE=mono`, which has no index.

6. **Verify:** run `.sdd/scripts/gate.sh init --verify`.

7. **Report the next step:** name the files and say to read them before going further, and the build commands on file — the gate's `BUILD_*`, or the answers of step 1. `code-style.md` says in its own header how to approve what was proposed. Then `/sdd-next-story <FeatureName>` starts the first feature.
