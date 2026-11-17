# Assignment: apply these findings in the frontend of {{FEATURE}}

Follow these protocols, in this order:

{{PROTOCOLS}}

Load only the installed skills that the findings below touch, as your
`## Skills` section matches them — not every one that matches the feature.

FEATURE={{FEATURE}}

Build command — the verification of this run, resolved already:

{{BUILD_FRONTEND}}

It is run as `.sdd/scripts/build-run.sh frontend`, and in no other way.

Files of this run:

{{SECTION:SPEC_FILES}}

The spec — opened only for a finding that names a requirement or the design,
a Spec Deviation:

{{SECTION:SPEC_REFERENCE}}

The triage the human settled, in their own words:

{{TRIAGE}}

The findings to fix, by their `F-##` numbers — each one is read in
`_docs/{{FOLDER}}/review.md`, with its location and recommendation:

{{FINDINGS}}

Fix these and nothing else. This is a list of findings, not a loop over tasks:
write no mark in `tasks.md`, and act on no finding outside the list. A `TODO`
marker is not yours either — the orchestrator wrote those before this run:
leave every `TODO Code Review:` line where it stands. A line number in the
report is the one the review saw; a marker written above it since moves it down.

A finding you decide not to fix is reported by its number with the reason.
Nothing drops out of the run in silence.

Return: what you fixed per `F-##`, what you did not and why, and the result of
the build command above.
