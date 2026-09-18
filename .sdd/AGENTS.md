# Information for agents

This project uses Spec-Driven Development.

**Nobody commits** — no command, no role. The current state of the project is the working tree, never the git history.

## The assignment

**The prompt carries everything the role needs**: the protocols it is to follow, the paths it may read and write, and whatever was already resolved — the build command, a starting number, the records of the work. A role looks nothing up that the prompt did not name, and reads nothing in a folder the prompt did not name.

What a role changed is read from the working tree, never from its prose.

## Scripts

**A script that fails is reported, never worked around** — every error is the human's call. A `NOTES:` section is part of the answer too: it names what the script could not settle on its own, so it is passed on.

## Skills

A role may consult any other project skill when it helps.

Whatever communication style the session is set to, anything written to `_docs/**` is normal prose.

## Instructions conflicts

**Precedence on conflict:** `_docs/code-style.md` (for code) or the architecture baseline — `_docs/architecture.index.md` and the sections it points at, or `_docs/architecture.md` — (for architecture) wins over instructions.
