---
name: sdd-status
description: "Report where each feature stands, computed from the files on disk."
argument-hint: "[<FeatureName>]"
disable-model-invocation: true
disallowed-tools: Write, Edit, NotebookEdit
---

# /sdd-status [<FeatureName>]

Reports the state of every feature, or of one. No argument — the summary; with `<FeatureName>` — the detail. Writes nothing and has no gate: a feature missing a file is exactly what this command is there to say.

## Context

- **Reads:**
  - `.sdd/protocols/orchestration.md`
  - the output of `.sdd/scripts/feature-state.sh`
  - the feature's `new-requirements.md`, for the coverage rows
  - the file of the `NEXT` command, for the one sentence that describes it
- **Writes:** nothing — the report goes to the chat

## Process

Every step is the orchestrator's own.

1. **Read the state:** run `.sdd/scripts/feature-state.sh` — with no argument for the summary, with `<FeatureName>` for the detail. Everything reported here comes out of that one run: no spec file is re-read for a signal the script already printed. This command has no gate, so the relay rule applies to this script's output instead: anything non-empty in `WARN:`, `ANOMALIES:` or `NOTES:` reaches the human word for word, before this command's own output.

2. **Report — no argument:** one row per record of `FEATURES:`, in the order they were printed, which is stage order, least advanced first:

   | Feature | Stage | Tasks | Next |
   |---------|-------|-------|------|
   | `Cart` | in progress 4/9, 2 blocked | 4/9 | `/sdd-implement Cart` |

   The `Tasks` cell is `done/total`; the blocked count is already inside the stage and is not repeated there. A record with an empty `next` field is a feature that is done: the cell is `—`, and no command is invented for it.

3. **Report — with an argument:** the `STAGE` line, then the sections below. Two files are opened here and nothing else: `new-requirements.md` for the coverage rows, and the file of the `NEXT` command for the one sentence that describes it.
   - **Files:** `RAW`, `REQUIREMENTS`, `DESIGN`, `TASKS`, the three spec files each with their `STATUS_*` marker. `raw.md` carries no status of its own and is reported bare.
   - **Tasks:** `TASKS_DONE`/`TASKS_TOTAL`, then every `TASKS:` record whose state is not `done` — the `blocked` ones first with their reason, then the `open` ones with ID, title and type. A feature with no open task says so in one line.
   - **Requirement coverage:** the `REQ-###` declared in `new-requirements.md` — a `### REQ-### — <title>` heading, the shape `.sdd/templates/new-requirements.md` fixes — against the `requires` field of the `TASKS:` records. Report requirements no task names, and `requires` entries that resolve to no declared requirement. This is the one signal the script does not print: it reads `tasks.md`, not `new-requirements.md`.
   - **Code review:** `REVIEW`, and when it is `present`, `REVIEW_VERDICT` with `REVIEW_DATE` and `REVIEW_ROOT` — the verdict, the day it was reached, and the commit it was reached on. A feature with no report says so in one line; the report itself is not opened here.
   - **Compilation:** `COMPILATION_ACTIVE`, `COMPILATION_DRAFT`, `COMPILATION_SUPERSEDED`, with the `COMPILATION_ENTRIES:` records behind those counts.
   - **Next command** — `NEXT`, with one sentence on what it will do, taken from the `description:` of that command's own file. An empty `NEXT` means the feature is done, and nothing is suggested in its place.

4. **Close with the anomalies:** the `ANOMALIES:` lines as they came, one per line, then the `NOTES:` lines. An empty section is one line saying there are none — never a section left off the report, and never a line invented to fill it. An anomaly is not restated in kinder words and not summarized away: report it, fix nothing.
