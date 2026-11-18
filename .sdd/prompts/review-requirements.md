# Assignment: review the requirements of {{FEATURE}}

Follow these protocols, in this order:

{{PROTOCOLS}}

MODE={{MODE}}
FEATURE={{FEATURE}}

Files of this run:

{{SECTION:REQUIREMENTS_FILES}}

Entries of the compilation this feature sourced:

{{SECTION:COMPILATION_ENTRIES}}

The domains in use, one record per sequence — `-` is the ungrouped one:

{{SECTION:REQ_DOMAINS}}

The first free number of the ungrouped sequence: {{NEXT_REQ}}.

Run your checklist passes over `_docs/{{FOLDER}}/new-requirements.md` and return
the `FAIL` list. Settle what you can settle yourself, and write it into that
file — no one else writes it.

What only the human can settle goes into its `## Open Questions`, and a line
there already carrying an `**Answer:**` is folded in — both as the spec-modes
protocol fixes them.

Return only the `FAIL` items you did not close, worst first, one line each, or
that none is left — what you fixed is read from the file, never from your reply.
