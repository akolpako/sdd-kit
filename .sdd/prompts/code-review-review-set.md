# Assignment: review this set against these specs

Follow these protocols, in this order:

{{PROTOCOLS}}

FEATURE={{FEATURE}}

The review set of this run, resolved already:

BASE={{BASE}}
ROOT={{ROOT}}
DIFF={{DIFF}}
DIFF_FILE={{DIFF_FILE}}

`BASE=(none)` means no base branch was found: the set is the uncommitted
changes alone, and the review is partial and says so.

The files of the diff, `<added>|<deleted>|<path>` — `-|-|` is a binary file:

{{SECTION:FILES}}

Lock files of the set, left out of the diff and of every list here — the
report names them as not read:

{{SECTION:EXCLUDED}}

Untracked files, part of the same set:

{{SECTION:UNTRACKED}}

Files of the set that were already changed or untracked when this feature's
implementation started — reviewed like the rest, but part of what they hold may
be someone else's work, and a finding in one says so:

{{SECTION:PREEXISTING}}

Tasks the implementation came back `blocked` on — code missing for these is not
a finding:

{{SECTION:BLOCKED}}

The build command of this project — the human's, resolved already, one
`<stack>: <command>` line per answer. Tests are run with it and with nothing
else, as `.sdd/scripts/build-run.sh <stack>`; where it reads `(none)`, no test
is run and the report says the tests were not run:

{{SECTION:BUILD}}

Specs of this run:

{{SECTION:SPEC_FILES}}

Your report goes into `{{REVIEW_PATH}}` — already on disk, holding the template,
with `reviewed`, `base` and `root` filled in. It is the one file you write.

Return: the summary the protocol asks for, once the report is in that file.
