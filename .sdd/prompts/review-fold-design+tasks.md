# Assignment: fold the answers into the design and the task breakdown of {{FEATURE}}

Follow these protocols, in this order:

{{PROTOCOLS}}

Load only the installed skills that what the answers touch calls for, as your
`## Skills` section matches them — not every one that matches the feature.

MODE={{MODE}}
FEATURE={{FEATURE}}

Files of this run:

{{SECTION:SPEC_FILES}}

Entries of the compilation this feature sourced:

{{SECTION:COMPILATION_ENTRIES}}

Fold every line of `## Open Questions` in `_docs/{{FOLDER}}/design.md` that
carries an `**Answer:**` into the part of the design it belongs to, as the
spec-modes protocol fixes it: the answer written in, the `A-##` it names
retired, the line deleted. A line without an answer stays exactly as it is.

Then re-check only what the answers touched — the sections of the design they
changed, and the tasks of `_docs/{{FOLDER}}/tasks.md` that build them, brought
in line. The rest is not re-checked in this run: it was checked before these
questions were asked. An answer that raises a new question puts it on the page,
as a line of `## Open Questions` in `design.md`, like any other.

Return only what the answers left unsettled, and a done task the revision made
pointless, one line per point, or that none is — what you folded in is read
from the files, never from your reply.
