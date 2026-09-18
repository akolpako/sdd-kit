# Protocol: task breakdown

*Addressed to the agent writing `tasks.md`. It names no command and no agent.*

How a design becomes the task list an implementer works from. The structure of the file itself is the one already on disk at the path the assignment names.

1. Cut a large initiative into bounded slices, then decompose the design into atomic, implementable tasks, each with a `TASK-###` unique within the feature.
2. Link each task to one or more requirements.
3. Specify task type — `backend` or `frontend`, exactly one per task: one type, one owner, one `[x]`. Full-stack work is split into a backend task and a frontend task.
4. Include technical details sufficient for implementation.
5. Order tasks by dependency (backend APIs before frontend consumers). **The order of the list is the order of execution** — `tasks.md` has no dependency field, so a task that depends on another is placed after it.

**Atomicity test.** A task is atomic when it can be finished with the build left green and nothing broken. If it cannot, cut it further. Incomplete feature coverage at the end of a task is fine; incomplete or broken code is not.

| Work | Result |
|------|--------|
| Trivial — a config value, a single `if` | Fold into a neighbouring task, no task of its own |
| Simple — one class, 1–2 files | One task |
| Medium — 3–5 files | One or two tasks |
| Complex — architectural change, 5+ files, cross-cutting edits | Cut down to atomic tasks |

**Greenfield.** A project with no build file has nothing to implement into. Its first task is the bootstrap: create the project skeleton — build file, module layout, base configuration — for the stack named in the architecture baseline's technology stack, and leave a build that runs green on an empty project. Everything else depends on it. An empty technology stack means the bootstrap task cannot be written: say so and send the human to fill it in. A project that already has a build file needs no bootstrap task.
