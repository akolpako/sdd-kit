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
`_docs/{{FOLDER}}/design.md`, one line each, carrying your recommended answer.
A line already carrying an `**Answer:**` is the human's: fold it into the design
it belongs to, retire the `A-##` that line names, and delete the line. Leave
every line without an answer as it stands, word for word.

`tasks.md` is yours to bring in line with the revised requirements and design.

Return: the `FAIL` list first, then what you fixed and what you left on the
page, worst first.
