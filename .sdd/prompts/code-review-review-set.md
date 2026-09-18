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

Specs of this run:

{{SECTION:SPEC_FILES}}

Return: your report in one piece, per the protocol.
