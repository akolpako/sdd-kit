# Protocol: requirements writing

*Addressed to the agent writing `new-requirements.md`. It names no command and no agent.*

How a feature description becomes implementation-ready requirements on this project. **What** is being specified arrives with the assignment; this is what happens to it once it has arrived.

## 1. Inputs

- `raw.md` — the feature description, and the only source of what was asked for.
- `requirements.md` — the existing requirements, the `REQ-###` counters, and which domains the project groups its requirements by.
- The architecture baseline, entered through the file the assignment names — architecture context.
- The `new-requirements.md` the assignment names — already on disk, holding the template it was scaffolded from. That is the structure to keep.

## 2. Scope and Conflicts

- Every point in `raw.md` ends up in one of two places: a requirement that covers it, or a line in `## Out of Scope` that excludes it.
- Capabilities nobody asked for are deferred, not designed in.
- Compare every new requirement against `requirements.md`. An overlap or a contradiction is resolved one of two ways, never silently: **refinement** — the existing entry is reworded in place and keeps its number; **replacement** — the existing entry gets the status `superseded by REQ-NNN` and the new requirement takes its own number.

## 3. Numbering

An id is `REQ-###`, or `REQ-<DOMAIN>-###` when the project groups its requirements — `REQ-ACC-003`. Each domain is a sequence of its own, with its own numbers and its own counter, and the ungrouped ids are one such sequence too. Which sequence this feature's requirements belong to is decided first, because it decides which number is the next free one.

### The domain

The domains in use are the `DOMAINS:` records of `.sdd/scripts/next-req.sh`, one per sequence, `-` standing for the ungrouped one. Read them before deciding:

- **The project groups nothing** — every record is `-`. Then this feature adds no domain: its requirements are ungrouped, like everything already in the file. Starting a group is a decision about the whole compilation, not about one feature.
- **One existing domain covers what this feature is about** — that is the domain, and no question is asked. A domain groups requirements by what they are about, never by which feature happened to write them: a feature touching accounts writes into `ACC` beside the accounts requirements that are already there.
- **The project groups its requirements and none of the domains fits, or two fit equally** — that is the human's to settle, asked as `.sdd/protocols/interview.md` fixes it: one question, carrying the recommended answer and the domains already in use. A new domain is a decision about how the compilation is organised, and it is never taken silently.

### The number

With the domain settled, the next free number comes from one read-only call:

```
.sdd/scripts/next-req.sh . <DOMAIN>     # REQ-<DOMAIN>-### — the domain's own sequence
.sdd/scripts/next-req.sh .              # REQ-### — the ungrouped sequence
```

`NEXT` is what it answers, and issuing numbers upward from it is what this protocol asks for. The `NEXT` the assignment hands over is that same answer for the ungrouped sequence, made by the gate before anything was spawned: with no domain chosen, it is the number to use and the call above is not needed.

Never a number counted off the list by eye, and never a number reused: a reused one silently rewrites the history of a requirement. An empty `NEXT` — the script's answer when the numbers it would hand out are already written into the specs, listed in its `TAKEN=` — is not one to guess under: stop and report it, with what the script said.

Declaring `### REQ-### — <short title>` in `new-requirements.md` is the whole of taking a number. `requirements.md` is not written here — that file is written by `/sdd-actualize` alone, once the feature is finished, and until then the declaration is what holds the number. A domain's counter is written there too, by the same command, including the first one of a domain this feature starts.

A `NEXT` that arrived is a number to use, whatever the compilation on disk looks like.

## 4. Requirements Generation

The structure of a requirement is the one the scaffolded `new-requirements.md` defines, in the hint comments it was copied with.

## 5. Edge Cases

Every edge case the feature carries is written down as a condition of satisfaction of the requirement it belongs to — or, when it is not a behaviour, as an `A-##` assumption or a line in `## Open Questions`.
