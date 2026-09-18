---
type: requirements
feature: <FeatureName>
status: draft
tags:
  - sdd/requirements
---

# Requirements — <FeatureName>

<!-- The `status` property above is `draft` or `ready` — the only record on
disk of whether the spec was reviewed. -->

## Overview

<!-- What this feature is for, in two or three sentences: the need it answers
and whose it is. Detail belongs in the requirements below, not here. -->

## Requirements

<!-- Each requirement follows this structure:

### REQ-### — <short title>
- **Description:** <what is required, from the business/user perspective> ^req-###
- **Conditions of satisfaction:**
  - <happy path: given <state>, when <action>, then <observable outcome>>
  - Error: when <invalid input or failure>, then <error response>
  - Edge: when <boundary case>, then <expected behaviour>

Requirements describe *what* and *why*, never *how*.
One behaviour per condition — "and" inside a condition means it should be split.
At least two conditions per requirement, one of them an `Error:` condition.

The `^req-###` at the end of the description line is the requirement's anchor,
the id in lower case — `REQ-ACC-003` gives `^req-acc-003`. It is what
`design.md` and `tasks.md` link to, so it is written even where nothing points
at it yet. A term this feature defines is marked ==like this== where it is
defined, once, and used plainly everywhere after.
-->

## Assumptions

<!-- Everything decided without confirmation, one line each — format in
`.sdd/protocols/spec-modes.md`. -->

## Open Questions

<!-- Points only the human can settle, one line each — see
`.sdd/protocols/spec-modes.md`. -->

## Out of Scope
