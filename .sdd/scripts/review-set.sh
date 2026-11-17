#!/usr/bin/env bash
# Computes the review set of /sdd-code-review and prints it.
#
# Usage: review-set.sh [<base-ref>] [--start=<file>]
#   --start=  the feature's starting point, `_docs/<Feature>/.implement-start`
#             as `spec-edit.sh start` wrote it (format: lib/format.sh). A file
#             that is not there is no starting point, and nothing else changes.
#
# Prints:
#   BASE=<ref>              the ref this work branched from; empty when none was
#                           found. The starting commit when there is one and no
#                           branch was found
#   ROOT=<commit>           what the diff is taken against; empty when nothing is committed yet
#   DIFF=<command>          the exact diff command of this review set
#   DIFF_FILE=<command>     the same diff for one file: the path goes last
#   NOTES:                  what was decided about the base, when it was not
#                           simply used; empty otherwise
#   UNTRACKED:              one path per line, then an empty line
#   PREEXISTING:            the paths of the set — in the diff or untracked —
#                           that were already changed or untracked at the
#                           starting point: they are reviewed, and may carry
#                           someone else's work. Empty without a starting point
#   FILES:                  one record per file the diff changes,
#                           `<added>|<deleted>|<path>` as `git diff --numstat
#                           --no-renames` counts them (`-|-|` for a binary); with
#                           UNTRACKED: they are the whole set
#   EXCLUDED:               the lock files the set changes or adds, one path per
#                           line — left out of DIFF, FILES: and UNTRACKED:
#
# A lock file is written by a package manager, thousands of lines nobody reads,
# and is named rather than diffed: by file name, the short list in LOCKS below.
# Generated code cannot be told by its name, so nothing else is left out.
#
# The base is a fork point, not the first name on a preference list: of the
# integration branches that exist, the one whose merge-base with HEAD sits
# closest to HEAD. That diff carries every commit of this work and nobody
# else's. A branch is a candidate by name only — the remote-tracking ref of the
# current branch is the same line of work, and taking it would hide everything
# already pushed.
#
# Nobody commits, so several features can share one working tree and one
# branch, and a fork point holds all of them. A starting point narrows the set
# to this feature: the diff is taken from the commit HEAD was on when its
# implementation began, and the files that were dirty already are named rather
# than left out — the feature may have gone on to change them. An explicit
# <base-ref> wins over it. A starting commit no longer in the history of HEAD —
# a rebase, a reset — is dropped with a note, and the base is detected as
# without one.
#
# Exit codes: 0 — printed; 1 — not a git repository, or lib/format.sh is
# missing; 2 — the base given on the command line shares no commit with HEAD.

set -uo pipefail
SDD_HERE="${0%/*}"; [[ "$SDD_HERE" == "$0" ]] && SDD_HERE="."
[[ -r "$SDD_HERE/lib/log.sh" ]] && . "$SDD_HERE/lib/log.sh"

[[ -r "$SDD_HERE/lib/format.sh" ]] || { printf 'ERROR=missing: %s/lib/format.sh\n' "$SDD_HERE" >&2; exit 1; }
. "$SDD_HERE/lib/format.sh"

git rev-parse --git-dir >/dev/null 2>&1 || exit 1

BASE=""; START_FILE=""
for arg in ${1+"$@"}; do
  case "$arg" in
    --start=*) START_FILE="${arg#--start=}" ;;
    *)         [[ -n "$BASE" ]] || BASE="$arg" ;;
  esac
done
EXPLICIT=0; [[ -n "$BASE" ]] && EXPLICIT=1
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

# The feature's own starting point, when one is on disk and no base was named.
START=""
if [[ $EXPLICIT -eq 0 && $HAS_HEAD -eq 1 && -n "$START_FILE" && -f "$START_FILE" ]]; then
  sc="$(md_start_commit "$START_FILE")"
  if [[ -n "$sc" ]] && git merge-base --is-ancestor "$sc" HEAD 2>/dev/null; then
    START="$sc"; ROOT="$sc"
    [[ -n "$BASE" ]] || BASE="$sc"
  elif [[ -n "$sc" ]]; then
    NOTES="The feature's starting point, commit $sc in $START_FILE, is no longer in the history of HEAD — a rebase or a reset moved the work. The review set is taken from the detected base instead, and may hold work that is not this feature's."
  fi
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
# `*.lock` is yarn, Gemfile, Cargo, composer, poetry and Pipfile at once; a file
# of another kind that ends so is still named under EXCLUDED:, never lost.
LOCKS="*.lock package-lock.json npm-shrinkwrap.json pnpm-lock.yaml go.sum gradle.lockfile"
LOCK_ONLY=()
set -f
for l in $LOCKS; do
  EXCLUDE+=(":(exclude,glob)**/$l")
  EXCLUDES="$EXCLUDES ':(exclude,glob)**/$l'"
  LOCK_ONLY+=(":(glob)**/$l")
done
set +f

if [[ -n "$ROOT" ]]; then
  DIFF_ARGS=("$ROOT")
  DIFF="git diff $ROOT -- . $EXCLUDES"
  DIFF_FILE="git diff $ROOT --"
else
  DIFF_ARGS=(--cached)
  DIFF="git diff --cached -- . $EXCLUDES"
  DIFF_FILE="git diff --cached --"
fi

printf 'BASE=%s\n' "$BASE"
printf 'ROOT=%s\n' "$ROOT"
printf 'DIFF=%s\n' "$DIFF"
printf 'DIFF_FILE=%s\n' "$DIFF_FILE"

printf '\nNOTES:\n'
[[ -n "$NOTES" ]] && printf '%s\n' "$NOTES"

UNTRACKED="$(git ls-files --others --exclude-standard -- . "${EXCLUDE[@]}")"
printf '\nUNTRACKED:\n'
[[ -n "$UNTRACKED" ]] && printf '%s\n' "$UNTRACKED"

# Renames are counted as a deletion and an addition: a numstat rename line
# spells both paths in one field, and a path is what every reader takes from it.
FILES="$(git diff --numstat --no-renames "${DIFF_ARGS[@]}" -- . "${EXCLUDE[@]}" | awk -F'\t' 'NF >= 3 { p = $3; for (i = 4; i <= NF; i++) p = p "\t" $i; print $1 "|" $2 "|" p }')"
PATHS=""
while IFS= read -r r; do
  [[ -n "$r" ]] || continue
  r="${r#*|}"; PATHS="$PATHS${r#*|}"$'\n'
done <<< "$FILES"
EXCLUDED="$( { git diff --name-only --no-renames "${DIFF_ARGS[@]}" -- "${LOCK_ONLY[@]}"; \
               git ls-files --others --exclude-standard -- "${LOCK_ONLY[@]}"; } | grep -v -e '^_docs/' -e '^\.sdd/' -e '^\.claude/')"

# Compared by the shell: the lists are paths, one per line, written by the same
# git commands on both sides.
printf '\nPREEXISTING:\n'
if [[ -n "$START" ]]; then
  SET=$'\n'"$PATHS"$'\n'"$UNTRACKED"$'\n'
  while IFS= read -r p; do
    [[ -n "$p" && "$SET" == *$'\n'"$p"$'\n'* ]] && printf '%s\n' "$p"
  done <<< "$(md_start_dirty "$START_FILE")"
fi

printf '\nFILES:\n'
[[ -n "$FILES" ]] && printf '%s\n' "$FILES"

printf '\nEXCLUDED:\n'
[[ -n "$EXCLUDED" ]] && printf '%s\n' "$EXCLUDED"
exit 0
