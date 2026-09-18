# Protocol: orchestration

*Addressed to the command. Names commands freely; names no agent.*

**Human review between every step is mandatory.** Nothing chains: a command names what follows and stops there. Every command is typed by the human, and none runs on the model's own initiative.

**No command names a tool** — what happens is the command's, how it happens is the environment's. Four terms are the whole vocabulary, exact in every command:

| Term | What it means |
|------|---------------|
| **Run `<script>`** | Execute it and read its output. Never re-derive what it printed. |
| **Spawn `<role>`** | Start that agent in a context of its own, with an assignment prompt. |
| **Ask the human** | One question at a time — with options where there are options, plain prose where there are none. The run waits. |
| **The orchestrator's own** | Done in the session running the command. No role is spawned for it. |

## What a script answers

| Exit | What it means |
|------|---------------|
| `0` | The output is the answer. |
| `1` | Wrong environment — not a git repository, no such folder. |
| `2` | The project is missing what the step needs. |

An `ERROR=` line is that script's answer to the step, like any other key.

## The gate

Every command but `/sdd-status` opens with `.sdd/scripts/gate.sh`. **Its output is the state of that run** — every later step reads it and re-derives nothing from the spec files.

| `GATE` | What happens |
|--------|--------------|
| `stop` | Relay every `STOP:` line and stop. |
| `ask`  | Put every `ASK:` line to the human. Nothing is written or spawned until the answer is in. |
| `done` | Report completion; no role is spawned. |
| `ok`   | Go on. |

**A verdict a command's file does not name does not occur there.**

`WARN:`, `ANOMALIES:` and `NOTES:` reach the human before the command's own output, whether or not they block, and are never put in kinder words.

A step's result is read the same way — `.sdd/scripts/gate.sh <command> <Feature> --verify`; `VERIFY=fail` relays every `FAIL:` line and stops. **Nothing is written by hand in place of what did not get written** — not a file, not a marker, not a task mark.

**Before any overwrite, `.sdd/scripts/spec-edit.sh backup`.** A non-zero exit is a stop: nothing is overwritten without its copy, and no role is spawned to write it.

**The command file never reaches the role** — what the role needs is in the spawn prompt (`.sdd/AGENTS.md`). `.sdd/scripts/spawn-prompt.sh` renders it from the gate's `SPAWN:` record; relay it word for word, adding only the `KEY=value` a script could not know and editing nothing inside.
