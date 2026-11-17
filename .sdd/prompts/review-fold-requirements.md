# Assignment: fold the answers into the requirements of {{FEATURE}}

Follow these protocols, in this order:

{{PROTOCOLS}}

Load only the installed skills that what the answers touch calls for, as your
`## Skills` section matches them — not every one that matches the feature.

MODE={{MODE}}
FEATURE={{FEATURE}}

Files of this run:

{{SECTION:REQUIREMENTS_FILES}}

Entries of the compilation this feature sourced:

{{SECTION:COMPILATION_ENTRIES}}

The first free number of the ungrouped sequence: {{NEXT_REQ}}.

Fold every line of `## Open Questions` in
`_docs/{{FOLDER}}/new-requirements.md` that carries an `**Answer:**` into the
requirement it belongs to, as the spec-modes protocol fixes it: the answer
written in, the `A-##` it names retired, the line deleted. A line without an
answer stays exactly as it is.

Then re-check only what the answers touched — the requirements they changed,
added or moved — by the rules that write them. The rest of the file is not
re-checked in this run: it was checked before these questions were asked. An
answer that raises a new question puts it on the page, as a line of
`## Open Questions`, like any other.

Return only what the answers left unsettled, one line per point, or that none
is — what you folded in is read from the file, never from your reply.
