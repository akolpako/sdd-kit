# Assignment: the frontend tasks of {{FEATURE}}

Follow these protocols, in this order:

{{PROTOCOLS}}

Before the first task, load the installed skills that match this work, as your
`## Skills` section says.

FEATURE={{FEATURE}}

Build command — the verification of this run, resolved already:

{{BUILD_FRONTEND}}

It is run as `.sdd/scripts/build-run.sh frontend`, and in no other way.

Files of this run:

{{SECTION:SPEC_FILES}}

The open tasks of this feature:

{{SECTION:TODO}}

Tasks the human holds back from this run — open or blocked, left as they stand:

{{HELD}}

Your type is `frontend`, and every task of it above is yours in this one run.
Your `tasks.md` is `_docs/{{FOLDER}}/tasks.md` — run the task loop over it.

A record marked `blocked` failed in an earlier run and is retried like any open
one, unless it is held back above. A task that consumes backend work which did
not land is blocked the same way — never stub the backend to get around it.

Return, with the skills you loaded named on the first line: the tasks you
closed, the tasks you blocked with their reports, and the result of the build
command above.
