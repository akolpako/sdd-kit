# Protocol: project baseline

*Addressed to the agent writing the project-level spec files. It names no command and no agent.*

The files in `_docs/` that belong to the whole project rather than to one feature — the architecture baseline, `code-style.md`, `requirements.md`. They are written twice in a project's life: once from the codebase, when the engine is set up, and then a decision at a time, as features are finished. The assignment states which of the two it is.

## The architecture baseline

The architecture of the project has two shapes, and a project holds one of them:

- **Sections** — one file per topic under `_docs/architecture/`, entered through `_docs/architecture.index.md`, a table of topic and path that `spec-edit.sh arch-index` writes whole from whatever the folder holds. This is what `/sdd-init` creates.
- **A single file** — `_docs/architecture.md`, holding the same topics as `## ` sections. A small project may keep this instead.

Both on disk at once is an error the gate stops on: nothing can say which of the two a role is meant to read.

Every assignment names the entry point, and that is what is read first: in the sections shape it is the index, and the section files a piece of work needs are read from there. All sixteen are never read at once.

**Which sections a project keeps is the project's answer.** The templates `/sdd-init` lays down are a starting set, not a required one. A section this project has nothing to say about — the API of a project that exposes none, the data model of one that persists nothing — is **deleted**, not left standing as an empty template; a topic the starting set has no file for gets a new file of its own. The index is rebuilt by the command once this assignment returns — do not write it by hand. Nothing in the engine checks which sections exist, so the set being honest is this role's responsibility and no script's.

**Human-written content is never discarded.** Every rule below is a rule about what may be added or corrected; nothing here authorizes deleting what a human put on the page.

## 1. From the codebase

The assignment names which of the output files already exist. Analyze the codebase — architecture patterns, technology choices, module structure, and the conventions the code actually follows — and write each output file according to that file's current state:

- **Does not exist** → the scaffold runs before this assignment and puts every file on disk, so a missing file means the setup was cut short. Report it and write nothing in its place: the next run scaffolds it.
- **Untouched template** (nothing outside the section skeletons and the hint comments the template shipped with) → fill it with the analysis. This is a state the engine tests for rather than a judgement: a file counts as written once it holds text of its own outside those comments, and a hint comment left standing beside that text does not make it unwritten.
- **Has real content** → update only the sections where the codebase has diverged, preserve human-written content, add sections the analysis discovered, and flag every conflict as a `<!-- REVIEW: ... -->` comment.

Three of them override that rule:

- `requirements.md` — a blank file gets the template as it is; requirements are not derived from code. Never overwrite an existing `REQ-###` entry.
- The architecture baseline — the sections that do not apply to this codebase are deleted rather than filled, and the index is rebuilt afterwards.
- `code-style.md` — write only into sections carrying the `derived: confirm or correct` marker, rewriting each in full and leaving the marker where it stands; instantiate the template's `## <stack>` section once per stack the project has, and leave no uninstantiated `## <stack>` heading in the file. A divergence in an unmarked section is reported as a `<!-- REVIEW: ... -->` comment above it, never written into.

An analysis that fails on one file is reported; the remaining files are still written.

## 2. From a finished feature

Read the feature's `design.md` and find the decisions that hold beyond it:

- new architectural decisions,
- technology choices,
- data model changes.

Each one is added to the architecture baseline, in the place that owns that topic: in the sections shape, the section file whose subject it is — a persistence change into the data model, a chosen library into the technology stack; in the single-file shape, the `## ` section whose subject it is. A decision that belongs to no existing section is a new section file, or a new `## `, named for its topic.

**Feature-specific implementation detail that does not generalize is not added**, however sound it is — the baseline is what the next feature inherits, not a record of this one. When something new contradicts what is already there, update the existing content to describe the current state rather than leaving two answers on the page.

## 3. Output Rules

- Follow the structure of the file you were handed — it is the template, copied to that path and waiting to be written into.
- **Purpose, not file counts.** A module is described by why it exists, what decided its shape, and what it owns versus delegates — never by the files in it or how many there are.
- No placeholders written into a filled section — a hint comment left standing in a file nobody has filled in yet is not a placeholder, it is the scaffold.
- Whatever the analysis could not settle is a `<!-- REVIEW: ... -->` comment, never a silent decision.
