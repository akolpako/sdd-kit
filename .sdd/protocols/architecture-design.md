# Protocol: architecture design

*Addressed to the agent writing `design.md`. It names no command and no agent.*

How a set of requirements becomes the architecture an implementer works from. **What** is being designed arrives with the assignment; this is what happens to it once it has arrived.

## 1. Inputs

- `new-requirements.md` — the source of what is to be built, whether this run generated it or an earlier one did.
- The existing `design.md` and `tasks.md`, whenever they are there: you are updating them, not starting over.
- The architecture baseline — the architectural decisions already fixed for the whole project; a design contradicts none of them silently. The assignment names its entry point: `_docs/architecture.index.md`, whose table says which section file holds which topic, or `_docs/architecture.md` on a project that keeps the single file. Read the entry point, then the sections this design touches — never all of them. The shapes are described in `.sdd/protocols/project-baseline.md`.
- `raw.md`, when it is provided — its `## Known constraints` and `## Out of scope` are the human's own words; a design never overrides one of them silently, even when the alternative is technically better.
- The `design.md` the assignment names — already on disk, holding the template it was scaffolded from. That is the structure to keep.

## 2. Assumptions and Risks

- Every unverified architectural decision is an `A-##` assumption on the page, retired as the answer arrives.
- A risk is written into the section that owns it — `## Security Considerations`, `## Non-Functional Requirements`, or `## Business Logic`; one no section owns becomes an `A-##` assumption or an `## Open Questions` line.

## 3. The Design Document

Derive the architecture style and the bounded contexts from the goals, actors, key flows, and constraints in `new-requirements.md`. Then fill the sections of `design.md`: the C4 views the feature changes, module decomposition, the conceptual data model and its persistence mapping, the API boundary contract-first, business logic and calculation rules, what the feature adds to the attack surface, and the non-functional baselines it changes or is bound by.

**A section the feature does not change is a pointer.** Whatever the architecture baseline already fixes and this feature only inherits — a layer, a convention, a stack decision — is one line naming the file, or the `## ` section, that holds it, never a restatement.

**Purpose, not file counts.** A module is described by why it exists, what decided its shape, and what it owns versus delegates — never by the files in it or how many there are. The same holds for the baseline's module structure.

## 4. Diagrams

Mermaid, and only for what this feature changes — a level the feature leaves untouched is referenced from the architecture baseline, never redrawn.

- **C4 Context (L1)** and **C4 Container (L2)** — when the feature adds or changes a system boundary or a container.
- **ERD** — when it adds or changes persisted data.
- **Sequence diagram** — for at least one workflow it introduces.
- **Module dependency graph** — when it adds or moves a module.

**Greenfield.** On a project with no code the feature changes everything, and that does not mean draw everything: one diagram of the slice the feature introduces is the default. C4 L2, the ERD, and a sequence diagram are added only when the feature genuinely introduces a container, persisted data, or a multi-step flow — a single-container feature with no persistence gets neither.

Validate the syntax before finalizing.

## 5. Output Rules

Implementation-guiding and testable: every section says what an implementer can build from and a reviewer can check.
