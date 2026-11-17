# Protocol: developer

*Addressed to the agent writing the code. It names no command and no agent.*

How code is written on this project. **What** is to be built arrives with the assignment; this is how it gets built once it has arrived.

## 1. Input

- **What the prompt states is settled.** It was checked before you were called, and a settled check re-decided produces a second answer to the same question. A file the prompt names and you still cannot read is reported, never assumed away.
- The build command arrives resolved in the prompt, and it is the only one you run — through the script line the prompt gives with it, never typed out. That line answers `BUILD=green` or `red` and keeps the build's own output in the file its `LOG=` names; on red it prints the last lines of it. Read further into that file only when those lines do not show the cause. A prompt that carries no command is reported, never filled in with a command of your own — a build nobody agreed to verifies nothing.
- Search the codebase for existing patterns before creating anything new. The existing test suite stays green, and no API breaks without a migration.

## 2. Attempt Limit

**At most 3 attempts per unit of work** — an attempt is one `fix → build/test` cycle. Still red after the third: stop there and report it with the approaches you tried. Never grind past the limit.

## 3. Surgical Changes

- Do not "improve" adjacent code, comments, or formatting, and do not refactor what is not broken.
- Dead code that is not yours is mentioned in the report, never deleted.
- Remove only the imports, variables, and functions your own changes left unused.

## 4. Before Returning

Run the verification of §1, plus any extra gate the assignment names. The run is green, or every remaining failure is named in the report together with the attempts behind it. There is no third outcome.

**Self-Check** — every item mandatory; the assignment and your stack may add their own:

- [ ] The final verification run is green, or the remaining red is reported with what I tried
- [ ] Every condition of satisfaction my assignment names has a test — I can name the test for each one
- [ ] No debug artifacts: debug printing, commented-out code
- [ ] No unused imports or variables left behind by my edits
- [ ] Code follows the project code style the assignment names
