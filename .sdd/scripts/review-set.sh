#!/usr/bin/env bash
# Computes the review set of /sdd-code-review and prints it.
#
# Usage: review-set.sh [<base-ref>]
#
# Prints:
#   BASE=<ref>              the ref this work branched from; empty when none was found
#   ROOT=<commit>           what the diff is taken against; empty when nothing is committed yet
#   DIFF=<command>          the exact diff command of this review set
#   NOTES:                  what was decided about the base, when it was not
#                           simply used; empty otherwise
#   UNTRACKED:              one path per line, then an empty line
#   DIFFSTAT:               the overview of the diff
#
# The base is a fork point, not the first name on a preference list: of the
# integration branches that exist, the one whose merge-base with HEAD sits
# closest to HEAD. That diff carries every commit of this work and nobody
# else's. A branch is a candidate by name only — the remote-tracking ref of the
# current branch is the same line of work, and taking it would hide everything
# already pushed.
#
# Exit codes: 0 — printed; 1 — not a git repository; 2 — the base given on the
# command line shares no commit with HEAD.

set -uo pipefail
[[ -r "$(dirname "$0")/lib/log.sh" ]] && . "$(dirname "$0")/lib/log.sh"

git rev-parse --git-dir >/dev/null 2>&1 || exit 1

BASE="${1:-}"
ROOT=""
NOTES=""
HAS_HEAD=0
git rev-parse -q --verify HEAD >/dev/null 2>&1 && HAS_HEAD=1

if [[ -n "$BASE" ]]; then
  if [[ $HAS_HEAD -eq 1 ]]; then
    ROOT=$(git merge-base "$BASE" HEAD 2>/dev/null)
    if [[ -z "$ROOT" ]]; then
      printf 'ERROR=%s shares no commit with HEAD — the review set cannot be taken against it. Name a ref this work grew from, or leave the base out and let it be detected.\n' "$BASE" >&2
      exit 2
    fi
  else
    # A base was named and there is no commit to take it against. Keeping the
    # ref on BASE with ROOT empty is the one combination nothing downstream
    # reads correctly: the diff falls to the staged tree while the output still
    # claims a base, and the gate's "no base was detected" warning — the only
    # check that would say so — does not fire because BASE is not empty. So the
    # ref is dropped, and the note is what keeps that from looking silent.
    NOTES="The base '$BASE' was dropped: this repository has no commit yet, so there is nothing to take a diff against. The review set is the staged tree."
    BASE=""
  fi
elif [[ $HAS_HEAD -eq 1 ]]; then
  CUR=$(git branch --show-current)
  CANDIDATES="origin/main origin/master origin/develop origin/trunk main master develop trunk"
  ORIGIN_HEAD=$(git symbolic-ref -q --short refs/remotes/origin/HEAD)
  [[ -n "$ORIGIN_HEAD" ]] && CANDIDATES="$ORIGIN_HEAD $CANDIDATES"
  DEFAULT_BRANCH=$(git config --get init.defaultBranch)
  [[ -n "$DEFAULT_BRANCH" ]] && CANDIDATES="$CANDIDATES $DEFAULT_BRANCH origin/$DEFAULT_BRANCH"

  # A candidate whose merge-base is a descendant of the one held so far forked
  # later, so it is the nearer base. Equal merge-bases keep the ref found first:
  # the order above is the tie-breaker, and two runs pick the same ref.
  for b in $CANDIDATES; do
    [[ "$b" == "$CUR" ]] && continue
    git rev-parse -q --verify "$b" >/dev/null 2>&1 || continue
    mb=$(git merge-base "$b" HEAD 2>/dev/null) || continue
    [[ -z "$mb" ]] && continue
    if [[ -z "$ROOT" ]]; then
      BASE="$b"; ROOT="$mb"
    elif [[ "$mb" != "$ROOT" ]] && git merge-base --is-ancestor "$ROOT" "$mb" 2>/dev/null; then
      BASE="$b"; ROOT="$mb"
    fi
  done

  # No base was found: the committed history is nobody's to attribute, and the
  # review set is what the working tree holds.
  [[ -z "$ROOT" ]] && ROOT=HEAD
fi

# The set is the project's code. The specs are read as the standard to review
# against, and the engine — .sdd/ and .claude/ — is nobody's work here: it is
# installed, never committed, so on every project it stays untracked and would
# otherwise enter the set in full. .claude/ goes out whole, hand-written files
# included: this is a review of code, not of the agents' configuration.
#
# .github/ is deliberately not on this list, in either host mode. The engine's
# files there are covered by the .gitignore block the installer writes, and both
# halves of the set honour it; excluding the directory would only cost the
# project its own workflows, issue templates and dependabot.yml.
EXCLUDE=(':(exclude)_docs/' ':(exclude).sdd/' ':(exclude).claude/')
EXCLUDES="':(exclude)_docs/' ':(exclude).sdd/' ':(exclude).claude/'"

if [[ -n "$ROOT" ]]; then
  DIFF="git diff $ROOT -- . $EXCLUDES"
else
  DIFF="git diff --cached -- . $EXCLUDES"
fi

printf 'BASE=%s\n' "$BASE"
printf 'ROOT=%s\n' "$ROOT"
printf 'DIFF=%s\n' "$DIFF"

printf '\nNOTES:\n'
[[ -n "$NOTES" ]] && printf '%s\n' "$NOTES"

printf '\nUNTRACKED:\n'
git ls-files --others --exclude-standard -- . "${EXCLUDE[@]}"

printf '\nDIFFSTAT:\n'
if [[ -n "$ROOT" ]]; then
  git diff --stat "$ROOT" -- . "${EXCLUDE[@]}"
else
  git diff --cached --stat -- . "${EXCLUDE[@]}"
fi
