# Information for agents

This project uses Spec-Driven Development.

**Nobody commits** — no command, no role. The current state of the project is the working tree, never the git history.

## The assignment

**The prompt carries everything the role needs** — or the file it points at, read whole before anything else: the protocols it is to follow, the paths it may read and write, and whatever was already resolved — the build command, a starting number, the records of the work. A role looks nothing up that the prompt did not name, and reads nothing in a folder the prompt did not name.

What a role changed is read from the working tree, never from its prose.

## Scripts

**A script that fails is reported, never worked around** — every error is the human's call. A `NOTES:` section is part of the answer too: it names what the script could not settle on its own, so it is passed on.

## Skills

A role may consult any other project skill when it helps.

The `jira` and `confluence` skills' scripts take their tokens from the files passed with `--tokens`: pass `~/.config/sdd-kit/tokens.env`, then `.sdd/sdd.conf` when the project has one — in that order, so the project's file wins.

**Publishing is the human's call.** `jira-publish.sh` and `confluence-publish.sh` run with `--yes` only after the human has seen the dry run and said yes in the session; a role never passes `--yes`.

Whatever communication style the session is set to, anything written to `_docs/**` is normal prose.

## Instructions conflicts

**Precedence on conflict:** `_docs/code-style.md` (for code) or the architecture baseline — `_docs/architecture.index.md` and the sections it points at, or `_docs/architecture.md` — (for architecture) wins over instructions.
