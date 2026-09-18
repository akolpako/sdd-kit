# Assignment: review the requirements of {{FEATURE}}

Follow these protocols, in this order:

{{PROTOCOLS}}

MODE={{MODE}}
FEATURE={{FEATURE}}

Files of this run:

{{SECTION:SPEC_FILES}}

Entries of the compilation this feature sourced:

{{SECTION:COMPILATION_ENTRIES}}

The first free number of the ungrouped sequence is {{NEXT_REQ}}; a domain's own
comes from `.sdd/scripts/next-req.sh . <DOMAIN>`, and which sequence this
feature writes into is what the numbering protocol settles.

Run your checklist passes over `_docs/{{FOLDER}}/new-requirements.md` and return
the `FAIL` list. Settle what you can settle yourself, and write it into that
file — no one else writes it.

What only the human can settle goes into its `## Open Questions`, one line
each, carrying your recommended answer. A line already carrying an `**Answer:**`
is the human's: fold it into the requirement it belongs to, retire the `A-##`
that line names, and delete the line. Leave every line without an answer as it
stands, word for word.

Return: the `FAIL` list first, then what you fixed and what you left on the
page, worst first.
