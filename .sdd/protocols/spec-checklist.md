# Protocol: spec checklist

*Addressed to the agent writing a spec file. It names no command and no agent.*

Four passes over the spec, run before a single question is asked. Each item comes out `PASS` or `FAIL`. A `FAIL` the role can settle on its own — wording, a missing edge case it can derive — is simply fixed; every other `FAIL` becomes a question for the interview. The checklist is deterministic: the same spec yields the same list.

1. **Completeness** — the spec says everything it must:
   - **Intent coverage comes first.** The role writing `new-requirements.md` walks `raw.md` point by point and finds, for each, either the requirement that covers it or the line in `## Out of Scope` that excludes it. A point in neither is a `FAIL`. A point that turns out to be out of scope is written into `## Out of Scope` in the human's terms, never dropped quietly.
   - Every requirement's conditions of satisfaction meet the count and shape `.sdd/templates/new-requirements.md` fixes.
   - `## Out of Scope` is on the page: what the feature does not cover is stated, not implied.
   - Assumptions are on the page as `A-##` lines, and edge cases are present.
2. **AC validation** — every condition of satisfaction, one at a time, against four properties: **testable** (a test or a manual check can decide it), **independent** (it does not lean on another condition to be understood), **unambiguous** (it has exactly one reading), **measurable** (it names a number or an observable outcome). A vague condition is rewritten when the fix is wording, and becomes a question when it needs a decision.
3. **Risk** — breaking changes, external dependencies, data integrity, security, performance. Each of the five is answered: a named risk with its consequence, or one line "no risk: `<reason>`" as a deliberate statement. An axis nobody mentioned is a `FAIL`, not an implicit "fine" — but an axis closed by that one line is a `PASS` and produces no `A-##`. An assumption is written only where a decision was actually taken without confirmation, never to keep a section from being empty.
4. **Alignment** — `design.md` against the architecture baseline, entered through the file the assignment names: layers, patterns, and stack match it; every component the design introduces is described; nothing contradicts a decision already taken. The `## Known constraints` of `raw.md` belong to this pass as well — a constraint the human stated is honoured or raised, never silently overridden.

Passes 1–3 belong to `new-requirements.md`, passes 3 and 4 to `design.md` — risk is asked of both files, and the design answers it in architectural terms. Run the passes that belong to the file your assignment names, and report your `FAIL` items together with the question each one raises.
