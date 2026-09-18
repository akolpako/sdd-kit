# Assignment: the requirements of {{FEATURE}}

Follow these protocols, in this order:

{{PROTOCOLS}}

MODE={{MODE}}
FEATURE={{FEATURE}}

Files of this run:

{{SECTION:SPEC_FILES}}

Kept by the human from an earlier run — input to read, never rewritten:

{{KEPT}}

Write `_docs/{{FOLDER}}/new-requirements.md` from `_docs/{{FOLDER}}/raw.md`, with
`status: draft` among its properties. That file is already on disk, holding nothing
but the template it was copied from: the structure to keep is the one already in
it, and no template has to be found.

{{NEXT_REQ}} is the first free number of the ungrouped sequence. Which sequence
this feature writes into — that one, or a domain of its own — is settled as the
numbering protocol fixes it, and a domain's own next number comes from
`.sdd/scripts/next-req.sh . <DOMAIN>`. Number upward from the one that answers.
Declaring the number in `new-requirements.md` is what takes it;
`_docs/requirements.md` is not written in this run.

Return: the requirements you wrote, the numbers you gave them, and what `raw.md`
left unsettled.
