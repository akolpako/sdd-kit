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

2. **Scaffold:** run `.sdd/scripts/spec-edit.sh scaffold init`. Both branches, and before anything is spawned. `COPIED:` and `UNTOUCHED:` are the files waiting to be written into; `SKIPPED:` already holds answers of its own. `MODE=` says which shape the architecture baseline is in: `split`, a folder of sections under `_docs/architecture/` entered through `_docs/architecture.index.md`, or `mono`, the single `_docs/architecture.md` — the shapes are described in `.sdd/protocols/project-baseline.md`. A project that wants the single file on a fresh setup gets it from `scaffold init --mono`.

3. **Greenfield** — `PROJECT=greenfield`, the orchestrator's own. Relay the scaffold's sections, report that no codebase was found, and ask the human to fill in the architecture baseline and the code style.

4. **Spawn** the `SPAWN:` record, if one is printed: run `.sdd/scripts/spawn-prompt.sh init baseline-from-codebase`. On greenfield the section is empty and nobody is spawned.

5. **Rebuild the index:** on `MODE=split`, run `.sdd/scripts/spec-edit.sh arch-index` once the spawn returns. The role deletes the sections this project has nothing to say about and adds the ones the starting set has no file for, and the index is what says which sections it ended up with. Skipped on `MODE=mono`, which has no index.

6. **The build command** — the orchestrator's own. The answer is what every later build runs.

   **Whether to ask.** A `DETECTED:` row is `<dir>|<build file>|<command>|<stack>`. *Answered* means `BUILD_ROOT`, `BUILD_BACKEND` or `BUILD_FRONTEND` already carries a value for that stack; the gate prints the row either way.

   | `DETECTED:` row | The stack | `PROJECT` | What happens |
   |---|---|---|---|
   | one | unanswered | brownfield | **ask**, naming the build file found and the command proposed for it |
   | one | answered | any | **report** it; the question is not asked twice |
   | none | unanswered | brownfield | **ask** one open question — a Makefile, a script or a monorepo task runner is a build the detection does not know |
   | none | unanswered | greenfield | **defer**: say the question waits, and that the first `/sdd-implement` asks it |
   | any | answered | greenfield | **report** it |

   Whatever comes back is the answer, unread and unjudged: a different command, a profile, a wrapper, a flag.

   **Where the answer goes** — `.sdd/sdd.conf` at the project root, one `KEY=value` line per answer:

   | The project | Keys written |
   |---|---|
   | both stacks | `SDD_BUILD_BACKEND`, `SDD_BUILD_FRONTEND` |
   | everything else | `SDD_BUILD_ROOT` |

   Create the file if it is not there, and leave every line already in it — the `SDD_LOG*` keys are the human's too. A key already carrying the same answer is left alone rather than written twice.

7. **Verify:** run `.sdd/scripts/gate.sh init --verify`.

8. **Report the next step:** name the files and say to read them before going further — `code-style.md` says in its own header how to approve what was proposed. Then `/sdd-next-story <FeatureName>` starts the first feature.
