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

**Words go to a script on stdin, never on its command line.** Whatever a human or a role wrote — an answer, a finding, the wording of an entry, the sweep of markers — is passed as `-` with a quoted here-document, whose closing word appears nowhere in the text:

```
.sdd/scripts/spec-edit.sh answer <file> <line> - <<'SDD_TEXT'
EUR and `USD`
SDD_TEXT
```

Inside double quotes on a command line a backtick runs a command and a `$` expands, so the file gets something nobody wrote. `spawn-prompt.sh` takes such values the same way, as `KEY:` blocks after a `-` (its header comment shows the shape).

**`FEEDBACK=on` from the gate means the project keeps a log of what gets in the way of the engine.** What got in the way of this command — a script that failed or printed what it could not have, two engine files asking for different things, something this file left out, something it had read that was not needed — is written there, one record per fact, naming the engine file: `.sdd/scripts/feedback.sh <script|conflict|missing|unused|skill> --by=orchestrator --command=<command> --feature=<FeatureName> -`, the remark on stdin. A record changes nothing in the run, and with nothing to say nothing is written. Without the key, no record is written at all. The roles write their own; their remarks never pass through here.

**`.sdd/sdd.conf` is never read or edited by hand.** It may hold a token. The build answers go in through `.sdd/scripts/spec-edit.sh conf-set`, and every value a step needs comes out of a script.

**Before any overwrite, `.sdd/scripts/spec-edit.sh backup <FeatureName>`.** A non-zero exit is a stop: nothing is overwritten without its copy, and no role is spawned to write it.

**The command file never reaches the role** — what the role needs is in the spawn prompt, as the core instructions every role is loaded with say. `.sdd/scripts/spawn-prompt.sh` renders it from the gate's `SPAWN:` record into a file and prints `PASS=`: the spawn call carries that line and nothing else. What a script could not know goes into the file as an argument of `spawn-prompt.sh` — `KEY=value`, or a `KEY:` block on stdin — never as text added to the spawn call. The file is not opened, retyped or summarised here.
