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

A requirement that rewords or replaces an entry `_docs/requirements.md` already
holds says so in one line directly under its heading — one of the two, never
both, and neither when the requirement is simply new:

### REQ-### — <short title>
- **Refines:** [REQ-NNN](../requirements.md#^req-nnn)
- **Description:** …

### REQ-### — <short title>
- **Supersedes:** [REQ-NNN](../requirements.md#^req-nnn)
- **Description:** …

`Refines` — the existing entry keeps its number and takes this wording.
`Supersedes` — the existing entry is retired and this requirement stands in its
place under its own number.
-->

## Risks

<!-- What the feature risks for the business and its users: one line per axis,
all five present. Each names the risk and its consequence, or closes the axis
with "no risk: <reason>" as a deliberate statement — an axis left out is not an
implicit "fine":

- Breaking changes: <the risk and its consequence> | no risk: <reason>
- External dependencies: …
- Data integrity: …
- Security: …
- Performance: …
-->

## Assumptions

<!-- Everything decided without confirmation, one line each — format in
`.sdd/protocols/spec-modes.md`. -->

## Open Questions

<!-- Points only the human can settle, one line each — see
`.sdd/protocols/spec-modes.md`. -->

## Out of Scope
