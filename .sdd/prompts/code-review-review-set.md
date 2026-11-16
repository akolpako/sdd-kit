# Assignment: review this set against these specs

Follow these protocols, in this order:

{{PROTOCOLS}}

FEATURE={{FEATURE}}

The review set of this run, resolved already:

BASE={{BASE}}
ROOT={{ROOT}}
DIFF={{DIFF}}

An empty `BASE` means no base branch was found: the set is the uncommitted
changes alone, and the review is partial and says so.

Untracked files, part of the same set:

{{SECTION:UNTRACKED}}

Tasks the implementation came back `blocked` on — code missing for these is not
a finding:

{{SECTION:BLOCKED}}

The build command of this project — the human's, resolved already. Tests are
run with it and with nothing else; where it reads `(none)`, no test is run and
the report says the tests were not run:

{{SECTION:BUILD}}

Specs of this run:

{{SECTION:SPEC_FILES}}

Your report goes into `{{REVIEW_PATH}}` — already on disk, holding the template,
with `reviewed`, `base` and `root` filled in. It is the one file you write.

Return: the summary the protocol asks for, once the report is in that file.
