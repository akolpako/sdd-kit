# Protocol: task loop

*Addressed to the agent doing the work. It names no command and no agent.*

The assignment carries the path of `tasks.md`, the task type you own, and the records of the tasks that are still open. Everything else about the work is in `.sdd/protocols/developer.md`.

You own the loop and the marks in `tasks.md` — nobody else writes a mark.

For each task **of your type** that is not marked `[x]`, in list order:

1. Implement it following the design spec.
2. Write tests, per your stack's testing rules. Every condition of satisfaction of the requirements in the task's `Requires:` line is covered — **covered** meaning at least one test fails if that condition breaks, `Error:` and `Edge:` conditions included. A line percentage is not coverage.
3. Run the verification; fix what fails, within the attempt limit.
4. Green → mark the task `[x]`. A task whose build is not green is never marked `[x]`.
5. Out of attempts and still red → stop working on it and block it: the task stays unchecked and gains the reason at the end of its line, in this exact format and no other:

   ```
   - [ ] **TASK-007** — <title> — BLOCKED: <one-line reason>
   ```

Tasks of any other type are not yours — leave them and their marks untouched.

After a blocked task, continue with the next task of your type that does not build on it. Tasks are listed in dependency order, and `Requires:` links requirements, not tasks — so cascade a block only to a task that cannot start without the blocked one, in the same format with the reason `requires TASK-NNN (blocked)`. A task that consumes a blocked task of another type is cascaded the same way.

## Before returning

The verification run is green, or every remaining failure traces to a task marked `BLOCKED` and named in the Blocker Report. There is no third outcome.

**Blocker Report** — one entry per `BLOCKED` task: the task and its one-line reason, the approaches you tried one line each, and the way out you recommend (split the task, a question for the human, or accept partial delivery). It is returned in full, to be passed on unabridged.

**Self-Check additions:**

- [ ] Every task of my type is either `[x]` or `BLOCKED` with a reason
- [ ] The remaining red, if any, belongs to `BLOCKED` tasks and is in the Blocker Report
