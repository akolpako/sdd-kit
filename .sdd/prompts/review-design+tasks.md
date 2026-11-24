# Assignment: review the design and the task breakdown of {{FEATURE}}

Follow these protocols, in this order:

{{PROTOCOLS}}

MODE={{MODE}}
FEATURE={{FEATURE}}

Files of this run:

{{SECTION:SPEC_FILES}}

Entries of the compilation this feature sourced:

{{SECTION:COMPILATION_ENTRIES}}

Run your checklist passes over `_docs/{{FOLDER}}/design.md` and
`_docs/{{FOLDER}}/tasks.md` and return the `FAIL` list. Settle what you can
settle yourself, and write it into those files — no one else writes them.

What only the human can settle goes into `## Open Questions` of
`_docs/{{FOLDER}}/design.md`, and a line there already carrying an
`**Answer:**` is folded in — both as the spec-modes protocol fixes them.

`tasks.md` is yours to bring in line with the revised requirements and design.

`new-requirements.md` is not yours to write. A decision of the design that
changes what a requirement says — a field it must name, a condition it must
carry — is returned as a line `REQUIREMENT: <REQ-###> — <the change>, per design
A-##`, and reaches that file through whoever led the review.

Return only the `FAIL` items you did not close, worst first, one line each, or
that none is left, and a done task the revision made pointless — what you fixed
is read from the files, never from your reply.
