---
name: sdd-next-story
description: "Scaffold a new feature: create its folder and raw.md, either from the template or from a Jira issue."
argument-hint: "<FeatureName | Jira issue key or URL>"
disable-model-invocation: true
---

# /sdd-next-story <FeatureName | Jira issue key or URL>

Creates the entry point of a feature: `_docs/<FeatureName>/raw.md`. The description is either filled in with the human, question by question, or downloaded from a Jira issue — the argument says which. Safe to re-run: an existing description is reported, never overwritten.

## Context

- **Reads:**
  - `.sdd/protocols/orchestration.md`
  - the output of `.sdd/scripts/gate.sh new`
  - `.sdd/templates/raw.md`, for the wording of the questions
- **Writes,** and nothing else:
  - `_docs/<FeatureName>/raw.md`
  - `_docs/<FeatureName>/attachments/`, on the Jira branch — what the issue description points at

## The argument

The mode is read off the argument; there is no flag to pass.

| The argument | Branch | The feature name | The Jira instance |
|---|---|---|---|
| a link containing `/browse/` | Jira | the part right of `/browse/` | the part left of `/browse/` |
| a bare issue key — letters, hyphen, digits, such as `ABC-12345` | Jira | the key | `JIRA_URL` |
| anything else | by hand | the argument | — |
| nothing | ask the human which of the two to create, and take the answer as the argument | | |

In the Jira branch the feature name **is** the issue key, used on disk exactly as Jira spells it: `_docs/ABC-12345/`.

## Process — a Jira issue

Every step is the orchestrator's own.

1. **Read the argument** into an issue key and, when it is a link, the instance it came from. The feature name is the key.

2. **Gate:** run `.sdd/scripts/gate.sh new ABC-12345`. The name, the existing folders and `raw.md` are all judged there, before anything is downloaded. `GATE=ok` creates.

3. **Create `raw.md`:** run `.sdd/scripts/spec-edit.sh scaffold feature ABC-12345`. It prints `RAW=` — the path the next step writes into.

4. **Download the issue:** run `.sdd/scripts/jira-fetch.sh <the argument, as the human typed it> --out <RAW>`. It writes the title, the link to the issue, the converted description and the two sections the flow reads by name, and downloads the attachments the description points at.

   This rewrites what step 3 created. To download an issue a second time the human deletes `raw.md` first.

5. **Verify:** run `.sdd/scripts/gate.sh new ABC-12345 --verify`.

6. **Report the next step:**
   - the path of the created file, the issue summary, and how many attachments were downloaded
   - anything in the script's `NOTES:` — an attachment that could not be fetched, an empty description, an attachment left in Jira
   - then: read `raw.md`, fill in `## Known constraints` and `## Out of scope`, and run `/sdd-specify ABC-12345`

A redirect, a rejected token or a missing issue is the human's call, not something to retry differently (`.sdd/AGENTS.md`).

## Process — a feature filled in by hand

Every step is the orchestrator's own.

1. **Gate:** run `.sdd/scripts/gate.sh new <FeatureName>`. The name, the existing folders and `raw.md` are all judged there. `GATE=ok` creates.

2. **Create `raw.md`:** run `.sdd/scripts/spec-edit.sh scaffold feature <FeatureName>`. It prints `RAW=` — the file every step below writes into.

3. **Offer to fill it in:** ask the human whether to fill the description in now or to edit the file themselves — two options to choose between.
   - Filling it in now: ask about `## Problem`, `## Users`, `## What the feature does`, `## Out of scope` — in that order, phrasing each question from that section's hint comment in the template. These four have nothing to choose between: each is asked as plain prose.
   - Each answer is written as it arrives: run `.sdd/scripts/spec-edit.sh section <RAW> <heading> <the human's words>` — their own words, unedited, never paraphrased into requirement language.
   - `## Known constraints` and `## Open questions` are not asked about.
   - A skipped answer is the same call with no text: the section keeps its hint.

4. **Verify:** run `.sdd/scripts/gate.sh new <FeatureName> --verify`.

5. **Report the next step:** the path of the created file, then the sections still holding only their hint comment — an empty section is not an error. Then: fill in or review `raw.md`, and run `/sdd-specify <FeatureName>`.
