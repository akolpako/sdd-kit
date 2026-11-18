#!/usr/bin/env bash
# The regression tests of the engine's scripts: runs gate.sh over every fixture
# under every command and again under every --verify, spawn-prompt.sh over every
# assignment those commands have, and spec-edit.sh over every write they make,
# and diffs the output — and for an edit, the state of the files — against the
# golden recorded next to the fixture.
#
# A fixture is a mini-project — the tree a command would find on disk. It is
# copied into a temporary directory before every run, so a test never writes
# into the fixture, and a git-backed fixture never sees the engine's own
# repository underneath it.
#
# Once per run, before the fixtures, it also checks the engine's own source
# files: every `name:` key matches the file — or, for a skill, the directory —
# it sits in. That check has no fixture and no golden; it is a property of the
# files themselves, and it runs whichever fixtures were selected.
#
# It then checks the log the scripts write: one record per run carrying the exit
# code, nothing at all under SDD_LOG=0, and one run id over a gate run and the
# scripts it fans out to. Every other case here would pass with the log broken —
# it is written and never read.
#
# The maven-lib-source, confluence and jira skills have suites of their own,
# `lib-source/run.sh`, `confluence/run.sh`, `confluence/publish.sh` and `confluence/search.sh`,
# `jira/run.sh` and `jira/publish.sh`, called from here as one job each: one
# builds a Maven repository, the others put a fake curl on PATH, and none is a shape a
# fixture of this file can hold. Run one alone while changing
# its script; run this one to be told whether it still passes.
#
# Last of the three, it calls lib/format.sh directly, on the values and the file
# shapes no fixture can produce: a blank `> Key:` line above a real one, a value
# carrying a backslash or an ampersand, and a compilation source spelled with a
# `|`. These have no golden either — they are properties of one function, and
# recording them as a tree would record the state the defect has nothing to do
# with.
#
# Usage: run.sh [--update] [--checks=<job,...>|none] [--no-fixtures] [--bash=<path>] [<fixture> ...]
#   no argument   every check and every fixture
#   <fixture>     the name of a directory under fixtures/
#   --checks=     only these property checks — the names of the queue below
#                 (`collisions`, `stacks`, `jira-publish`, …); `none` runs no
#                 check. A name the queue does not hold is an error.
#   --no-fixtures no fixture at all, only the checks
#   --bash=       the bash every script under test runs on — `--bash=/bin/bash`
#                 is macOS's 3.2, the floor the engine keeps to. The runner
#                 itself stays on the bash that started it: under 3.2 it would
#                 lose `wait -n` and run every job one after another.
#   --update      overwrite the golden files with what the scripts print now.
#                 A golden is a decision: run this only after reading the diff
#                 the plain run printed, never to make a red run green.
#   A narrowed run is for the edit at hand; the whole suite still runs before
#   a set of changes is done.
#
# The environment it reads:
#   SDD_TEST_JOBS    how many checks and fixtures run at once. Default: the
#                    machine's cores. 1 puts the suite back on one, which is
#                    what to reach for when a failure looks like it might be
#                    the harness rather than the engine.
#   SDD_TEST_LOGGED  which fixtures run with the scripts' log on — see
#                    LOGGED_FIXTURES below. `all` is every one of them.
#
# A fixture directory holds:
#   case              KEY=value: FEATURE=<name>, EXTRA=<gate's third argument>,
#                     GIT=yes|no (default no)
#   tree/             the project, copied as the working directory of the run
#   git-setup         optional, GIT=yes only: sourced in the project instead of
#                     the default single commit, for a fixture whose subject is
#                     the history — branches, remote-tracking refs, upstream
#   after-commit/     copied over the project after the commit — what a
#                     git-backed fixture leaves uncommitted
#   golden/<cmd>.txt  the expected gate output, one file per command
#   golden-prompt/<case>.txt
#                     the expected rendered prompt, one file per assignment of
#                     PROMPT_CASES below — every scope of the gate's SPAWN:
#                     table, plus the ways a render is refused
#   golden-verify/<case>.txt
#                     the expected `gate.sh … --verify` output, one file per
#                     case of VERIFY_CASES — every postcondition a command has,
#                     plus the ways a check is refused
#   golden-edit/<case>.txt
#                     the expected output of one spec-edit.sh op from
#                     EDIT_CASES, followed by what it changed on disk as a diff
#                     against the untouched fixture
#   golden-jira/<case>.txt
#                     the expected output of one jira-import.sh run from
#                     JIRA_CASES, followed by the paths it left under _docs/
#                     and the text of the file it wrote. Only a fixture that
#                     carries the sanitized Jira answer the case names runs
#                     these; every run goes through --from-file, so the suite
#                     never makes a request.
#
# The golden sets are read together: a section the gate stopped printing has to
# turn up in a prompt, or it was lost rather than moved.
#
# What is normalized before the diff: the temporary path the fixture ran in,
# and every 40-character commit id. Nothing else is allowed to vary between
# two runs of the same fixture — a value that does is a bug in the script
# under test, not something to normalize away.
#
# Exit codes: 0 — every case matched (or was written under --update);
#             1 — the environment is wrong; 2 — a case differs from its golden,
#             and the diff was printed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../.sdd/scripts"
GATE="$SCRIPTS/gate.sh"
RENDERER="$SCRIPTS/spawn-prompt.sh"
EDITOR_SH="$SCRIPTS/spec-edit.sh"
JIRA_SH="$SCRIPTS/jira-import.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
COMMANDS="init new specify review implement code-review code-fix actualize"

# One line per render: <case>|<command>|<scope>|<KEY=value;KEY=value>. `\n` in a
# value is a real newline — a multi-line value is what the block form of a
# placeholder exists for. The last four cases are refusals: no template for the
# scope, no value for a placeholder, a multi-line value where the template has
# the placeholder inline, and a base ref that shares no commit with HEAD.
PROMPT_CASES='init-baseline|init|baseline-from-codebase|
specify-requirements|specify|requirements|KEPT=none
specify-design-tasks|specify|design+tasks|KEPT=new-requirements.md
review-requirements|review|requirements|
review-design-tasks|review|design+tasks|
implement-backend|implement|backend|HELD=none
implement-frontend|implement|frontend|HELD=TASK-009
code-review-review-set|code-review|review-set|
code-fix-backend|code-fix|findings-backend|TRIAGE=Critical and Major fixed, the rest gets a marker.;FINDINGS=F-01\nF-02
code-fix-frontend|code-fix|findings-frontend|TRIAGE=Fix everything.;FINDINGS=F-03
actualize-baseline|actualize|baseline-from-feature|
refused-no-template|implement|no-such-scope|
refused-no-value|code-fix|findings-backend|TRIAGE=Fix everything.
refused-multiline-inline|implement|backend|HELD=none;FEATURE=Cart\nBasket
refused-alien-base|code-review|review-set|BASE=no-such-ref'

# One line per postcondition check: <case>|<command>|<option;option>. The last
# four are refusals: a scope that was not named, files that were not named, a
# file --files does not know, and a command that has no --verify at all.
VERIFY_CASES='verify-init|init|
verify-new|new|
verify-specify-all|specify|--files=new-requirements.md,design.md,tasks.md
verify-specify-one|specify|--files=design.md
verify-implement-backend|implement|--scope=backend
verify-implement-frontend|implement|--scope=frontend
verify-code-review|code-review|
verify-actualize|actualize|
refused-no-scope|implement|
refused-no-files|specify|
refused-unknown-file|specify|--files=raw.md
refused-no-verify|review|'

# One line per edit: <case>|<argument;argument;…> for spec-edit.sh, where `<F>`
# stands for the feature name of the fixture. Each case runs on its own copy of
# the project; the golden records what the script printed and what changed on
# disk.
EDIT_CASES='backup|backup;<F>
status-ready|status;<F>;ready;new-requirements.md;design.md;tasks.md
status-draft|status;<F>;draft;new-requirements.md
status-repeat|status;<F>;ready;new-requirements.md;new-requirements.md
status-no-line|status;<F>;ready;raw.md
verdict-stale|verdict-stale;<F>
scaffold-init|scaffold;init
scaffold-feature-new|scaffold;feature;Wishlist
scaffold-feature-existing|scaffold;feature;<F>
scaffold-spec-all|scaffold;spec;<F>;new-requirements.md;design.md;tasks.md
scaffold-spec-one|scaffold;spec;<F>;design.md
scaffold-spec-unknown-file|scaffold;spec;<F>;raw.md
scaffold-review|scaffold;review;<F>
scaffold-review-header|scaffold;review;<F>;main;deadbeef
marker-java|marker;src/main/java/com/example/CartService.java;3;The total ignores the discount.
marker-unknown-type|marker;web/package.json;2;No comment syntax here.
marker-past-end|marker;_docs/<F>/raw.md;9999;Nowhere near a line.
compile-entry-final|compile-entry;<F>;REQ-002;final
compile-entry-new|compile-entry;<F>;REQ-900;final;Saved carts. A shopper keeps a cart between sessions.
compile-entry-superseded|compile-entry;<F>;REQ-002;superseded-by:REQ-900
compile-entry-no-text|compile-entry;<F>;REQ-900;final
compile-entry-domained|compile-entry;<F>;REQ-ACC-900;final;Password reset. An account holder sets a new password over a mailed link.
compile-entry-refined|compile-entry;<F>;REQ-001;refine;Catalog listing. A shopper browses and filters the products on offer.
compile-entry-foreign-final|compile-entry;<F>;REQ-001;final;Catalog listing. A shopper browses and filters the products on offer.
section-text|section;_docs/<F>/raw.md;Problem;Shoppers lose the cart when the session drops.
section-heading-hashes|section;_docs/<F>/raw.md;## Problem;Shoppers lose the cart when the session drops.
section-empty|section;_docs/<F>/raw.md;Users
section-no-heading|section;_docs/<F>/raw.md;Nowhere'

# One line per import: <case>|<the fixture's Jira answer>|<argument;argument;…>
# for jira-import.sh|<VAR=value;VAR=value> put in its environment, where `<KEY>`
# stands for the feature name of the fixture — for this family that is the issue
# key. A case runs only in a fixture that carries the answer it names, and the
# runner adds `--from-file` itself: no case here can reach the network, and none
# may be written that could.
#
# The environment is built from nothing: HOME points at an empty directory, so
# ~/.config/sdd-kit/tokens.env is missing whatever the machine running the tests
# holds, and JIRA_URL and JIRA_TOKEN are unset unless the case sets them.
#
# What these pin is the import: the skill run through the wrapper, the two
# sections appended, nothing written on a stop. The request itself, the token
# and every HTTP answer are the jira skill's, and its own suite checks
# them over a fake curl — a --from-file run needs no token at all.
JIRA_CASES='key|issue.json|<KEY>;--out;_docs/<KEY>/raw.md|JIRA_URL=https://jira.example.com;JIRA_TOKEN=fixture-token
url|issue.json|https://jira.example.com/browse/<KEY>;--out;_docs/<KEY>/raw.md|JIRA_TOKEN=fixture-token
no-url|issue.json|<KEY>;--out;_docs/<KEY>/raw.md|JIRA_TOKEN=fixture-token
empty-description|issue-empty.json|<KEY>;--out;_docs/<KEY>/raw.md|JIRA_URL=https://jira.example.com;JIRA_TOKEN=fixture-token
mixed|issue-mixed.json|<KEY>;--out;_docs/<KEY>/raw.md|JIRA_URL=https://jira.example.com;JIRA_TOKEN=fixture-token
not-a-key|issue.json|Cart;--out;_docs/<KEY>/raw.md|JIRA_URL=https://jira.example.com'

[[ -x "$GATE" ]]      || { printf 'ERROR=not executable: %s\n' "$GATE" >&2; exit 1; }
[[ -x "$RENDERER" ]]  || { printf 'ERROR=not executable: %s\n' "$RENDERER" >&2; exit 1; }
[[ -x "$EDITOR_SH" ]] || { printf 'ERROR=not executable: %s\n' "$EDITOR_SH" >&2; exit 1; }
[[ -d "$FIXTURES" ]]  || { printf 'ERROR=no fixtures directory: %s\n' "$FIXTURES" >&2; exit 1; }

UPDATE=0
SELECTED=""
CHECKS=""
NO_FIXTURES=0
BASH_UNDER_TEST=""
while (( $# > 0 )); do
  case "$1" in
    --update) UPDATE=1 ;;
    --checks=*) CHECKS="${1#--checks=}"; [[ -n "$CHECKS" ]] || { printf 'ERROR=--checks= names nothing: a list of checks, or none\n' >&2; exit 1; } ;;
    --no-fixtures) NO_FIXTURES=1 ;;
    --bash=*) BASH_UNDER_TEST="${1#--bash=}"
              [[ -x "$BASH_UNDER_TEST" ]] || { printf 'ERROR=--bash= is not an executable: %s\n' "$BASH_UNDER_TEST" >&2; exit 1; } ;;
    -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'ERROR=unknown option: %s\n' "$1" >&2; exit 1 ;;
    *)  SELECTED="$SELECTED $1" ;;
  esac
  shift
done

# Every job — a property check or a fixture — gets a temporary root of its own
# under this one, so two of them running at the same time share no path. What
# the goldens see is unchanged: a job's own root is what `normalize` rewrites to
# `<tmp>`, so a case reads back the same way whether it ran alone or beside
# fourteen others.
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sdd-tests.XXXXXX")" || exit 1
# TMPDIR carries a trailing slash on macOS, and mktemp keeps the double slash it
# makes. A prompt now opens with the directory it was rendered in, which the
# shell reports collapsed, so a path normalized against the uncollapsed one
# comes back through the golden with the machine's name still on it.
TMP_ROOT="$(cd "$TMP_ROOT" && pwd)" || exit 1

# The scripts start with `#!/usr/bin/env bash`, so the first bash on PATH is
# the one they run on.
if [[ -n "$BASH_UNDER_TEST" ]]; then
  mkdir -p "$TMP_ROOT/bash-under-test" && ln -s "$BASH_UNDER_TEST" "$TMP_ROOT/bash-under-test/bash" || exit 1
  export PATH="$TMP_ROOT/bash-under-test:$PATH"
  printf 'scripts run on: %s\n' "$("$TMP_ROOT/bash-under-test/bash" -c 'printf %s "$BASH_VERSION"')"
fi
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/out" "$TMP_ROOT/res" "$TMP_ROOT/rc" "$TMP_ROOT/time" || exit 1

# git reads the machine's identity, its default branch and its global ignore
# file. A test that inherits those passes on one machine and fails on the next.
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_DATE="2026-01-01T00:00:00+0000"
export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"

# The temporary root of one job, and the environment that hangs off it. HOME is
# per job for the same reason the root is: the git identity is written into it,
# and a job must not be reading a file another job is still writing.
#
# The scripts log every run. Left to its default the log lands in the project
# the case runs in — `.sdd/log/` inside a fixture copy, where an untracked path
# is part of what a review set reports — and a run of this suite would write
# into the engine's own tree besides. Every case gets the job's own root.
job_env() {
  TMP="$TMP_ROOT/$1"
  mkdir -p "$TMP" || exit 1
  export HOME="$TMP/home"
  mkdir -p "$HOME" || exit 1
  cat > "$HOME/.gitconfig" <<'EOF'
[user]
	name = SDD Tests
	email = tests@sdd.invalid
[init]
	defaultBranch = main
[core]
	excludesfile = /dev/null
EOF
  export SDD_LOG_DIR="$TMP/log"
}

# A verdict, appended to the job's own result file rather than counted in a
# variable: a job runs in a subshell, and a number raised there dies with it.
# The parent adds the files up once every job has finished.
RESULTS="$TMP_ROOT/res/main"
: > "$RESULTS"

pass()    { printf 'P\n' >> "$RESULTS"; }
fail()    { printf 'F\n' >> "$RESULTS"; }
written() { printf 'W\n' >> "$RESULTS"; }

# The fixtures that run with the scripts' log on. The log wrapper re-runs every
# script as a child of itself — two bash startups, two temporary files and a
# handful of small commands per case — and that is the larger half of what a
# case costs. What it has to be checked against is that it changes no byte of
# stdout, stderr or the exit code, and that is a property of the wrapper: the
# two fixtures named here exercise every case family the suite has between them
# — every command, prompt, verify and edit case in the first, the Jira imports
# in the second — so a wrapper that corrupts any of them is caught. The rest run
# with it off. SDD_TEST_LOGGED=all puts it back on everywhere, which is the run
# to make after touching lib/log.sh.
LOGGED_FIXTURES="${SDD_TEST_LOGGED:-ready-half jira}"

# The output of one run, with everything machine-specific taken out: the
# temporary path, commit ids, the date a run happened on, the timestamp a backup
# folder is named after, and the mtimes diff prints in its file headers.
# Two dates, not one: a suite started late enough runs cases on either side of
# midnight, and the day a case stamped is the day it ran on rather than the day
# the suite started. Reading `date` per normalize call would be a process per
# case; the day after is one more pattern and no process at all. No fixture and
# no golden carries a date that is not already fixed, so the second pattern
# matches nothing on every run that does not cross over.
TODAY="$(date +%Y-%m-%d)"
TOMORROW="$(date -v+1d +%Y-%m-%d 2>/dev/null || date -d tomorrow +%Y-%m-%d 2>/dev/null || printf '%s' "$TODAY")"
normalize() {
  sed -e "s#$TMP#<tmp>#g" \
      -e 's/[0-9a-f]\{40\}/<sha>/g' \
      -e "s/$TODAY/<today>/g" \
      -e "s/$TOMORROW/<today>/g" \
      -e 's/[0-9]\{8\}-[0-9]\{6\}/<ts>/g' \
      -e 's/^\(--- .*\)	.*/\1/' \
      -e 's/^\(+++ .*\)	.*/\1/'
}

# What a run left behind, as the golden files record it: the output, the exit
# code, then whatever went to stderr.
record() {
  local out="$1" rc="$2" err="$3" actual="$4"
  : > "$actual"
  [[ -n "$out" ]] && printf '%s\n' "$out" | normalize >> "$actual"
  printf '### exit=%s\n' "$rc" >> "$actual"
  if [[ -s "$err" ]]; then
    printf '### stderr\n' >> "$actual"
    normalize < "$err" >> "$actual"
  fi
}

compare() {
  local fixture="$1" label="$2" golden="$3" actual="$4"

  if (( UPDATE )); then
    mkdir -p "$(dirname "$golden")"
    if [[ -f "$golden" ]] && diff -q "$golden" "$actual" >/dev/null; then
      pass
    else
      cat "$actual" > "$golden"
      written
      printf '  written  %s / %s\n' "$fixture" "$label"
    fi
    return 0
  fi

  if [[ ! -f "$golden" ]]; then
    fail
    printf '  MISSING  %s / %s — no golden file. Read the output, then record it with --update.\n' "$fixture" "$label"
    return 0
  fi

  if diff -q "$golden" "$actual" >/dev/null; then
    pass
  else
    fail
    printf '  FAILED   %s / %s\n' "$fixture" "$label"
    diff -u "$golden" "$actual" | sed 's/^/    /'
  fi
}

run_case() {
  local fixture="$1" cmd="$2" project="$3" feature="$4" extra="$5"
  local actual="$TMP/actual.txt" err="$TMP/err.txt" out rc

  if [[ "$cmd" == "init" ]]; then
    out="$(cd "$project" && "$GATE" init 2>"$err")"; rc=$?
  elif [[ "$cmd" == "code-review" ]]; then
    out="$(cd "$project" && "$GATE" "$cmd" "$feature" "$extra" 2>"$err")"; rc=$?
  else
    out="$(cd "$project" && "$GATE" "$cmd" "$feature" 2>"$err")"; rc=$?
  fi

  record "$out" "$rc" "$err" "$actual"
  compare "$fixture" "$cmd" "$FIXTURES/$fixture/golden/$cmd.txt" "$actual"
}

# One rendered prompt. The renderer runs the gate itself, so a fixture whose
# gate stops is a case too: what it prints then is the refusal, not a prompt.
run_prompt_case() {
  local fixture="$1" name="$2" cmd="$3" scope="$4" args="$5" project="$6" feature="$7"
  local actual="$TMP/actual.txt" err="$TMP/err.txt" out rc old_ifs arg
  local argv=()

  if [[ -n "$args" ]]; then
    old_ifs="$IFS"; IFS=';'
    for arg in $args; do argv+=("$(printf '%b' "$arg")"); done
    IFS="$old_ifs"
  fi

  if [[ "$cmd" == "init" ]]; then
    out="$(cd "$project" && "$RENDERER" init "$scope" ${argv[@]+"${argv[@]}"} --print 2>"$err")"; rc=$?
  else
    out="$(cd "$project" && "$RENDERER" "$cmd" "$feature" "$scope" ${argv[@]+"${argv[@]}"} --print 2>"$err")"; rc=$?
  fi

  record "$out" "$rc" "$err" "$actual"
  compare "$fixture" "prompt $name" "$FIXTURES/$fixture/golden-prompt/$name.txt" "$actual"
}

# One postcondition check. Nothing is written first: a fixture is the disk a
# step would have left behind, and the check either recognizes it or names why.
run_verify_case() {
  local fixture="$1" name="$2" cmd="$3" opts="$4" project="$5" feature="$6"
  local actual="$TMP/actual.txt" err="$TMP/err.txt" out rc old_ifs opt
  local argv=()

  if [[ -n "$opts" ]]; then
    old_ifs="$IFS"; IFS=';'
    for opt in $opts; do argv+=("$opt"); done
    IFS="$old_ifs"
  fi

  if [[ "$cmd" == "init" ]]; then
    out="$(cd "$project" && "$GATE" init --verify ${argv[@]+"${argv[@]}"} 2>"$err")"; rc=$?
  else
    out="$(cd "$project" && "$GATE" "$cmd" "$feature" --verify ${argv[@]+"${argv[@]}"} 2>"$err")"; rc=$?
  fi

  record "$out" "$rc" "$err" "$actual"
  compare "$fixture" "verify $name" "$FIXTURES/$fixture/golden-verify/$name.txt" "$actual"
}

# One edit, on a copy of its own: an op that writes has to be seen against the
# project it started from, and the next case must not inherit what it did.
run_edit_case() {
  local fixture="$1" name="$2" args="$3" project="$4" feature="$5"
  local work="$TMP/edit" actual="$TMP/actual.txt" err="$TMP/err.txt" out rc old_ifs arg
  local argv=()

  rm -rf "$work" && mkdir -p "$work" || exit 1
  cp -R "$project/." "$work/" || exit 1

  old_ifs="$IFS"; IFS=';'
  for arg in $args; do argv+=("${arg//<F>/$feature}"); done
  IFS="$old_ifs"

  out="$(cd "$work" && "$EDITOR_SH" ${argv[@]+"${argv[@]}"} 2>"$err")"; rc=$?

  record "$out" "$rc" "$err" "$actual"
  printf '### tree\n' >> "$actual"
  diff -ru -x .git "$project" "$work" 2>&1 | normalize >> "$actual"
  compare "$fixture" "edit $name" "$FIXTURES/$fixture/golden-edit/$name.txt" "$actual"
}

# One jira-import.sh run, over its own copy of the project. The golden holds what
# the script printed, then every path it left under _docs/, then the text of
# the file it was told to write — the last two together are what pins a run that
# must write nothing: the listing is empty and the file is not there.
run_jira_case() {
  local fixture="$1" name="$2" json="$3" args="$4" envs="$5" project="$6" feature="$7"
  local dir="$FIXTURES/$fixture" work="$TMP/jira-run" home="$TMP/jira-home"
  local actual="$TMP/actual.txt" err="$TMP/err.txt" out rc old_ifs arg kv out_rel i
  local argv=() envv=()

  [[ -f "$dir/$json" ]] || return 0

  rm -rf "$work" "$home" && mkdir -p "$work" "$home" || exit 1
  [[ -d "$project" ]] && { cp -R "$project/." "$work/" || exit 1; }

  old_ifs="$IFS"; IFS=';'
  for arg in $args; do argv+=("${arg//<KEY>/$feature}"); done
  for kv in $envs; do envv+=("$kv"); done
  IFS="$old_ifs"

  out_rel=""
  for (( i = 0; i < ${#argv[@]}; i++ )); do
    [[ "${argv[$i]}" == "--out" ]] && out_rel="${argv[$(( i + 1 ))]:-}"
  done

  # `env -u`, so a JIRA_TOKEN in the shell that started the tests cannot reach a
  # case that is about not having one. --from-file is added here rather than in
  # the case list: it is the harness's rule, not one case's argument.
  out="$(cd "$work" && env -u JIRA_URL -u JIRA_TOKEN "HOME=$home" \
        ${envv[@]+"${envv[@]}"} \
        "$JIRA_SH" ${argv[@]+"${argv[@]}"} --from-file "$dir/$json" 2>"$err")"; rc=$?

  record "$out" "$rc" "$err" "$actual"
  printf '### specs\n' >> "$actual"
  ( cd "$work" && find _docs -type f 2>/dev/null | LC_ALL=C sort ) >> "$actual"
  printf '### file %s\n' "$out_rel" >> "$actual"
  if [[ -f "$work/$out_rel" ]]; then
    normalize < "$work/$out_rel" >> "$actual"
  else
    printf 'not written\n' >> "$actual"
  fi
  compare "$fixture" "jira $name" "$FIXTURES/$fixture/golden-jira/$name.txt" "$actual"
}

# Every `name:` key in the engine's source files against the name the host
# reads it under: a command file and an agent file by their file name, a skill
# by its directory, which is what a SKILL.md is matched on. The two names have
# no mechanism keeping them equal — Claude Code reads the file name and ignores
# the key, Copilot reads the key — so a mismatch is silent on both hosts: the
# command leaves the `/` menu, or a spawn finds no role of that name.
frontmatter_name() {
  awk '
    NR == 1 && $0 != "---" { exit }
    /^---$/ { n++; if (n == 2) exit; next }
    n == 1 && /^name:[[:space:]]/ {
      sub(/^name:[[:space:]]*/, "")
      sub(/[[:space:]]+$/, "")
      gsub(/^["\047]|["\047]$/, "")
      print; exit
    }
  ' "$1"
}

check_names() {
  local root="$SCRIPT_DIR/.." f expected actual

  printf 'source names\n'
  for f in "$root"/.sdd/commands/*.md "$root"/.sdd/agents/*.md "$root"/.sdd/skills/*/SKILL.md; do
    [[ -f "$f" ]] || continue
    case "$f" in
      */SKILL.md) expected="$(basename "$(dirname "$f")")" ;;
      *)          expected="$(basename "$f" .md)" ;;
    esac
    actual="$(frontmatter_name "$f")"
    if [[ "$actual" == "$expected" ]]; then
      pass
    else
      fail
      printf '  FAILED   %s — name: %s, expected %s\n' \
        "${f#"$root"/}" "${actual:-<none>}" "$expected"
    fi
  done
}

# One check that has no fixture behind it: a label, 0 for a pass, and what to
# say when it is not one.
prop_check() {
  local group="$1" label="$2" ok="$3" why="$4"
  if (( ok == 0 )); then
    pass
  else
    fail
    printf '  FAILED   %s %s — %s\n' "$group" "$label" "$why"
  fi
}

# The log `.sdd/scripts/lib/log.sh` writes. It is written and never read, so
# every other case in this file would pass with it broken; these three are what
# notice. That it changes no output is not checked here — that is the whole
# suite, running with SDD_LOG_DIR set.
check_log() {
  local work="$TMP/log-check" next="$SCRIPTS/next-req.sh"
  local n ok ids names last nested

  printf 'log\n'
  rm -rf "$work" && mkdir -p "$work/tree" || exit 1

  # One record, carrying the code the run exited with. next-req.sh in a tree
  # with no compilation file exits 2, and a refusal is as ordinary an outcome
  # here as a success — the log carries either one the same way.
  ( cd "$work/tree" && SDD_LOG_DIR="$work/one" "$next" ) >/dev/null 2>&1
  n="$(grep -c '^== ' "$work/one/sdd.log" 2>/dev/null)"
  ok=0
  [[ "${n:-0}" == "1" ]] && grep -q '^== .*exit=2 .*next-req\.sh' "$work/one/sdd.log" || ok=1
  prop_check log "one record" "$ok" \
    "expected one record carrying exit=2 in $work/one/sdd.log, found ${n:-0}"

  # Off is off: no file, and no directory to hold one.
  ( cd "$work/tree" && SDD_LOG=0 SDD_LOG_DIR="$work/off" "$next" ) >/dev/null 2>&1
  ok=0
  [[ -e "$work/off" ]] && ok=1
  prop_check log "SDD_LOG=0" "$ok" "SDD_LOG=0 created $work/off"

  # Words handed over on stdin are in the record when `-` says the run reads
  # them, and only then: without `-` stdin is left alone, the record carries
  # no block, and the child still gets what was sent.
  ( cd "$work/tree" && printf 'nofile.txt|1|sdd-stdin-words\n' \
      | SDD_LOG_DIR="$work/in" "$SCRIPTS/spec-edit.sh" marker - ) >/dev/null 2>&1
  ( cd "$work/tree" && printf 'sdd-unread-words\n' \
      | SDD_LOG_DIR="$work/in" "$next" ) >/dev/null 2>&1
  ok=0
  grep -q '^stdin:$' "$work/in/sdd.log" 2>/dev/null \
    && grep -qx '| nofile.txt|1|sdd-stdin-words' "$work/in/sdd.log" \
    && ! grep -q 'sdd-unread-words' "$work/in/sdd.log" \
    && [[ "$(grep -c '^stdin:$' "$work/in/sdd.log")" == "1" ]] || ok=1
  prop_check log "stdin block" "$ok" \
    "expected one stdin: block, from the run given '-', in $work/in/sdd.log"

  # A gate run and the scripts it fans out to are one run: the same id, and the
  # nested records ahead of the gate's own, which is written after its child
  # exits.
  ( cd "$work/tree" && SDD_LOG_DIR="$work/gate" "$GATE" specify Cart ) >/dev/null 2>&1
  ids="$(awk '/^== / { print $3 }' "$work/gate/sdd.log" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
  names="$(awk '/^== / { print $6 }' "$work/gate/sdd.log" 2>/dev/null)"
  last="$(printf '%s\n' "$names" | sed -n '$p')"
  nested="$(printf '%s\n' "$names" | sed '$d' | grep -c 'feature-state\.sh')"
  ok=0
  [[ "${ids:-0}" == "1" && "$last" == "gate.sh" && "${nested:-0}" -ge 1 ]] || ok=1
  prop_check log "nested run" "$ok" \
    "expected one run id over nested records then gate.sh; ids=${ids:-0}, last=${last:-<none>}, nested=${nested:-0}"
}

# The reader and the writer of one `> Key: value` line, against values no
# fixture can hand them. spec-edit.sh only ever writes `ready`, `draft` and one
# fixed sentence, so the values that break the writer — a backslash, an
# ampersand — arrive from a review report and from nowhere a golden can reach.
# lib/format.sh is sourced and called directly, which is the only way to pass
# one in. The compilation record is here for the same reason: the source that
# breaks its field split is a feature folder spelled with a `|`, and no fixture
# is named that.
# shellcheck disable=SC1090
. "$SCRIPTS/lib/format.sh"

check_format() {
  local work="$TMP/format-check" ok n v val out rc

  printf 'format\n'
  rm -rf "$work" && mkdir -p "$work" || exit 1

  # A blank field line above a real one. The reader skips the blank; the writer
  # has to land on the same line, or it rewrites the one nothing reads and
  # leaves the old value standing where everything looks.
  printf '# Requirements — Cart\n\n> Status:\n> Status: ready\n\n## Requirements\n' > "$work/two.md"
  n="$(md_field_line "$work/two.md" Status)"
  ok=0; [[ "$n" == "4" ]] || ok=1
  prop_check format "blank line skipped" "$ok" \
    "md_field_line pointed at line ${n:-<none>}, and md_field reads line 4"

  md_field_set "$work/two.md" Status draft > "$work/two-out.md"
  v="$(md_status "$work/two-out.md")"
  n="$(grep -c '^> Status:' "$work/two-out.md")"
  out="$(sed -n '3p' "$work/two-out.md")"
  ok=0
  [[ "$v" == "draft" && "$n" == "2" && "$out" == '> Status:' ]] || ok=1
  prop_check format "written value reads back" "$ok" \
    "after writing 'draft': md_status reads '$v', line 3 is '$out' where it was blank, over $n '> Status:' line(s)"

  # A file whose only field line is blank has no line to rewrite. The write
  # fails rather than inserting one, and spec-edit.sh reports that to the human.
  printf '# Requirements — Cart\n\n> Status:\n' > "$work/blank.md"
  md_field_set "$work/blank.md" Status ready > "$work/blank-out.md"
  ok=$?
  [[ "$ok" -eq 1 ]] && ok=0 || ok=1
  prop_check format "blank-only fails the write" "$ok" \
    "md_field_set wrote into a file whose only '> Status:' line is blank"

  # ── Frontmatter ─────────────────────────────────────────────────
  # The templates write their fields as YAML properties. The blockquote form
  # stays readable, because a document written before them still carries it.
  printf -- '---\ntype: design\nfeature: Cart\nstatus: draft\ntags:\n  - sdd/design\n---\n\n# Design — Cart\n\nBody.\n' > "$work/fm.md"
  v="$(md_status "$work/fm.md")"
  out="$(md_field "$work/fm.md" type)"
  n="$(md_field_line "$work/fm.md" status)"
  ok=0; [[ "$v" == "draft" && "$out" == "design" && "$n" == "4" ]] || ok=1
  prop_check format "frontmatter field read" "$ok" \
    "md_status reads '$v', md_field type reads '$out', md_field_line says ${n:-<none>} where the property is on line 4"

  # A property is rewritten in place, and nothing else in the file moves.
  md_field_set "$work/fm.md" Status ready > "$work/fm-out.md"
  v="$(md_status "$work/fm-out.md")"
  n="$(grep -c '' "$work/fm-out.md")"
  out="$(sed -n '4p' "$work/fm-out.md")"
  ok=0; [[ "$v" == "ready" && "$n" == "11" && "$out" == "status: ready" ]] || ok=1
  prop_check format "frontmatter field written" "$ok" \
    "after writing 'ready': md_status reads '$v', line 4 is '$out', over $n line(s) where the file had 11"

  # Both forms in one file: the property is at the top and is what every reader
  # stops at, so a stale blockquote below cannot outrank it.
  printf -- '---\nstatus: ready\n---\n\n# Design — Cart\n\n> Status: draft\n' > "$work/both.md"
  v="$(md_status "$work/both.md")"
  ok=0; [[ "$v" == "ready" ]] || ok=1
  prop_check format "frontmatter outranks the blockquote" "$ok" \
    "md_status reads '$v' where the property says ready"

  # A quoted value comes back without its quotes: a verdict carrying a colon has
  # to be quoted or YAML reads the colon as the end of the key.
  printf -- '---\nverdict: "BLOCKED: no tests"\n---\n\n# Code Review — Cart\n' > "$work/q.md"
  out="$(md_field "$work/q.md" verdict)"
  ok=0; [[ "$out" == "BLOCKED: no tests" ]] || ok=1
  prop_check format "quoted value is unquoted" "$ok" \
    "md_field reads '$out'"

  # `---` opens a property block on the first line and nowhere else. Further
  # down it is a horizontal rule, and what follows it is body.
  printf -- '# Design — Cart\n\n---\n\nstatus: ready\n\n> Status: draft\n' > "$work/rule.md"
  v="$(md_status "$work/rule.md")"
  ok=0; [[ "$v" == "draft" ]] || ok=1
  prop_check format "a rule is not frontmatter" "$ok" \
    "md_status reads '$v' where the only field is the blockquote saying draft"

  # The scaffold writes the feature name and the status into the properties, so
  # a file whose only difference from its template is there has not been
  # written into. Comparing them would make every fresh scaffold read as filled.
  printf -- '---\ntype: design\nfeature: <FeatureName>\nstatus: draft\n---\n\n# Design — <FeatureName>\n\n<!-- hint -->\n' > "$work/tmpl.md"
  printf -- '---\ntype: design\nfeature: Cart\nstatus: ready\n---\n\n# Design — Cart\n\n<!-- hint -->\n' > "$work/copy.md"
  ok=0; md_untouched "$work/copy.md" "$work/tmpl.md" || ok=1
  prop_check format "frontmatter is outside the skeleton" "$ok" \
    "md_untouched called a scaffold written, over properties alone"

  printf -- '---\ntype: design\nfeature: Cart\nstatus: draft\n---\n\n# Design — Cart\n\n<!-- hint -->\n\nThe real design.\n' > "$work/written.md"
  ok=0; md_untouched "$work/written.md" "$work/tmpl.md" && ok=1
  prop_check format "a written body is not the skeleton" "$ok" \
    "md_untouched called a written file untouched"

  # A value is written as it was handed over. Under `awk -v` a backslash is an
  # escape: `\n` becomes a real newline and splits the line in two, and the half
  # carrying the value is no longer a field line at all.
  printf '# Code Review — Cart\n\n> Verdict: BLOCKED\n\n## Findings\n' > "$work/v.md"
  for val in 'a\nb' 'x & y' 'C:\temp\new' 'APPROVED WITH MINOR ISSUES'; do
    md_field_set "$work/v.md" Verdict "$val" > "$work/v-out.md"
    n="$(grep -c '' "$work/v-out.md")"
    out="$(md_field "$work/v-out.md" Verdict)"
    ok=0; [[ "$n" == "5" && "$out" == "$val" ]] || ok=1
    prop_check format "value written as handed over" "$ok" \
      "wrote '$val', read back '$out' over $n line(s) where the file had 5"
  done

  # The counter takes the same route, and its value lands in the replacement of
  # a sub(), where `&` stands for the whole match.
  printf '# Requirements Compilation\n\n<!-- Next free number: REQ-004 -->\n' > "$work/c.md"
  for val in 'REQ-1&2' 'REQ-1\n2'; do
    md_counter_set "$work/c.md" "$val" > "$work/c-out.md"
    n="$(grep -c '' "$work/c-out.md")"
    ok=0
    [[ "$n" == "3" ]] && grep -qF "Next free number: $val -->" "$work/c-out.md" || ok=1
    prop_check format "counter written as handed over" "$ok" \
      "wrote '$val' over $n line(s) where the file had 3, and the marker does not carry it"
  done

  # A compilation record is three fields split on `|`, and a source carrying one
  # used to shift every field after it. A feature name holding `|` is refused at
  # every entry point now — it never reaches a per-feature record at all.
  mkdir -p "$work/pipe/_docs/Ca|rt" || exit 1
  printf '# Requirements Compilation\n\n<!-- Next free number: REQ-002 -->\n\n## Requirements\n\n- **REQ-001** — Cart holds items. A shopper keeps picked items until checkout. *(Source: Ca|rt, draft)*\n' \
    > "$work/pipe/_docs/requirements.md"
  printf '# Requirements — Ca|rt\n\n> Status: ready\n\n## Requirements\n\n### REQ-001 — Cart holds items\n\nA shopper keeps picked items until checkout.\n' \
    > "$work/pipe/_docs/Ca|rt/new-requirements.md"
  out="$(cd "$work/pipe" && "$SCRIPTS/feature-state.sh" 'Ca|rt' 2>&1)"; rc=$?
  ok=0
  [[ $rc -eq 2 && "$out" == *"is not a feature name — it holds '|'"* ]] || ok=1
  prop_check format "a name holding | is refused" "$ok" "exit $rc: $out"
  ok=0
  printf '%s\n' "$out" | grep -q 'name the source' && ok=1
  prop_check format "no drift against its own folder" "$ok" \
    "the folder 'Ca|rt' was reported as drifting from the source it wrote itself"

  # An untouched template. Every check the engine had — `-s` in scaffold and
  # `[^[:space:]]` in verify_init — passes a freshly copied template, so a setup
  # interrupted after the copy reads as a finished one and is skipped ever after.
  # These say what distinguishes the copy from a file somebody wrote into.
  local t tmpl
  for t in "$SCRIPT_DIR"/../.sdd/templates/*.md; do
    cp "$t" "$work/fresh.md" || exit 1
    ok=0; md_untouched "$work/fresh.md" "$t" || ok=1
    prop_check format "fresh $(basename "$t") is untouched" "$ok" \
      "a byte-for-byte copy of the template read as written into"
  done

  # The title is the feature's name, not content: `scaffold feature` writes it
  # in, and the file it leaves has still been written into by nobody.
  tmpl="$SCRIPT_DIR/../.sdd/templates/new-requirements.md"
  sed '1s|<FeatureName>|Cart|' "$tmpl" > "$work/named.md" || exit 1
  ok=0; md_untouched "$work/named.md" "$tmpl" || ok=1
  prop_check format "named title is untouched" "$ok" \
    "a template whose only edit is the feature name in its H1 read as written into"

  # The hint comments are the writer's business — `code-style.md` keeps its
  # markers, another file may drop the hint it just answered. Neither move is
  # what the test reads, so neither one flips the answer on its own.
  md_uncomment "$tmpl" > "$work/stripped.md" || exit 1
  ok=0; md_untouched "$work/stripped.md" "$tmpl" || ok=1
  prop_check format "hints removed, nothing written" "$ok" \
    "a template with every hint comment cut out and no text added read as written into"

  # And one line of its own is the whole difference.
  cp "$tmpl" "$work/filled.md" || exit 1
  printf 'A shopper keeps picked items until checkout.\n' >> "$work/filled.md"
  ok=0; md_untouched "$work/filled.md" "$tmpl" && ok=1
  prop_check format "one written line is enough" "$ok" \
    "a template carrying a line of prose outside its comments read as untouched"

  # Absent is not untouched: the caller that asked knows the difference, and a
  # missing template is not an answer about the file either.
  ok=0; md_untouched "$work/gone.md" "$tmpl" && ok=1
  prop_check format "absent is not untouched" "$ok" \
    "a file that is not on disk read as an untouched template"
  ok=0; md_untouched "$work/fresh.md" "$work/no-template.md" && ok=1
  prop_check format "no template is not an answer" "$ok" \
    "a template that is not on disk read as matching the file"

  # Whether a feature was promoted as it declares: one reader for the stage and
  # for --verify. A replacement whose target has no entry is not promoted.
  cat > "$work/comp.md" <<'SDD_T'
## Requirements

- **REQ-001** — Old. *(Source: Cart, superseded by REQ-004)*
- **REQ-002** — Other. *(Source: Promo, refined by cart)*
- **REQ-003** — Mine. *(Source: Cart)*
- **REQ-004** — Replacement. *(Source: Cart)*
- **REQ-006** — Foreign. *(Source: Promo)*
- **REQ-007** — Replacement of nothing. *(Source: Cart)*
SDD_T
  cat > "$work/decl.md" <<'SDD_T'
## Requirements

### REQ-002 — Reworded
**Refines:** REQ-002
### REQ-003 — Mine
### REQ-004 — Replacement
**Supersedes:** REQ-001
### REQ-005 — Never written
### REQ-006 — Taken
### REQ-007 — Replacement of nothing
**Supersedes:** REQ-009
SDD_T
  out="$(md_unpromoted "$work/comp.md" "$work/decl.md" Cart | tr '\n' ' ')"
  ok=0; [[ "$out" == "REQ-005|missing| REQ-006|foreign|Promo REQ-007|no-target|REQ-009 " ]] || ok=1
  prop_check format "md_unpromoted names what is not there as declared" "$ok" "printed: $out"
}

# The build command, by the shape of the project. Which keys `.sdd/sdd.conf`
# has to carry follows from which stacks the build files say the project has,
# and both halves of that — what `build-command.sh` resolves, and what `gate.sh`
# asks for when it is not there — are properties of a tree, not of a feature.
# Four shapes against answered, half-answered and unanswered is ten trees, and
# no fixture would be exercising anything else in any of them.
# The shape of a feature name, over the names no fixture is built around. Two
# are accepted in silence — a PascalCase name a human chose, and a Jira issue
# key, which carries a hyphen and is never PascalCase — and everything else is
# a warning the human is meant to read. A fixture records one name; this is the
# boundary between the two shapes and the rest, which is what the import moved.
check_feature_name() {
  local work="$TMP/name-check" out warn ok name want

  printf 'feature name\n'
  rm -rf "$work" && mkdir -p "$work" || exit 1

  # <name>|warn or quiet
  local cases='Cart|quiet
CartService|quiet
ABC-12345|quiet
A1-9|quiet
cart|warn
cart_service|warn
Cart-Service|warn
ABC-12345x|warn'

  while IFS='|' read -r name want; do
    [[ -n "$name" ]] || continue
    out="$(cd "$work" && "$GATE" new "$name" 2>&1)"
    warn="$(printf '%s\n' "$out" | grep 'neither PascalCase nor a Jira issue key')"
    ok=0
    if [[ "$want" == "quiet" ]]; then
      [[ -z "$warn" ]] || ok=1
    else
      [[ -n "$warn" ]] || ok=1
    fi
    prop_check name "$name is $want" "$ok" \
      "WARN: ${warn:-<none>}"
  done <<EOF
$cases
EOF
}

# A name that is not a path segment is refused wherever a feature is named, so no
# write lands outside _docs/<name>/.
check_name_everywhere() {
  local work="$TMP/name-everywhere" out rc ok name
  printf 'name everywhere\n'
  rm -rf "$work" && mkdir -p "$work" && cp -R "$FIXTURES/two-stacks/tree/." "$work/" || exit 1
  ok=0
  for name in '../web' 'Cart/' '.hidden'; do
    ( cd "$work" && "$EDITOR_SH" scaffold spec "$name" tasks.md ) >/dev/null 2>&1; rc=$?; [[ $rc -eq 2 ]] || ok=1
    ( cd "$work" && "$EDITOR_SH" scaffold feature "$name" ) >/dev/null 2>&1; rc=$?; [[ $rc -eq 2 ]] || ok=1
    ( cd "$work" && "$GATE" implement "$name" ) >/dev/null 2>&1; rc=$?; [[ $rc -eq 1 ]] || ok=1
    ( cd "$work" && "$SCRIPTS/feature-state.sh" "$name" ) >/dev/null 2>&1; rc=$?; [[ $rc -eq 2 ]] || ok=1
  done
  [[ -e "$work/web/tasks.md" ]] && ok=1
  out="$(cd "$work" && "$GATE" implement cart 2>&1)"
  printf '%s\n' "$out" | grep -q '^FOLDER=Cart$' || ok=1
  prop_check name "a name that is not a path segment is refused everywhere" "$ok" "$(printf '%s' "$out" | head -3 | tr '\n' '~')"
}

check_build() {
  local work="$TMP/build-check" bc="$SCRIPTS/build-command.sh"
  local out ok

  printf 'build command\n'
  rm -rf "$work" || exit 1

  # <name>|<build files, space separated>|<sdd.conf lines, ; separated>|
  # <expected ROOT>|<expected BACKEND>|<expected FRONTEND>|<expected SOURCE>|
  # <the SDD_BUILD_* keys the gate has to ask for, space separated>
  local cases='backend-answered|pom.xml|SDD_BUILD_ROOT=mvn -q verify|mvn -q verify|mvn -q verify|mvn -q verify|config|
backend-stack-key|pom.xml|SDD_BUILD_BACKEND=mvn -q verify|mvn -q verify|mvn -q verify||config|
backend-missing|pom.xml|||||detected|SDD_BUILD_BACKEND
frontend-answered|package.json|SDD_BUILD_ROOT=npm test|npm test|npm test|npm test|config|
frontend-missing|package.json|||||detected|SDD_BUILD_FRONTEND
two-answered|backend/pom.xml frontend/package.json|SDD_BUILD_BACKEND=cd backend && mvn verify;SDD_BUILD_FRONTEND=cd frontend && npm test||cd backend && mvn verify|cd frontend && npm test|config|
two-root-only|backend/pom.xml frontend/package.json|SDD_BUILD_ROOT=make all|make all|||config|SDD_BUILD_BACKEND SDD_BUILD_FRONTEND
two-half|backend/pom.xml frontend/package.json|SDD_BUILD_BACKEND=cd backend && mvn verify||cd backend && mvn verify||config|SDD_BUILD_FRONTEND
no-stack-answered|Makefile|SDD_BUILD_ROOT=make verify|make verify|make verify|make verify|config|
no-stack-missing|Makefile|||||none|SDD_BUILD_ROOT
quote-inside|pom.xml|SDD_BUILD_ROOT=mvn verify -Dgroups="fast"|mvn verify -Dgroups="fast"|mvn verify -Dgroups="fast"|mvn verify -Dgroups="fast"|config|
quote-around|pom.xml|SDD_BUILD_ROOT="mvn -q verify"|mvn -q verify|mvn -q verify|mvn -q verify|config|'

  local name files lines want_root want_be want_fe want_source want_ask
  local dir f line key old_ifs
  local got_root got_be got_fe got_source n_ask want_n
  while IFS='|' read -r name files lines want_root want_be want_fe want_source want_ask; do
    [[ -n "$name" ]] || continue
    dir="$work/$name"
    mkdir -p "$dir/.sdd" || exit 1
    for f in $files; do
      mkdir -p "$dir/$(dirname "$f")" && : > "$dir/$f" || exit 1
    done
    if [[ -n "$lines" ]]; then
      old_ifs="$IFS"; IFS=';'
      for line in $lines; do printf '%s\n' "$line" >> "$dir/.sdd/sdd.conf"; done
      IFS="$old_ifs"
    fi

    out="$("$bc" "$dir" 2>&1)"
    got_source="$(printf '%s\n' "$out" | sed -n 's/^SOURCE=//p')"
    got_root="$(printf '%s\n' "$out" | sed -n 's/^ROOT=//p')"
    got_be="$(printf '%s\n' "$out" | sed -n 's/^BACKEND=//p')"
    got_fe="$(printf '%s\n' "$out" | sed -n 's/^FRONTEND=//p')"
    ok=0
    [[ "$got_source" == "$want_source" && "$got_root" == "$want_root" &&
       "$got_be" == "$want_be" && "$got_fe" == "$want_fe" ]] || ok=1
    prop_check build "$name resolves" "$ok" \
      "SOURCE=$got_source ROOT=$got_root BACKEND=$got_be FRONTEND=$got_fe, expected SOURCE=$want_source ROOT=$want_root BACKEND=$want_be FRONTEND=$want_fe"

    # And the verdict over the same tree: a shape whose answer is missing is one
    # ASK: naming the key it is missing, and a shape that has its answers asks
    # nothing about the build at all. The gate runs here as code-fix, because
    # /sdd-implement needs a feature and the ASK: section is printed whatever
    # else the gate stopped on.
    out="$(cd "$dir" && "$GATE" code-fix Nothing 2>&1)"
    n_ask="$(printf '%s\n' "$out" | sed -n '/^ASK:$/,/^WARN:$/p' | grep -c 'SDD_BUILD_' || true)"
    want_n=0; ok=0
    for key in $want_ask; do
      want_n=$(( want_n + 1 ))
      printf '%s\n' "$out" | grep -q "holds no $key," || ok=1
    done
    [[ "$n_ask" == "$want_n" ]] || ok=1
    prop_check build "$name asks" "$ok" \
      "expected $want_n build ASK: line(s) naming ${want_ask:-nothing}, found $n_ask"
  done <<EOF
$cases
EOF

  # build-run.sh: the verdict comes back, the output stays in the log.
  local br="$SCRIPTS/build-run.sh" rc
  rm -rf "$work" && mkdir -p "$work/.sdd" || exit 1
  printf '<project/>\n' > "$work/pom.xml"
  printf 'SDD_BUILD_ROOT=echo quiet-line\n' > "$work/.sdd/sdd.conf"
  out="$(cd "$work" && "$br" root 2>&1)"; rc=$?
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^BUILD=green$' || ok=1
  printf '%s\n' "$out" | grep -qx 'quiet-line' && ok=1
  grep -qx 'quiet-line' "$work/.sdd/build/root.log" || ok=1
  prop_check build "a green build answers green and keeps its output in the log" "$ok" "exit $rc: $(printf '%s' "$out" | tr '\n' '~')"

  printf 'SDD_BUILD_BACKEND=echo first; echo broke >&2; exit 3\n' > "$work/.sdd/sdd.conf"
  out="$(cd "$work" && "$br" backend 2>&1)"; rc=$?
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^BUILD=red$' || ok=1
  printf '%s\n' "$out" | grep -q '^EXIT=3$' || ok=1
  [[ "$(printf '%s\n' "$out" | sed -n '/^TAIL:$/,$p' | tr '\n' '~')" == 'TAIL:~first~broke~' ]] || ok=1
  prop_check build "a red build answers red with the tail" "$ok" "exit $rc: $(printf '%s' "$out" | tr '\n' '~')"

  out="$(cd "$work" && "$br" frontend 2>&1)"; rc=$?
  ok=0; [[ $rc -eq 2 && "$out" == *"no build command for frontend"* ]] || ok=1
  [[ -f "$work/.sdd/build/frontend.log" ]] && ok=1
  prop_check build "no command is a stop, never a guess" "$ok" "exit $rc: $out"
}

# What `/sdd-init` left behind, over the one state no fixture can hold: the
# project files as the scaffold copied them, with the analysis never written
# in. It is a tree, not a feature — the scaffold runs on brownfield now, so a
# run cut between the copy and the write leaves exactly this, and every check
# the gate had before passed it. A fixture would record the whole project
# around a difference that is a few files deep.
#
# The architecture baseline is checked at its entry point and no deeper, so
# what these cases pin down is which entry point the gate resolves to — the
# generated index, the single file, neither, or both at once.
check_init_verify() {
  local work="$TMP/init-verify" tmpl="$SCRIPT_DIR/../.sdd/templates"
  local out rc ok n

  printf 'init verify\n'
  rm -rf "$work" || exit 1

  # The scaffold as it stands: `code-style.md` is written from the codebase and
  # fails untouched; `requirements.md` does not — project-baseline.md has it
  # staying the template, because requirements are not derived from code — and
  # the architecture baseline passes on its index alone, because which sections
  # a project keeps is the project's answer and no file test's.
  mkdir -p "$work/fresh" || exit 1
  "$EDITOR_SH" scaffold init --root "$work/fresh" > /dev/null || exit 1
  out="$(cd "$work/fresh" && "$GATE" init --verify 2>&1)"; rc=$?
  n="$(printf '%s\n' "$out" | grep -c 'nothing but the template' || true)"
  ok=0
  [[ "$rc" == "2" && "$n" == "1" ]] || ok=1
  printf '%s\n' "$out" | grep -q 'code-style.md holds nothing but the template' || ok=1
  printf '%s\n' "$out" | grep -q 'requirements.md holds nothing but' && ok=1
  printf '%s\n' "$out" | grep -q 'architecture' && ok=1
  prop_check "init verify" "an untouched template fails" "$ok" \
    "exit=$rc over $n untouched-template line(s), where exit=2 over code-style.md alone is the answer"

  # And the setup that finished: code-style carries an answer, the compilation
  # is still the template it is meant to be, the index is on disk.
  mkdir -p "$work/written" || exit 1
  "$EDITOR_SH" scaffold init --root "$work/written" > /dev/null || exit 1
  printf '\nThe project is a Spring service behind one gateway.\n' \
    >> "$work/written/_docs/code-style.md"
  out="$(cd "$work/written" && "$GATE" init --verify 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] && printf '%s\n' "$out" | grep -q '^VERIFY=ok$' || ok=1
  prop_check "init verify" "a written file passes" "$ok" \
    "exit=$rc, where a setup that wrote into code-style.md and left the compilation as the template verifies"

  # The sections a project deleted are not a failure: the set is the project's
  # to choose, and the index says which one it chose.
  mkdir -p "$work/pruned" || exit 1
  "$EDITOR_SH" scaffold init --root "$work/pruned" > /dev/null || exit 1
  printf '\nThe project is a Spring service behind one gateway.\n' \
    >> "$work/pruned/_docs/code-style.md"
  rm -f "$work/pruned/_docs/architecture/"0*.md || exit 1
  printf '# Ours\n\nOne module, no API.\n' > "$work/pruned/_docs/architecture/90-ours.md"
  "$EDITOR_SH" arch-index --root "$work/pruned" > /dev/null || exit 1
  out="$(cd "$work/pruned" && "$GATE" init --verify 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] && printf '%s\n' "$out" | grep -q '^VERIFY=ok$' || ok=1
  prop_check "init verify" "a pruned section set passes" "$ok" \
    "exit=$rc, where a project that deleted the sections it has nothing to say about and added one of its own verifies"

  # The other shape of the same baseline: one file, no index, and nothing
  # asking for a folder that this project does not have.
  mkdir -p "$work/mono" || exit 1
  "$EDITOR_SH" scaffold init --mono --root "$work/mono" > /dev/null || exit 1
  printf '\nThe project is a Spring service behind one gateway.\n' \
    >> "$work/mono/_docs/code-style.md"
  out="$(cd "$work/mono" && "$GATE" init --verify 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] && printf '%s\n' "$out" | grep -q '^VERIFY=ok$' || ok=1
  prop_check "init verify" "the single-file shape passes" "$ok" \
    "exit=$rc, where a project whose architecture is _docs/architecture.md alone verifies"

  # Both shapes at once is the one state no reader resolves, and it is named
  # as that rather than as a missing file.
  mkdir -p "$work/both" || exit 1
  "$EDITOR_SH" scaffold init --root "$work/both" > /dev/null || exit 1
  cp "$tmpl/architecture.md" "$work/both/_docs/architecture.md" || exit 1
  out="$(cd "$work/both" && "$GATE" init --verify 2>&1)"; rc=$?
  n="$(printf '%s\n' "$out" | sed -n '/^FAIL:$/,$p' | grep -c 'both on disk' || true)"
  ok=0
  [[ "$rc" == "2" && "$n" == "1" ]] || ok=1
  prop_check "init verify" "two shapes at once is a failure" "$ok" \
    "exit=$rc over $n line(s) about both shapes on disk, where one is the answer"

  # A baseline that is not there is absent, not untouched: it was already
  # reported once, and reporting it twice would name a state the disk is not in.
  mkdir -p "$work/absent/_docs" || exit 1
  cp "$tmpl/requirements.md" "$work/absent/_docs/" || exit 1
  printf '# Code Style\n\nTabs, and no line over 100.\n' > "$work/absent/_docs/code-style.md"
  out="$(cd "$work/absent" && "$GATE" init --verify 2>&1)"; rc=$?
  n="$(printf '%s\n' "$out" | sed -n '/^FAIL:$/,$p' | grep -c 'architecture' || true)"
  ok=0
  [[ "$rc" == "2" && "$n" == "1" ]] || ok=1
  printf '%s\n' "$out" | grep -q 'architecture.index.md is not on disk' || ok=1
  prop_check "init verify" "absent is reported once" "$ok" \
    "exit=$rc over $n line(s) naming the architecture baseline, where one 'is not on disk' line is the answer"
}

# The same state one command further on: the spec files and the report as their
# scaffold copied them, with nobody having written into them. `/sdd-specify`
# and `/sdd-code-review` scaffold before they write, so a run cut off in between
# leaves a template carrying `> Status: draft` or a `> Verdict:` line — which is
# every field the postcondition checks read. No fixture can hold this either:
# it is one file inside a feature a golden would carry whole.
check_spec_verify() {
  local work="$TMP/spec-verify" tmpl="$SCRIPT_DIR/../.sdd/templates"
  local out rc ok n f

  printf 'spec verify\n'
  rm -rf "$work" || exit 1

  # Three scaffolded spec files: each one is named, once.
  mkdir -p "$work/fresh/_docs/Cart" || exit 1
  printf '# Raw — Cart\n\nA shopper keeps picked items until checkout.\n' \
    > "$work/fresh/_docs/Cart/raw.md" || exit 1
  for f in new-requirements.md design.md tasks.md; do
    sed '1s|<FeatureName>|Cart|' "$tmpl/$f" > "$work/fresh/_docs/Cart/$f" || exit 1
  done
  out="$(cd "$work/fresh" && "$GATE" specify Cart --verify \
    --files=new-requirements.md,design.md,tasks.md 2>&1)"; rc=$?
  n="$(printf '%s\n' "$out" | grep -c 'nothing but the template' || true)"
  ok=0
  [[ "$rc" == "2" && "$n" == "3" ]] || ok=1
  for f in new-requirements.md design.md tasks.md; do
    printf '%s\n' "$out" | grep -q "$f holds nothing but the template" || ok=1
  done
  prop_check "spec verify" "an untouched spec template fails" "$ok" \
    "exit=$rc over $n untouched-template line(s), where exit=2 over the three files this run wrote is the answer"

  # And the run that finished: the marker the template shipped with is the same
  # marker, so what tells the two apart is the spec written under it.
  cp -R "$work/fresh" "$work/written" || exit 1
  for f in new-requirements.md design.md tasks.md; do
    printf '\nThe cart survives a dropped session.\n' \
      >> "$work/written/_docs/Cart/$f" || exit 1
  done
  out="$(cd "$work/written" && "$GATE" specify Cart --verify \
    --files=new-requirements.md,design.md,tasks.md 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] && printf '%s\n' "$out" | grep -q '^VERIFY=ok$' || ok=1
  prop_check "spec verify" "a written spec passes" "$ok" \
    "exit=$rc, where a role that wrote into all three scaffolded files verifies"

  # The report the same way: the template carries a `verdict` property of its
  # own, and that property is the whole of what verify_code_review used to read.
  cp -R "$work/fresh" "$work/report" || exit 1
  sed 's|<FeatureName>|Cart|g' "$tmpl/review.md" \
    > "$work/report/_docs/Cart/review.md" || exit 1
  out="$(cd "$work/report" && "$GATE" code-review Cart --verify 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "2" ]] || ok=1
  printf '%s\n' "$out" | grep -q 'review.md holds nothing but the template' || ok=1
  printf '%s\n' "$out" | grep -q 'review.md carries no verdict' && ok=1
  prop_check "spec verify" "an untouched report fails" "$ok" \
    "exit=$rc, where the scaffolded report is named as the template it is and not as a report missing its verdict"

  # The precondition side of the same fact: a re-run after an interrupted one
  # finds the templates on disk, and asking the human which of them may be
  # overwritten would be asking about a file holding no answer of anyone's.
  out="$(cd "$work/fresh" && "$GATE" specify Cart 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] && printf '%s\n' "$out" | grep -q '^GATE=ok$' || ok=1
  printf '%s\n' "$out" | grep -q 'already hold a spec' && ok=1
  prop_check "spec verify" "an untouched spec is not asked about" "$ok" \
    "exit=$rc, where the three scaffolded files are nothing the human is asked whether to overwrite"

  # And the file somebody wrote into is, whatever else is on disk beside it.
  out="$(cd "$work/written" && "$GATE" specify Cart 2>&1)"; rc=$?
  n="$(printf '%s\n' "$out" | grep -c 'already hold a spec' || true)"
  ok=0
  [[ "$rc" == "0" && "$n" == "1" ]] || ok=1
  printf '%s\n' "$out" | grep -q '^GATE=ask$' || ok=1
  for f in new-requirements.md design.md tasks.md; do
    printf '%s\n' "$out" | grep -q "$f (draft)" || ok=1
  done
  prop_check "spec verify" "a written spec is asked about" "$ok" \
    "exit=$rc over $n ASK: line(s), where the three files written into are the ones the human is asked about"
}

# A run that died in the middle leaves the tree in a shape no command wrote on
# purpose: half a status flip, a file cut off mid-line, an entry compiled whose
# counter never moved. None of it is hypothetical — `replace_file` truncates its
# target before it writes, and `compile-entry` touches the compilation twice.
# What these say is that the next command reads such a tree for what it is and
# says so, instead of taking the half for the whole.
check_interrupted() {
  local work="$TMP/interrupted" base="$FIXTURES/ready-half/tree"
  local edit="$SCRIPTS/spec-edit.sh" next="$SCRIPTS/next-req.sh"
  local out rc ok n before

  printf 'interrupted\n'
  rm -rf "$work" && mkdir -p "$work" || exit 1

  # A status flip that got through one file of three. The three files disagree,
  # and both halves of that — the disagreement itself and which files are still
  # draft — are the human's to see.
  cp -R "$base" "$work/half-flip" || exit 1
  ( cd "$work/half-flip" && "$edit" status Cart draft design.md tasks.md ) >/dev/null || exit 1
  out="$(cd "$work/half-flip" && "$GATE" implement Cart 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] && printf '%s\n' "$out" | grep -q '^GATE=ask$' || ok=1
  printf '%s\n' "$out" | grep -q 'disagree on Status — ready: new-requirements.md; draft: design.md, tasks.md' || ok=1
  printf '%s\n' "$out" | grep -q 'Not reviewed: design.md (draft), tasks.md (draft)' || ok=1
  prop_check "interrupted" "half a status flip is reported as one" "$ok" \
    "exit=$rc, where a tree whose three spec files disagree is asked about and the disagreement named"

  # A file cut off before its status. The flip is refused whole: the
  # check runs over every file before any is written, so the two sound files
  # keep the status they had rather than following the broken one halfway.
  cp -R "$base" "$work/truncated" || exit 1
  head -1 "$base/_docs/Cart/design.md" > "$work/truncated/_docs/Cart/design.md" || exit 1
  out="$(cd "$work/truncated" && "$edit" status Cart draft new-requirements.md design.md tasks.md 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "2" ]] || ok=1
  printf '%s\n' "$out" | grep -q 'design.md carries no status' || ok=1
  for n in new-requirements.md tasks.md; do
    [[ "$(md_status "$work/truncated/_docs/Cart/$n")" == "ready" ]] || ok=1
  done
  prop_check "interrupted" "a truncated file flips nothing" "$ok" \
    "exit=$rc, where the file with no status line refuses the flip and leaves the other two at ready"

  # And what the gate makes of the same tree: a missing status line is not a
  # missing file, and calling it draft is what keeps the run going.
  out="$(cd "$work/truncated" && "$GATE" implement Cart 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] || ok=1
  printf '%s\n' "$out" | grep -q "design.md carries no status — counted as draft" || ok=1
  prop_check "interrupted" "a truncated file counts as draft" "$ok" \
    "exit=$rc, where the file cut off above its status line is read as a draft and named as one"

  # The write that died before any byte landed. An empty file is not a draft:
  # there is nothing under it to implement, and the run stops rather than
  # building from a page that says nothing.
  cp -R "$base" "$work/empty" || exit 1
  : > "$work/empty/_docs/Cart/design.md" || exit 1
  out="$(cd "$work/empty" && "$edit" status Cart draft new-requirements.md design.md 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "2" ]] || ok=1
  printf '%s\n' "$out" | grep -q 'design.md carries no status' || ok=1
  [[ "$(md_status "$work/empty/_docs/Cart/new-requirements.md")" == "ready" ]] || ok=1
  prop_check "interrupted" "an empty file flips nothing" "$ok" \
    "exit=$rc, where the emptied file refuses the flip and new-requirements.md stays at ready"

  out="$(cd "$work/empty" && "$GATE" implement Cart 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] && printf '%s\n' "$out" | grep -q '^GATE=stop$' || ok=1
  printf '%s\n' "$out" | grep -q 'design.md exists but is empty — counted as missing' || ok=1
  prop_check "interrupted" "an empty file stops the run" "$ok" \
    "exit=$rc, where a spec file holding no bytes is named as missing rather than read as a draft"

  # The re-run after a flip that did finish. Every file is already where it was
  # asked to be, so the second run writes nothing at all — a resumed session
  # repeating the step it completed changes no byte on disk.
  cp -R "$base" "$work/again" || exit 1
  before="$work/again-before"
  cp -R "$work/again/_docs" "$before" || exit 1
  out="$(cd "$work/again" && "$edit" status Cart ready new-requirements.md design.md tasks.md 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] || ok=1
  [[ "$(printf '%s\n' "$out" | sed -n '/^UPDATED:$/,/^$/p' | grep -c '\.md$' || true)" == "0" ]] || ok=1
  n="$(printf '%s\n' "$out" | sed -n '/^UNCHANGED:$/,$p' | grep -c '\.md$' || true)"
  [[ "$n" == "3" ]] || ok=1
  diff -r "$before" "$work/again/_docs" >/dev/null 2>&1 || ok=1
  prop_check "interrupted" "a repeated status flip writes nothing" "$ok" \
    "exit=$rc over $n unchanged file(s), where the three files already at ready are left byte for byte"

  # `compile-entry` writes the entry and the counter as two separate writes, so
  # a death between them leaves a marker pointing at a number already issued.
  # The entries are what the next number is read off; the marker is a hint that
  # loses to them, and saying so is what keeps two features off one number.
  cp -R "$base" "$work/stale-counter" || exit 1
  awk '
    /^- \*\*REQ-003\*\*/ { print; print "- **REQ-004** — Cart clears. A shopper empties the cart. *(Source: Cart)*"; next }
    { print }
  ' "$base/_docs/requirements.md" \
    > "$work/stale-counter/_docs/requirements.md" || exit 1
  out="$(cd "$work/stale-counter" && "$next" 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] || ok=1
  printf '%s\n' "$out" | grep -q '^NEXT=REQ-005$' || ok=1
  printf '%s\n' "$out" | grep -q '^COUNTER=REQ-004$' || ok=1
  printf '%s\n' "$out" | grep -q '^SOURCE=compilation$' || ok=1
  printf '%s\n' "$out" | grep -q 'the entries win, and the marker is behind' || ok=1
  prop_check "interrupted" "a counter left behind loses to the entries" "$ok" \
    "exit=$rc, where the marker at REQ-004 over an entry carrying REQ-004 hands out REQ-005 and says the marker is behind"
}

# Requirements grouped by domain: `REQ-ACC-003` beside `REQ-001`. The fixture
# `domained` records what the gate prints over such a compilation; these are the
# properties underneath it — one sequence per domain, over the trees a fixture
# would have to be a project to hold: a domain nothing names yet, a marker left
# behind its own entries, a number carried twice inside one domain.
#
# The undomained ids are half of every case here on purpose: a domain is a
# decision a project makes partway through, so the two shapes share a file, and
# a reader that treats them as one sequence hands out a number in use.
check_domains() {
  local work="$TMP/domain-check" next="$SCRIPTS/next-req.sh"
  local out rc ok v

  printf 'domains\n'
  rm -rf "$work" && mkdir -p "$work/mixed/_docs/Cart" || exit 1

  cat > "$work/mixed/_docs/requirements.md" <<'EOF'
# Requirements Compilation

<!-- Next free number: REQ-002 -->
<!-- Next free number: REQ-ACC-002 -->

## Requirements

- **REQ-001** — Catalog listing. A shopper browses the products on offer. *(Source: Catalog)*
- **REQ-ACC-001** — Sign-up. A visitor opens an account with an email address. *(Source: Account)*
- **REQ-ACC-003** — Password reset. An account holder sets a new password. *(Source: Account)*
EOF
  cat > "$work/mixed/_docs/Cart/new-requirements.md" <<'EOF'
# Requirements — Cart

> Status: draft

## Requirements

### REQ-CART-005 — Cart holds items

A shopper keeps picked items until checkout.
EOF

  # The three parts of an id, for the shell. `REQ-003` has no domain and is not
  # a special case: the empty domain is one more sequence.
  ok=0
  [[ "$(md_req_domain REQ-ACC-003)" == "ACC" ]] || ok=1
  [[ "$(md_req_domain REQ-ACC-SUB-003)" == "ACC-SUB" ]] || ok=1
  [[ -z "$(md_req_domain REQ-003)" ]] || ok=1
  [[ "$(md_req_number REQ-ACC-003)" == "003" ]] || ok=1
  [[ "$(md_req_id ACC 3)" == "REQ-ACC-003" ]] || ok=1
  md_req_is_id REQ-ACC-003 || ok=1
  md_req_is_id REQ-Acc-003 && ok=1
  prop_check domains "an id splits into domain and number" "$ok" \
    "md_req_domain/md_req_number/md_req_id disagree on REQ-ACC-003, REQ-ACC-SUB-003 or REQ-003, or REQ-Acc-003 reads as an id"

  # Each domain is a sequence of its own: the ACC marker answers for ACC alone,
  # and the highest ACC entry is what it is measured against.
  out="$(cd "$work/mixed" && "$next" . ACC 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] || ok=1
  printf '%s\n' "$out" | grep -q '^DOMAIN=ACC$' || ok=1
  printf '%s\n' "$out" | grep -q '^NEXT=REQ-ACC-004$' || ok=1
  printf '%s\n' "$out" | grep -q '^HIGHEST=REQ-ACC-003$' || ok=1
  printf '%s\n' "$out" | grep -q '^SOURCE=compilation$' || ok=1
  prop_check domains "a domain counts its own entries" "$ok" \
    "exit=$rc, where the ACC marker at REQ-ACC-002 loses to the entry carrying REQ-ACC-003 and REQ-ACC-004 is handed out"

  # And the undomained sequence is untouched by them: three entries in the file,
  # one of them undomained, and the next undomained number is REQ-002.
  out="$(cd "$work/mixed" && "$next" 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] || ok=1
  printf '%s\n' "$out" | grep -q '^NEXT=REQ-002$' || ok=1
  printf '%s\n' "$out" | grep -q '^HIGHEST=REQ-001$' || ok=1
  printf '%s\n' "$out" | grep -q '^COUNT=3$' || ok=1
  printf '%s\n' "$out" | grep -q '^-|NEXT=REQ-002|COUNTER=REQ-002|HIGHEST=REQ-001|.*|COUNT=1$' || ok=1
  prop_check domains "the undomained sequence keeps its numbers" "$ok" \
    "exit=$rc, where REQ-ACC-003 pushed the undomained sequence past REQ-002, or its record counts the whole file"

  # A declaration reserves a number in its own domain before the compilation
  # ever sees it, and the feature holding it is named.
  ok=0
  printf '%s\n' "$out" | grep -q '^CART|NEXT=REQ-CART-006|COUNTER=|HIGHEST=|DECLARED=REQ-CART-005|DECLARED_IN=Cart|COUNT=0$' || ok=1
  prop_check domains "a declaration reserves its domain's number" "$ok" \
    "the CART record does not read REQ-CART-006 off the declaration REQ-CART-005 of the feature Cart"

  # Two ids that differ only in domain are two ids. Reading the number alone
  # would call these a collision and stop every run over the file.
  ok=0
  printf '%s\n' "$out" | sed -n '/^DUPLICATES:$/,/^$/p' | grep -q 'REQ' && ok=1
  prop_check domains "REQ-003 and REQ-ACC-003 are not one number" "$ok" \
    "the compilation holding REQ-001 and REQ-ACC-001 was reported as carrying a duplicate"

  # A domain nothing names yet is still answered for: that is what makes
  # REQ-BILL-001 readable as the first number of a group being started.
  out="$(cd "$work/mixed" && "$next" . BILL 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] || ok=1
  printf '%s\n' "$out" | grep -q '^NEXT=REQ-BILL-001$' || ok=1
  printf '%s\n' "$out" | grep -q '^SOURCE=none$' || ok=1
  printf '%s\n' "$out" | grep -q '^BILL|NEXT=REQ-BILL-001|' || ok=1
  prop_check domains "an unused domain starts at 001" "$ok" \
    "exit=$rc, where a domain no entry, declaration or marker names is not answered with REQ-BILL-001"

  # A name no id could carry is refused rather than answered: a number handed
  # out under it would reserve nothing.
  for v in Acc acc 3ACC ACC- ''; do
    [[ -n "$v" ]] || continue
    out="$(cd "$work/mixed" && "$next" . "$v" 2>&1)"; rc=$?
    ok=0
    [[ "$rc" == "1" ]] && printf '%s\n' "$out" | grep -q '^ERROR=not a domain' || ok=1
    prop_check domains "'$v' is not a domain" "$ok" \
      "exit=$rc over: $(printf '%s' "$out" | head -1)"
  done

  # A number carried twice inside one domain is the collision the script exists
  # to prevent, and it is reported as the id it is.
  cp -R "$work/mixed" "$work/dup" || exit 1
  printf -- '- **REQ-ACC-003** — Password reset again. A second entry on one number. *(Source: Account)*\n' \
    >> "$work/dup/_docs/requirements.md"
  out="$(cd "$work/dup" && "$next" . ACC 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] || ok=1
  printf '%s\n' "$out" | sed -n '/^DUPLICATES:$/,/^$/p' | grep -q '^REQ-ACC-003$' || ok=1
  prop_check domains "a domain's own duplicate is reported" "$ok" \
    "exit=$rc, where REQ-ACC-003 carried by two entries was not named a duplicate"

  # The gate stops on it, over the domained id: the compilation is inconsistent
  # before any number is issued.
  out="$(cd "$work/dup" && "$GATE" specify Cart 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] && printf '%s\n' "$out" | grep -q '^GATE=stop$' || ok=1
  printf '%s\n' "$out" | grep -q 'REQ-ACC-003' || ok=1
  prop_check domains "the gate stops on a domained duplicate" "$ok" \
    "exit=$rc, where a compilation carrying REQ-ACC-003 twice did not stop the run by that id"

  # A domain whose entries have no marker: the sequence has nothing to start the
  # next feature from, and the gate says which one is missing it.
  cp -R "$work/mixed" "$work/no-marker" || exit 1
  grep -v 'Next free number: REQ-ACC-' "$work/mixed/_docs/requirements.md" \
    > "$work/no-marker/_docs/requirements.md" || exit 1
  out="$(cd "$work/no-marker" && "$GATE" actualize Cart --verify 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "2" ]] || ok=1
  printf '%s\n' "$out" | grep -q "carries no '<!-- Next free number: -->' marker for ACC requirements" || ok=1
  printf '%s\n' "$out" | grep -q "for the undomained requirements" && ok=1
  prop_check domains "a domain with entries and no marker is named" "$ok" \
    "exit=$rc, where the ACC entries standing without an ACC marker were not reported by domain, or the undomained sequence carrying its own marker was reported with them"

  # The write side: a value moves the marker of its own domain and leaves every
  # other one where it stands.
  cp -R "$work/mixed" "$work/write" || exit 1
  local file="$work/write/_docs/requirements.md"
  md_counter_set "$file" REQ-ACC-009 > "$work/write/out.md" || ok=1
  ok=0
  grep -q 'Next free number: REQ-ACC-009 -->' "$work/write/out.md" || ok=1
  grep -q 'Next free number: REQ-002 -->' "$work/write/out.md" || ok=1
  [[ "$(grep -c 'Next free number:' "$work/write/out.md")" == "2" ]] || ok=1
  prop_check domains "a counter moves its own domain alone" "$ok" \
    "writing REQ-ACC-009 did not leave the undomained marker at REQ-002 beside it, over $(grep -c 'Next free number:' "$work/write/out.md") marker(s)"
  cp "$work/write/out.md" "$file" || exit 1

  # A domain the file carries no marker for gets one, under the last marker
  # there is: the first requirement of a new group is what creates its sequence.
  md_counter_set "$file" REQ-BILL-002 > "$work/write/new.md"
  ok=0
  grep -q 'Next free number: REQ-BILL-002 -->' "$work/write/new.md" || ok=1
  [[ "$(grep -c 'Next free number:' "$work/write/new.md")" == "3" ]] || ok=1
  [[ "$(sed -n '5p' "$work/write/new.md")" == '<!-- Next free number: REQ-BILL-002 -->' ]] || ok=1
  prop_check domains "a new domain's marker is written in" "$ok" \
    "writing REQ-BILL-002 into a file with no BILL marker left line 5 as '$(sed -n '5p' "$work/write/new.md")' over $(grep -c 'Next free number:' "$work/write/new.md") marker(s), where the marker belongs under the last one there is"

  # And a marker is read back per domain rather than by position.
  ok=0
  [[ "$(md_counter "$work/write/new.md" ACC)" == "REQ-ACC-009" ]] || ok=1
  [[ "$(md_counter "$work/write/new.md")" == "REQ-002" ]] || ok=1
  [[ "$(md_counter "$work/write/new.md" NONE)" == "" ]] || ok=1
  prop_check domains "a marker is read by its domain" "$ok" \
    "md_counter read '$(md_counter "$work/write/new.md" ACC)' for ACC and '$(md_counter "$work/write/new.md")' for the undomained sequence"
}

# The candidate checked against the text the specs already carry. An entry and a
# declaration reserve a number; a `Requires: REQ-014` reserves nothing and uses
# it all the same, and the two are what these tell apart. No fixture holds a
# spec writing a number nobody reserved — that is the shape of a project halfway
# through a repair, not of one a command left behind.
check_taken() {
  local work="$TMP/taken-check" next="$SCRIPTS/next-req.sh"
  local out rc ok

  printf 'taken\n'
  rm -rf "$work" && mkdir -p "$work/used/_docs/Cart" || exit 1

  cat > "$work/used/_docs/requirements.md" <<'EOF'
# Requirements Compilation

<!-- Next free number: REQ-004 -->

## Requirements

- **REQ-001** — Catalog listing. A shopper browses the products on offer. *(Source: Catalog)*
- **REQ-003** — Cart totals. A cart shows the sum of its items. *(Source: Cart)*
EOF
  cat > "$work/used/_docs/Cart/tasks.md" <<'EOF'
# Tasks — Cart

> Status: draft

## Tasks

- [ ] **TASK-001** — Cart table and entity
  - **Requires:** REQ-004
  - **Type:** backend

- [ ] **TASK-002** — Saved carts
  - **Requires:** REQ-005
  - **Type:** backend
EOF

  # Two numbers the tasks require and nothing reserves. The candidate the
  # counter gave is one of them, and the answer moves past both.
  out="$(cd "$work/used" && "$next" 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] || ok=1
  printf '%s\n' "$out" | grep -q '^NEXT=REQ-006$' || ok=1
  printf '%s\n' "$out" | grep -q '^SOURCE=scan$' || ok=1
  printf '%s\n' "$out" | grep -q '^TAKEN=REQ-004 REQ-005$' || ok=1
  printf '%s\n' "$out" | grep -q '^-|NEXT=REQ-006|' || ok=1
  printf '%s\n' "$out" | grep -q 'written into the specs without being reserved' || ok=1
  prop_check taken "a number the specs use is not free" "$ok" \
    "exit=$rc, where REQ-004 and REQ-005 required by a task and reserved by nothing did not move the answer to REQ-006"

  # Five in a row is where it stops. Nothing is handed out: a sixth guess would
  # be a number over whatever the file says next, and the human repairs the
  # files instead.
  cp -R "$work/used" "$work/wall" || exit 1
  printf -- '  - **Requires:** REQ-006\n  - **Requires:** REQ-007\n  - **Requires:** REQ-008\n' \
    >> "$work/wall/_docs/Cart/tasks.md"
  out="$(cd "$work/wall" && "$next" 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "3" ]] || ok=1
  printf '%s\n' "$out" | grep -q '^NEXT=$' || ok=1
  printf '%s\n' "$out" | grep -q '^SOURCE=taken$' || ok=1
  printf '%s\n' "$out" | grep -q '^TAKEN=REQ-004 REQ-005 REQ-006 REQ-007 REQ-008$' || ok=1
  printf '%s\n' "$out" | grep -q '^-|NEXT=|' || ok=1
  prop_check taken "five in a row is refused" "$ok" \
    "exit=$rc, where five numbers written into the specs did not leave NEXT empty at exit 3"

  # And the gate carries the refusal to the human rather than starting a
  # session that has no number to write with.
  out="$(cd "$work/wall" && "$GATE" specify Cart 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] && printf '%s\n' "$out" | grep -q '^GATE=stop$' || ok=1
  printf '%s\n' "$out" | grep -q '^NEXT_REQ=$' || ok=1
  printf '%s\n' "$out" | grep -q 'No requirement number is free: REQ-004 REQ-005 REQ-006 REQ-007 REQ-008' || ok=1
  printf '%s\n' "$out" | grep -q '^-|NEXT=|' || ok=1
  prop_check taken "the gate stops with no number to issue" "$ok" \
    "exit=$rc, where the run was not stopped by name over the five numbers, or the domains table was dropped with the empty NEXT"

  # A number named inside a comment reserves nothing. The hint block of
  # `.sdd/templates/requirements.md` names four, REQ-001 among them, and a
  # project copied from it starts at REQ-001 all the same.
  mkdir -p "$work/fresh/_docs" || exit 1
  cp "$SCRIPT_DIR/../.sdd/templates/requirements.md" "$work/fresh/_docs/" || exit 1
  out="$(cd "$work/fresh" && "$next" 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] || ok=1
  printf '%s\n' "$out" | grep -q '^NEXT=REQ-001$' || ok=1
  printf '%s\n' "$out" | grep -q '^TAKEN=$' || ok=1
  prop_check taken "a comment reserves nothing" "$ok" \
    "exit=$rc, where the REQ-001 of the template's hint block took the first number of a project copied from it"

  # The scan is per domain like everything else here: REQ-ACC-004 in a task
  # moves the ACC sequence and leaves the undomained one where it was.
  cp -R "$work/used" "$work/domained" || exit 1
  printf '# Requirements Compilation\n\n<!-- Next free number: REQ-004 -->\n<!-- Next free number: REQ-ACC-004 -->\n\n## Requirements\n\n- **REQ-001** — Catalog listing. A shopper browses. *(Source: Catalog)*\n- **REQ-ACC-003** — Sign-up. A visitor opens an account. *(Source: Account)*\n' \
    > "$work/domained/_docs/requirements.md" || exit 1
  printf '# Tasks — Cart\n\n> Status: draft\n\n- [ ] **TASK-001** — Sign-up form\n  - **Requires:** REQ-ACC-004\n  - **Type:** frontend\n' \
    > "$work/domained/_docs/Cart/tasks.md" || exit 1
  out="$(cd "$work/domained" && "$next" . ACC 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] || ok=1
  printf '%s\n' "$out" | grep -q '^NEXT=REQ-ACC-005$' || ok=1
  printf '%s\n' "$out" | grep -q '^TAKEN=REQ-ACC-004$' || ok=1
  printf '%s\n' "$out" | grep -q '^-|NEXT=REQ-004|' || ok=1
  prop_check taken "the scan moves one domain alone" "$ok" \
    "exit=$rc, where REQ-ACC-004 used by a task did not move ACC to REQ-ACC-005, or moved the undomained sequence off REQ-004 with it"

  # A longer number is a different number. Reading the mention as a prefix
  # would reserve REQ-004 for every project whose specs name REQ-0041.
  cp -R "$work/used" "$work/prefix" || exit 1
  printf '# Tasks — Cart\n\n> Status: draft\n\n- [ ] **TASK-001** — Cart table\n  - **Requires:** REQ-0041\n  - **Type:** backend\n' \
    > "$work/prefix/_docs/Cart/tasks.md" || exit 1
  out="$(cd "$work/prefix" && "$next" 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] || ok=1
  printf '%s\n' "$out" | grep -q '^NEXT=REQ-004$' || ok=1
  printf '%s\n' "$out" | grep -q '^TAKEN=$' || ok=1
  prop_check taken "REQ-0041 is not REQ-004" "$ok" \
    "exit=$rc, where a task requiring REQ-0041 was read as using REQ-004 and moved the answer off it"
}

# The cases of one fixture run side by side, CASE_JOBS at a time. A script
# spends its time starting programs rather than computing, so a fixture run
# case after case was the whole wall time of the suite. Each case gets a root
# of its own holding a copy of the project at the same relative path — what
# `normalize` rewrites to `<tmp>` reads back exactly as before — and its output
# is printed in case order once the fixture is done.
CASE_JOBS="${SDD_TEST_CASE_JOBS:-8}"
case "$CASE_JOBS" in ''|*[!0-9]*|0) CASE_JOBS=8 ;; esac
CASE_N=0
case_bg() {
  local i=$CASE_N fixture="$1"
  shift
  CASE_N=$(( CASE_N + 1 ))
  (
    local root="$TMP/case-$i" a args=()
    mkdir -p "$root" && cp -R "$TMP/$fixture" "$root/$fixture" || exit 1
    for a in "$@"; do args+=("${a//@PROJECT@/$root/$fixture}"); done
    TMP="$root"
    "${args[@]}"
    printf '0\n' > "$root.rc"
  ) > "$TMP/case-$i.out" 2>&1 &
  (( CASE_N % CASE_JOBS == 0 )) && wait
  return 0
}
case_collect() {
  local i
  wait
  for (( i = 0; i < CASE_N; i++ )); do
    cat "$TMP/case-$i.out"
    [[ "$(cat "$TMP/case-$i.rc" 2>/dev/null)" == "0" ]] || { printf 'ERROR=case %s did not finish\n' "$i" >&2; exit 1; }
  done
}

run_fixture() {
  local fixture="$1"
  local dir="$FIXTURES/$fixture"
  local project="$TMP/$fixture"
  local FEATURE="" EXTRA="" GIT="no" cmd

  case " $LOGGED_FIXTURES " in
    *" all "*|*" $fixture "*) ;;
    *) export SDD_LOG=0 ;;
  esac

  [[ -f "$dir/case" ]] || { printf 'ERROR=no case file: %s\n' "$dir/case" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$dir/case"

  mkdir -p "$project"
  if [[ -d "$dir/tree" ]]; then
    cp -R "$dir/tree/." "$project/" || exit 1
  fi

  if [[ "$GIT" == "yes" ]]; then
    (
      cd "$project" || exit 1
      git init -q . || exit 1
      # A fixture whose subject is the history itself writes its own: branches,
      # remote-tracking refs, upstream. Everything else gets one commit.
      if [[ -f "$dir/git-setup" ]]; then
        # shellcheck disable=SC1090
        . "$dir/git-setup"
      else
        git add -A && git commit -qm "fixture"
      fi
    ) >/dev/null 2>&1 || { printf 'ERROR=git fixture setup failed: %s\n' "$fixture" >&2; exit 1; }
    if [[ -d "$dir/after-commit" ]]; then
      cp -R "$dir/after-commit/." "$project/" || exit 1
    fi
  fi

  printf '%s\n' "$fixture"
  for cmd in $COMMANDS; do
    case_bg "$fixture" run_case "$fixture" "$cmd" @PROJECT@ "$FEATURE" "$EXTRA"
  done

  local line name pcmd pscope pargs
  while IFS='|' read -r name pcmd pscope pargs; do
    [[ -n "$name" ]] || continue
    # A base-ref the fixture names reaches the renderer the way a command passes
    # it on: two detections of a review set produce two sets.
    if [[ "$pcmd" == "code-review" && -n "$EXTRA" && "$pargs" != *BASE=* ]]; then
      pargs="BASE=$EXTRA${pargs:+;$pargs}"
    fi
    case_bg "$fixture" run_prompt_case "$fixture" "$name" "$pcmd" "$pscope" "$pargs" @PROJECT@ "$FEATURE"
  done <<EOF
$PROMPT_CASES
EOF

  local vcmd vopts
  while IFS='|' read -r name vcmd vopts; do
    [[ -n "$name" ]] || continue
    case_bg "$fixture" run_verify_case "$fixture" "$name" "$vcmd" "$vopts" @PROJECT@ "$FEATURE"
  done <<EOF
$VERIFY_CASES
EOF

  local eargs
  while IFS='|' read -r name eargs; do
    [[ -n "$name" ]] || continue
    case_bg "$fixture" run_edit_case "$fixture" "$name" "$eargs" @PROJECT@ "$FEATURE"
  done <<EOF
$EDIT_CASES
EOF

  local jjson jargs jenv
  while IFS='|' read -r name jjson jargs jenv; do
    [[ -n "$name" ]] || continue
    case_bg "$fixture" run_jira_case "$fixture" "$name" "$jjson" "$jargs" "$jenv" @PROJECT@ "$FEATURE"
  done <<EOF
$JIRA_CASES
EOF
  case_collect
}

# ── The jobs ──────────────────────────────────────────────────────
# A job is one property check or one fixture. They share nothing: each gets its
# own temporary root, its own HOME and its own log directory, and each writes
# its verdicts and its output to files of its own. So they run side by side, and
# the parent replays their output afterwards in the order the queue was built —
# a parallel run reads exactly like a serial one.
#
# The number of them at once follows the machine. SDD_TEST_JOBS=1 puts the suite
# back on one core, which is what to reach for when a failure looks like it
# might be the harness rather than the engine.
JOBS="${SDD_TEST_JOBS:-}"
if [[ -z "$JOBS" ]]; then
  JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
fi
case "$JOBS" in ''|*[!0-9]*) JOBS=4 ;; esac
(( JOBS > 0 )) || JOBS=1
# `wait -n` is bash 4.3. Without it a job slot cannot be reclaimed one at a
# time, and the suite runs serially rather than in waves that would idle every
# core but the slowest job's.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  JOBS=1
fi

JOB_NAMES=()

# The body of one job. The exit code is written before the work starts and
# overwritten when it finishes: a job that dies part-way — `exit 1` out of a
# fixture whose setup failed, a `set -u` abort — leaves the 1 standing, and the
# parent has its answer without depending on a status `wait -n` may already
# have reaped.
# The jira skill reads no config of its own accord; jira-import.sh hands
# it the engine's two files. What is checked is that both reach it, in the
# engine's order — the project's .sdd/sdd.conf over the home token file — and
# that a missing one is simply not passed. The issue's own instance is the
# visible effect: a bare key has nowhere else to take it from.
check_jira_tokens() {
  local work="$TMP/jira-tokens" home="$TMP/jira-tokens-home" out rc ok
  local json="$FIXTURES/jira/issue.json"

  printf 'jira-tokens\n'
  rm -rf "$work" "$home" && mkdir -p "$work/.sdd" "$home/.config/sdd-kit" || exit 1
  printf 'JIRA_URL=https://home.example.com\nJIRA_TOKEN=t\n' > "$home/.config/sdd-kit/tokens.env"

  out="$(cd "$work" && env -u JIRA_URL -u JIRA_TOKEN "HOME=$home" SDD_LOG=0 \
        "$JIRA_SH" ABC-12345 --out _docs/ABC-12345/raw.md --from-file "$json" 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] || ok=1
  printf '%s\n' "$out" | grep -q '^URL=https://home.example.com/browse/ABC-12345$' || ok=1
  prop_check jira-tokens "the home token file is passed; no sdd.conf is not an error" "$ok" "exit=$rc, out: $out"

  printf 'SDD_BUILD_ROOT=true\nJIRA_URL=https://proj.example.com\n' > "$work/.sdd/sdd.conf"
  out="$(cd "$work" && env -u JIRA_URL -u JIRA_TOKEN "HOME=$home" SDD_LOG=0 \
        "$JIRA_SH" ABC-12345 --out _docs/ABC-12345/raw.md --from-file "$json" 2>&1)"; rc=$?
  ok=0
  [[ "$rc" == "0" ]] || ok=1
  printf '%s\n' "$out" | grep -q '^URL=https://proj.example.com/browse/ABC-12345$' || ok=1
  prop_check jira-tokens "the project's sdd.conf wins over the home file" "$ok" "exit=$rc, out: $out"
}

# A skill with a suite of its own: maven-lib-source needs a Maven repository
# built here out of javac and jar, confluence and jira a fake curl
# on PATH, and none is a shape a fixture of this suite can hold; each is useful on its own
# while that script is being changed. Called from here it is one job like any
# other, and the verdict it prints is folded into this count so a failure there
# fails the run.
check_suite() {
  local name="$1" script="${2:-run.sh}" out rc summary p f i

  out="$("$SCRIPT_DIR/$name/$script" 2>&1)"; rc=$?
  summary="$(printf '%s\n' "$out" | tail -1)"
  printf '%s\n' "$out" | sed '$d'

  p="$(printf '%s' "$summary" | sed -n 's/^\([0-9][0-9]*\) passed.*/\1/p')"
  f="$(printf '%s' "$summary" | sed -n 's/.*, \([0-9][0-9]*\) failed$/\1/p')"
  if [[ -z "$p" || -z "$f" ]]; then
    fail
    printf '  FAILED   %s — tests/%s/run.sh printed no verdict, exit %s\n' "$name" "$name" "$rc"
    return 0
  fi

  for (( i = 0; i < p; i++ )); do pass; done
  for (( i = 0; i < f; i++ )); do fail; done
}

# What one requirement is to another, end to end. A relation is written by a
# role as a line under a heading, read by lib/format.sh, handed to
# /sdd-actualize by the gate, applied by spec-edit.sh, and read back by
# feature-state.sh as the stage of the feature — five scripts over one line, and
# a fixture records one of them at a time. This walks a promotion through all
# five, a feature that only refines among them: that one leaves no entry of its
# own, and used to stay at `implemented` for good.
check_relations() {
  local work="$TMP/relations-check" state="$SCRIPTS/feature-state.sh"
  local out rc ok v line

  printf 'relations\n'
  rm -rf "$work" && mkdir -p "$work/_docs/Checkout" "$work/_docs/Promo" || exit 1

  cat > "$work/_docs/requirements.md" <<'EOF'
# Requirements Compilation

<!-- Next free number: REQ-003 -->

## Requirements

- **REQ-001** — Guest checkout. A guest can order without an account. *(Source: Catalog)*
- **REQ-002** — Cart holds items. A shopper keeps picked items until checkout. *(Source: Cart)*
EOF
  printf '# Architecture\n\nA monolith.\n' > "$work/_docs/architecture.md"

  cat > "$work/_docs/Checkout/new-requirements.md" <<'EOF'
---
status: ready
---

# Requirements — Checkout

## Requirements

### REQ-003 — Cart size
- **Refines:** [REQ-002](../requirements.md#^req-002)
- **Description:** A shopper keeps up to 50 items until checkout. ^req-003

### REQ-004 — Account checkout
- **Supersedes:** [REQ-001](../requirements.md#^req-001)
- **Description:** An order needs an account. It replaces REQ-002 nowhere. ^req-004

### REQ-005 — Order summary
- **Description:** A shopper sees the order before paying. ^req-005

<!--
### REQ-099 — An example
- **Refines:** REQ-001
-->

## Out of Scope

### REQ-006 — Gift wrapping
EOF
  printf -- '---\nstatus: ready\n---\n\n# Design — Checkout\n\nBody.\n' > "$work/_docs/Checkout/design.md"
  cat > "$work/_docs/Checkout/tasks.md" <<'EOF'
---
status: ready
---

# Tasks — Checkout

## Tasks

- [x] **TASK-001** — Checkout service
  - **Requires:** REQ-003, REQ-004, REQ-005
  - **Type:** backend
EOF
  printf -- '---\nreviewed: 2026-01-15\nbase: main\nroot: deadbeef\nverdict: APPROVED WITH MINOR ISSUES\n---\n\n# Code Review — Checkout\n\nBody.\n' \
    > "$work/_docs/Checkout/review.md"

  # ── The reader ──────────────────────────────────────────────────
  out="$(md_req_relations "$work/_docs/Checkout/new-requirements.md" | tr '\n' ' ')"
  ok=0; [[ "$out" == "REQ-003|refines|REQ-002 REQ-004|supersedes|REQ-001 REQ-005|new| " ]] || ok=1
  prop_check relations "read off the page" "$ok" \
    "md_req_relations printed '$out' — three records, the commented example and the requirement under Out of Scope in none of them"

  # ── The gate hands them over ────────────────────────────────────
  out="$(cd "$work" && "$GATE" actualize Checkout 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q '^GATE=ok$' || ok=1
  printf '%s\n' "$out" | grep -q '^REQ-003|refines|REQ-002$' || ok=1
  printf '%s\n' "$out" | grep -q '^REQ-004|supersedes|REQ-001$' || ok=1
  printf '%s\n' "$out" | grep -q 'lists Major findings' || ok=1
  prop_check relations "gate prints DECLARED:" "$ok" \
    "gate.sh actualize did not answer ok with the three records and the warning about the review: $(printf '%s' "$out" | tr '\n' '~')"

  # `APPROVED WITH MINOR ISSUES` lists Major findings: the next step is the fix.
  v="$(cd "$work" && "$state" Checkout | sed -n 's/^NEXT=//p')"
  ok=0; [[ "$v" == "/sdd-code-fix Checkout" ]] || ok=1
  prop_check relations "approved with issues goes to the fix" "$ok" \
    "feature-state.sh says NEXT=$v for a report whose verdict lists Major findings"

  # ── Nothing promoted yet ────────────────────────────────────────
  out="$(cd "$work" && "$GATE" actualize Checkout --verify 2>&1)"; rc=$?
  ok=0
  [[ $rc -eq 2 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^REQ-003 refines REQ-002' || ok=1
  printf '%s\n' "$out" | grep -q '^REQ-004 supersedes REQ-001' || ok=1
  printf '%s\n' "$out" | grep -q '^REQ-005 is declared' || ok=1
  prop_check relations "verify names what did not arrive" "$ok" \
    "exit $rc: $(printf '%s' "$out" | tr '\n' '~')"

  # ── The promotion in one call, on a copy ───────────────────────
  # promote reads the relations off the page and takes only the words. A line
  # missing is a stop that names it, and the compilation stays as it was.
  local one="$work.one" words before
  rm -rf "$one" && cp -R "$work" "$one" || exit 1
  before="$(cat "$one/_docs/requirements.md")"
  words='REQ-003|Cart holds items. A shopper keeps up to 50 items until checkout.
REQ-004|Account checkout. An order needs an account.'
  out="$(cd "$one" && printf '%s\nREQ-009|Stray. Nobody declared it.\n' "$words" | "$EDITOR_SH" promote Checkout - 2>&1)"; rc=$?
  ok=0
  [[ $rc -eq 2 && "$out" == *'REQ-009 is not declared'* && "$out" == *'REQ-005 has no wording on stdin'* ]] || ok=1
  [[ "$(cat "$one/_docs/requirements.md")" == "$before" ]] || ok=1
  prop_check relations "promote: a wording missing or stray stops it, nothing written" "$ok" \
    "exit $rc: $(printf '%s' "$out" | tr '\n' '~')"

  words="$words
REQ-005|Order summary. A shopper sees the order before paying."
  out="$(cd "$one" && printf '%s\n' "$words" | "$EDITOR_SH" promote Checkout - 2>&1)"; rc=$?
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  [[ "$(printf '%s\n' "$out" | sed -n '/^ENTRIES:$/,$p' | sed 1d | tr '\n' ' ')" \
      == 'REQ-002|refined REQ-004|appended REQ-001|superseded REQ-005|appended ' ]] || ok=1
  grep -q 'REQ-002\*\* — Cart holds items. A shopper keeps up to 50 items until checkout. \*(Source: Cart, refined by Checkout)\*' \
    "$one/_docs/requirements.md" || ok=1
  grep -q '^- \*\*REQ-003\*\*' "$one/_docs/requirements.md" && ok=1
  ( cd "$one" && "$GATE" actualize Checkout --verify ) >/dev/null 2>&1 || ok=1
  [[ "$(cd "$one" && "$state" Checkout | sed -n 's/^STAGE=//p')" == "actualized" ]] || ok=1
  prop_check relations "promote: every record in one call, and verify passes" "$ok" \
    "exit $rc: $(printf '%s' "$out" | tr '\n' '~')"

  before="$(cat "$one/_docs/requirements.md")"
  out="$(cd "$one" && printf '%s\n' "$words" | "$EDITOR_SH" promote Checkout - 2>&1)"; rc=$?
  ok=0
  [[ $rc -eq 0 && "$(cat "$one/_docs/requirements.md")" == "$before" ]] || ok=1
  prop_check relations "promote: a re-run changes nothing" "$ok" \
    "exit $rc: $(printf '%s' "$out" | tr '\n' '~')"

  # ── The promotion ───────────────────────────────────────────────
  out="$(cd "$work" && "$EDITOR_SH" compile-entry Checkout REQ-002 refine "Cart holds items. A shopper keeps up to 50 items until checkout." 2>&1)"
  line="$(grep 'REQ-002\*\*' "$work/_docs/requirements.md")"
  ok=0
  printf '%s\n' "$out" | grep -q '^ACTION=refined$' || ok=1
  [[ "$line" == *'up to 50 items'*'*(Source: Cart, refined by Checkout)*'* ]] || ok=1
  prop_check relations "a refinement leaves its trace" "$ok" \
    "the entry reads: $line"

  # One entry of three is a promotion cut short, not a promoted feature.
  out="$(cd "$work" && "$state" Checkout)"
  ok=0
  printf '%s\n' "$out" | grep -q '^STAGE=implemented$' || ok=1
  printf '%s\n' "$out" | grep -q '^NEXT=/sdd-actualize Checkout$' || ok=1
  printf '%s\n' "$out" | grep -q 'not REQ-004, REQ-005 — a promotion cut short' || ok=1
  prop_check relations "a promotion cut short is not actualized" "$ok" \
    "$(printf '%s' "$out" | grep -E '^(STAGE|NEXT)=|cut short' | tr '\n' '~')"

  ( cd "$work" \
    && "$EDITOR_SH" compile-entry Checkout REQ-004 final "Account checkout. An order needs an account." \
    && "$EDITOR_SH" compile-entry Checkout REQ-001 superseded-by:REQ-004 \
    && "$EDITOR_SH" compile-entry Checkout REQ-005 final "Order summary. A shopper sees the order before paying." ) >/dev/null 2>&1

  out="$(cd "$work" && "$GATE" actualize Checkout --verify 2>&1)"; rc=$?
  ok=0; [[ $rc -eq 0 ]] || ok=1
  prop_check relations "verify passes once every record is applied" "$ok" \
    "exit $rc: $(printf '%s' "$out" | tr '\n' '~')"

  out="$(cd "$work" && "$state" Checkout)"
  ok=0
  printf '%s\n' "$out" | grep -q '^STAGE=actualized$' || ok=1
  printf '%s\n' "$out" | grep -q '^COMPILATION_REFINED=1$' || ok=1
  printf '%s\n' "$out" | grep -q '^REQ-002|refined$' || ok=1
  prop_check relations "the refined entry is the feature's" "$ok" \
    "$(printf '%s' "$out" | grep -E '^(STAGE|COMPILATION_|REQ-)' | tr '\n' '~')"

  # ── A feature that only refines ─────────────────────────────────
  cat > "$work/_docs/Promo/new-requirements.md" <<'EOF'
---
status: ready
---

# Requirements — Promo

## Requirements

### REQ-007 — Cart size for members
- **Refines:** REQ-002
- **Description:** A member keeps up to 80 items. ^req-007
EOF
  printf -- '---\nstatus: ready\n---\n\n# Design — Promo\n\nBody.\n' > "$work/_docs/Promo/design.md"
  sed 's/Checkout/Promo/; s/REQ-003, REQ-004, REQ-005/REQ-007/' "$work/_docs/Checkout/tasks.md" > "$work/_docs/Promo/tasks.md"

  v="$(cd "$work" && "$state" Promo | sed -n 's/^STAGE=//p')"
  ok=0; [[ "$v" == "implemented" ]] || ok=1
  prop_check relations "refine-only, not yet promoted" "$ok" "STAGE=$v where nothing of it is in the compilation"

  ( cd "$work" && "$EDITOR_SH" compile-entry Promo REQ-002 refine "Cart holds items. A member keeps up to 80 items, anyone else 50." ) >/dev/null 2>&1
  line="$(grep 'REQ-002\*\*' "$work/_docs/requirements.md")"
  v="$(cd "$work" && "$state" Promo | sed -n 's/^STAGE=//p')"
  out="$(cd "$work" && "$state" Checkout | sed -n 's/^STAGE=//p')"
  ok=0
  [[ "$v" == "actualized" && "$out" == "actualized" ]] || ok=1
  [[ "$line" == *'*(Source: Cart, refined by Checkout, refined by Promo)*'* ]] || ok=1
  prop_check relations "refine-only reaches actualized" "$ok" \
    "Promo is '$v', Checkout is '$out', and the entry reads: $line"

  # The same call again adds no second trace, and a later supersession keeps
  # the ones that are there.
  ( cd "$work" \
    && "$EDITOR_SH" compile-entry Promo REQ-002 refine "Cart holds items. A member keeps up to 80 items, anyone else 50." \
    && "$EDITOR_SH" compile-entry Checkout REQ-002 superseded-by:REQ-005 ) >/dev/null 2>&1
  line="$(grep 'REQ-002\*\*' "$work/_docs/requirements.md")"
  ok=0
  [[ "$line" == *'*(Source: Cart, refined by Checkout, refined by Promo, superseded by REQ-005)*'* ]] || ok=1
  prop_check relations "the trace survives later edits" "$ok" "the entry reads: $line"

  # ── A relation the gate cannot act on ───────────────────────────
  cat > "$work/_docs/Promo/new-requirements.md" <<'EOF'
---
status: ready
---

# Requirements — Promo

## Requirements

### REQ-007 — Cart size for members
- **Refines:**

### REQ-008 — Member prices
- **Supersedes:** REQ-555
EOF
  out="$(cd "$work" && "$GATE" actualize Promo 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q '^GATE=stop$' || ok=1
  printf '%s\n' "$out" | grep -q '^REQ-007 says it refines a requirement and names none' || ok=1
  printf '%s\n' "$out" | grep -q '^REQ-008 supersedes REQ-555, and _docs/requirements.md holds no entry REQ-555' || ok=1
  prop_check relations "a broken relation is a stop" "$ok" \
    "$(printf '%s' "$out" | tr '\n' '~')"

  # ── A report whose verdict nobody wrote ─────────────────────────
  printf -- '---\nreviewed: 2026-01-15\nbase: main\nroot: deadbeef\nverdict: <APPROVED | APPROVED WITH MINOR ISSUES | BLOCKED>\n---\n\n# Code Review — Checkout\n\n## Findings\n\nNone.\n' \
    > "$work/_docs/Checkout/review.md"
  out="$(cd "$work" && "$GATE" code-review Checkout --verify 2>&1)"; rc=$?
  ok=0
  [[ $rc -eq 2 ]] || ok=1
  printf '%s\n' "$out" | grep -q "template's placeholder as its verdict" || ok=1
  prop_check relations "a placeholder verdict is no verdict" "$ok" \
    "exit $rc: $(printf '%s' "$out" | tr '\n' '~')"
}

# Words reach spec-edit.sh from a human or a role and are written as given:
# a backslash, a backtick, a dollar sign or a quote is text, never syntax.
check_text() {
  local work="$TMP/text-check" out line ok rc
  local nasty='Matches \d+ in C:\new\table, `code` and $HOME "quoted"'

  printf 'text\n'
  rm -rf "$work" && mkdir -p "$work/_docs/Cart" || exit 1
  cat > "$work/_docs/requirements.md" <<'EOF'
# Requirements Compilation

<!-- Next free number: REQ-002 -->

## Requirements

- **REQ-001** — Old. Old wording. *(Source: Cart)* ^req-001
EOF
  printf 'int a;\nint b;\n' > "$work/A.java"

  # ── As an argument ──────────────────────────────────────────────
  ( cd "$work" && "$EDITOR_SH" compile-entry Cart REQ-002 final "New. $nasty" \
              && "$EDITOR_SH" compile-entry Cart REQ-001 final "Old. $nasty" \
              && "$EDITOR_SH" marker A.java 2 "$nasty" ) >/dev/null 2>&1
  ok=0
  [[ "$(grep -cF -- "$nasty" "$work/_docs/requirements.md")" == "2" ]] || ok=1
  grep -qF -- "// TODO Code Review: $nasty (" "$work/A.java" || ok=1
  [[ "$(grep -c '' "$work/A.java")" == "3" ]] || ok=1
  prop_check text "an argument is written byte for byte" "$ok" \
    "requirements.md: $(tr '\n' '~' < "$work/_docs/requirements.md") A.java: $(tr '\n' '~' < "$work/A.java")"

  # ── On stdin ────────────────────────────────────────────────────
  # The way the commands pass words: `-`, and a quoted here-document.
  printf '# Raw\n\n## Problem\n\n<!-- hint -->\n\n## Users\n' > "$work/_docs/Cart/raw.md"
  ( cd "$work" && "$EDITOR_SH" section _docs/Cart/raw.md Problem - <<'SDD_TEXT'
- Does `REQ-001` cost $5? \d+ **Answer:** yes
second line
SDD_TEXT
  ) >/dev/null 2>&1
  ( cd "$work" && printf '%s\n' "Stdin. $nasty" | "$EDITOR_SH" compile-entry Cart REQ-003 final - \
              && printf '%s\n' "$nasty" | "$EDITOR_SH" marker A.java 1 - ) >/dev/null 2>&1
  ok=0
  grep -qF -- '- Does `REQ-001` cost $5? \d+ **Answer:** yes' "$work/_docs/Cart/raw.md" || ok=1
  grep -qx 'second line' "$work/_docs/Cart/raw.md" || ok=1
  grep -qF -- "**REQ-003** — Stdin. $nasty" "$work/_docs/requirements.md" || ok=1
  [[ "$(head -1 "$work/A.java")" == "// TODO Code Review: $nasty ("* ]] || ok=1
  prop_check text "'-' reads the text from stdin" "$ok" \
    "raw.md: $(tr '\n' '~' < "$work/_docs/Cart/raw.md") A.java: $(tr '\n' '~' < "$work/A.java")"

  out="$(cd "$work" && printf 'a\nb\n' | "$EDITOR_SH" marker A.java 1 - 2>&1)"; rc=$?
  ok=0; [[ $rc -eq 2 && "$out" == *"holds a newline"* ]] || ok=1
  [[ "$(grep -c '' "$work/A.java")" == "4" ]] || ok=1
  prop_check text "a marker of two lines is a stop" "$ok" "exit $rc: $out"

  # ── marker -, the batch ─────────────────────────────────────────
  # Records in any order land above the lines they name as the file stood before
  # the call; two on one line keep their order; the text is the rest of the line.
  local b1
  mkdir -p "$work/batch" && printf '1\n2\n3\n4\n5\n' > "$work/batch/B.java" && printf 'x\n  y\n' > "$work/batch/b.py"
  out="$(cd "$work/batch" && "$EDITOR_SH" marker - 2>&1 <<SDD_RECS
B.java|2|first on 2
B.java|4|on 4, with a | inside and $nasty
b.py|2|py
B.java|2|second on 2
SDD_RECS
)"; rc=$?
  b1="$(sed 's/ ([0-9-]*)$//' "$work/batch/B.java" | tr '\n' '~')"
  ok=0; [[ $rc -eq 0 ]] || ok=1
  [[ "$b1" == "1~// TODO Code Review: first on 2~// TODO Code Review: second on 2~2~3~// TODO Code Review: on 4, with a | inside and $nasty~4~5~" ]] || ok=1
  [[ "$(sed -n 2p "$work/batch/b.py")" == "  # TODO Code Review: py ("* ]] || ok=1
  [[ "$(printf '%s\n' "$out" | sed -n '/^MARKERS:$/,$p' | sed 1d | tr '\n' ' ')" == "B.java:4 B.java:2 B.java:2 b.py:2 " ]] || ok=1
  prop_check text "marker - writes every record bottom-up" "$ok" "exit $rc: $(printf '%s' "$out" | tr '\n' '~') B.java: $b1"

  # One bad record writes nothing, and every bad one is named.
  cp "$work/batch/B.java" "$work/batch/B.before"
  out="$(cd "$work/batch" && printf 'B.java|1|fine\nB.java|99|past the end\nC.json|1|no syntax\n' | "$EDITOR_SH" marker - 2>&1)"; rc=$?
  ok=0; [[ $rc -eq 2 && "$out" == *"record 2:"* && "$out" == *"record 3:"* && "$out" != *"record 1:"* ]] || ok=1
  cmp -s "$work/batch/B.java" "$work/batch/B.before" || ok=1
  prop_check text "marker - checks every record before writing one" "$ok" "exit $rc: $out"

  # ── spawn-prompt.sh, values on stdin ────────────────────────────
  local proj="$TMP/text-prompt" a b
  rm -rf "$proj" && mkdir -p "$proj" && cp -R "$FIXTURES/actualized/tree/." "$proj/" || exit 1
  a="$(cd "$proj" && "$RENDERER" code-fix Cart findings-backend --print "TRIAGE=Fix all." "FINDINGS=F-01 a.java:1 — x
F-02 b.java:2 — y" 2>&1)"
  b="$(cd "$proj" && "$RENDERER" code-fix Cart findings-backend --print - 2>&1 <<'SDD_VALUES'

TRIAGE:
Fix all.

FINDINGS:
F-01 a.java:1 — x
F-02 b.java:2 — y

SDD_VALUES
  )"
  ok=0; [[ -n "$a" && "$a" == "$b" ]] || ok=1
  prop_check text "stdin blocks render as the arguments do" "$ok" "$(diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | tr '\n' '~')"

  b="$(cd "$proj" && "$RENDERER" code-fix Cart findings-backend --print - 2>&1 <<'SDD_VALUES'
TRIAGE:
Keep `$HOME` and \d+ as written.
FINDINGS:
F-01 a.java:1 — x
SDD_VALUES
  )"
  ok=0; printf '%s\n' "$b" | grep -qxF 'Keep `$HOME` and \d+ as written.' || ok=1
  prop_check text "a stdin value is not expanded" "$ok" "$(printf '%s' "$b" | tr '\n' '~')"

  out="$(cd "$proj" && printf 'TRIAGE:\nx\nFINDINGS:\ny\n' | "$RENDERER" code-fix Cart findings-backend - "TRIAGE=z" 2>&1)"; rc=$?
  ok=0; [[ $rc -eq 1 && "$out" == *"given twice"* ]] || ok=1
  prop_check text "a key given twice is refused" "$ok" "exit $rc: $out"

  # Without --print the prompt goes to a file and the spawn call carries one line.
  local file
  out="$(cd "$proj" && "$RENDERER" code-fix Cart findings-backend "TRIAGE=Fix all." "FINDINGS=F-01" 2>&1)"; rc=$?
  file="$proj/.sdd/run/code-fix-Cart-findings-backend.md"
  b="$(cd "$proj" && "$RENDERER" code-fix Cart findings-backend --print "TRIAGE=Fix all." "FINDINGS=F-01" 2>&1)"
  ok=0; [[ $rc -eq 0 && -f "$file" && "$(cat "$file")" == "$b" ]] || ok=1
  [[ "$out" == "PROMPT=$file"$'\n'"PASS=Your assignment is in $file. Read it whole and follow it." ]] || ok=1
  prop_check text "the prompt is written to .sdd/run/ and PASS= names it" "$ok" "exit $rc: $out"
}

# A raw.md that is still the template the scaffold copied holds no description:
# /sdd-next-story runs again over it, and /sdd-specify has nothing to write from.
check_raw() {
  local work="$TMP/raw-check" out rc ok

  printf 'raw\n'
  rm -rf "$work" && mkdir -p "$work/_docs" || exit 1
  ( cd "$work" && "$EDITOR_SH" scaffold feature Cart ) >/dev/null 2>&1

  out="$(cd "$work" && "$GATE" new Cart 2>&1)"
  ok=0; printf '%s\n' "$out" | grep -q '^GATE=ok$' || ok=1
  prop_check raw "next-story runs again over the template" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  out="$(cd "$work" && "$EDITOR_SH" scaffold feature Cart 2>&1)"; rc=$?
  ok=0; [[ $rc -eq 0 ]] || ok=1
  prop_check raw "scaffold feature copies over the template" "$ok" "exit $rc: $out"

  out="$(cd "$work" && "$GATE" specify Cart 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q '^GATE=stop$' || ok=1
  printf '%s\n' "$out" | grep -q 'raw.md holds nothing but the template' || ok=1
  prop_check raw "specify stops on the template" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  ( cd "$work" && "$EDITOR_SH" section _docs/Cart/raw.md Problem - <<<'Shoppers lose their cart.' ) >/dev/null 2>&1
  out="$(cd "$work" && "$GATE" new Cart 2>&1)"
  ok=0; printf '%s\n' "$out" | grep -q 'already holds a description' || ok=1
  out="$(cd "$work" && "$EDITOR_SH" scaffold feature Cart 2>&1)"; rc=$?
  [[ $rc -eq 2 ]] || ok=1
  grep -q 'Shoppers lose their cart.' "$work/_docs/Cart/raw.md" || ok=1
  prop_check raw "a written description is kept" "$ok" "exit $rc: $out"
}

# The tasks a review is told are unfinished by design: the unchecked ones only.
# A task marked [x] that kept an old BLOCKED: reason has code behind it.
check_blocked_set() {
  local work="$TMP/blocked-set" out ok

  printf 'blocked-set\n'
  rm -rf "$work" && mkdir -p "$work/_docs/Cart" || exit 1
  printf 'x\n' > "$work/_docs/code-style.md"
  printf '# Architecture\n\nA monolith.\n' > "$work/_docs/architecture.md"
  for f in new-requirements design; do
    printf -- '---\nstatus: ready\n---\n\n# %s\n\nBody.\n' "$f" > "$work/_docs/Cart/$f.md"
  done
  cat > "$work/_docs/Cart/tasks.md" <<'EOF'
---
status: ready
---

# Tasks — Cart

## Tasks

- [x] **TASK-001** — Done after a retry — BLOCKED: old reason
  - **Requires:** REQ-001
  - **Type:** backend
- [ ] **TASK-002** — Still blocked — BLOCKED: no schema
  - **Requires:** REQ-001
  - **Type:** backend
EOF
  ( cd "$work" && git init -q . && git add -A && git commit -qm base \
    && git checkout -qb feature && printf 'class A {}\n' > A.java ) >/dev/null 2>&1

  out="$(cd "$work" && "$GATE" code-review Cart --prompt-data 2>&1)"
  out="$(printf '%s\n' "$out" | awk '/^[A-Z_]+:$/ { inside = ($0 == "BLOCKED:"); next } inside && NF')"
  ok=0; [[ "$out" == "TASK-002|Still blocked|no schema" ]] || ok=1
  prop_check blocked-set "only unchecked tasks are excused" "$ok" "BLOCKED: $(printf '%s' "$out" | tr '\n' '~')"

  # A fix run marks the report stale whatever it said, BLOCKED included, so a
  # stale report holds promotion back the way a blocked one does.
  local proj="$TMP/stale-actualize"
  rm -rf "$proj" && mkdir -p "$proj" && cp -R "$FIXTURES/actualized/tree/." "$proj/" || exit 1
  ( cd "$proj" && "$EDITOR_SH" verdict-stale Cart ) >/dev/null 2>&1
  out="$(cd "$proj" && "$GATE" actualize Cart 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q '^GATE=ask$' || ok=1
  printf '%s\n' "$out" | awk '/^[A-Z_]+:$/ { inside = ($0 == "ASK:"); next } inside' | grep -q "says 'stale" || ok=1
  prop_check blocked-set "a stale report is asked about before promotion" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  # The marker sweep scaffold review writes into the report's last section.
  ( cd "$proj" && git init -q . \
      && printf 'class A {\n  // TODO Code Review: the total ignores the discount (2026-11-01)\n}\n' > A.java \
      && printf '<!-- TODO Code Review: label missing (2026-11-02) -->\n' > a.html \
      && printf -- '- TODO Code Review: not code (2026-11-03)\n' > _docs/note.md ) >/dev/null 2>&1
  out="$(cd "$proj" && "$EDITOR_SH" scaffold review Cart 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q '^MARKERS=2$' || ok=1
  grep -qxF -- '- `A.java:2` — the total ignores the discount (2026-11-01)' "$proj/_docs/Cart/review.md" || ok=1
  grep -qxF -- '- `a.html:1` — label missing (2026-11-02)' "$proj/_docs/Cart/review.md" || ok=1
  grep -q 'not code' "$proj/_docs/Cart/review.md" && ok=1
  prop_check blocked-set "the report lists the markers in the tree, _docs/ aside" "$ok" "$out — $(sed -n '/^## Older/,$p' "$proj/_docs/Cart/review.md" | tr '\n' '~')"
}

# The starting point of a feature: written once, read by the review set, which
# then holds this feature's code and names what was dirty before it began.
check_start() {
  local work="$TMP/start" out ok first sec

  printf 'start\n'
  rm -rf "$work" && mkdir -p "$work/_docs/Cart" || exit 1
  out="$(cd "$work" && "$EDITOR_SH" start Cart 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q '^START=none$' || ok=1
  [[ -e "$work/_docs/Cart/.implement-start" ]] && ok=1
  prop_check start "outside git nothing is written" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  ( cd "$work" && git init -q . && git add -A && git commit -qm base --allow-empty && git branch -M base \
      && git checkout -qb feature && printf 'other\n' > Other.java && git add -A && git commit -qm other \
      && printf 'dirty\n' > Dirty.java ) >/dev/null 2>&1
  out="$(cd "$work" && "$EDITOR_SH" start Cart 2>&1)"
  first="$(cd "$work" && git rev-parse HEAD)"
  ok=0
  printf '%s\n' "$out" | grep -q '^START=written$' || ok=1
  grep -qx "COMMIT=$first" "$work/_docs/Cart/.implement-start" || ok=1
  grep -qx 'Dirty.java' "$work/_docs/Cart/.implement-start" || ok=1
  prop_check start "the commit and the dirty files are recorded" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  ( cd "$work" && git commit -q --allow-empty -m later ) >/dev/null 2>&1
  out="$(cd "$work" && "$EDITOR_SH" start Cart 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q '^START=kept$' || ok=1
  grep -qx "COMMIT=$first" "$work/_docs/Cart/.implement-start" || ok=1
  prop_check start "a re-run keeps the first record" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  printf 'class Mine {}\n' > "$work/Mine.java"
  out="$(cd "$work" && "$SCRIPTS/review-set.sh" --start=_docs/Cart/.implement-start 2>&1)"
  sec() { printf '%s\n' "$out" | awk -v h="$1:" '/^[A-Z_]+:$/ { inside = ($0 == h); next } inside && NF' | tr '\n' ','; }
  ok=0
  printf '%s\n' "$out" | grep -qx "ROOT=$first" || ok=1
  [[ "$(sec UNTRACKED)" == "Dirty.java,Mine.java," ]] || ok=1
  [[ "$(sec PREEXISTING)" == "Dirty.java," ]] || ok=1
  printf '%s\n' "$out" | grep -q 'Other.java' && ok=1
  prop_check start "the set starts at the feature, the dirty files named" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  mkdir -p "$work/web" && printf '{}\n' > "$work/web/package-lock.json" && printf 'x\n' > "$work/yarn.lock"
  printf 'more\n' >> "$work/Other.java"
  out="$(cd "$work" && "$SCRIPTS/review-set.sh" --start=_docs/Cart/.implement-start 2>&1)"
  ok=0
  [[ "$(sec EXCLUDED)" == "web/package-lock.json,yarn.lock," ]] || ok=1
  [[ "$(sec UNTRACKED)" == "Dirty.java,Mine.java," ]] || ok=1
  [[ "$(sec FILES)" == "1|0|Other.java," ]] || ok=1
  rm -rf "$work/web" "$work/yarn.lock"; ( cd "$work" && git checkout -q -- Other.java )
  prop_check start "lock files are named apart, the diff's files counted" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  out="$(cd "$work" && "$SCRIPTS/review-set.sh" base --start=_docs/Cart/.implement-start 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q 'Other.java' || ok=1
  [[ -z "$(sec PREEXISTING)" ]] || ok=1
  prop_check start "an explicit base wins over the starting point" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  ( cd "$work" && git reset -q --hard base && git commit -q --allow-empty -m rewritten ) >/dev/null 2>&1
  out="$(cd "$work" && "$GATE" code-review Cart 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q 'no longer in the history of HEAD' || ok=1
  printf '%s\n' "$out" | grep -qx "ROOT=$first" && ok=1
  prop_check start "a starting commit a reset dropped falls back with a warning" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"
}

# The feedback log: off by default and silent, on only with SDD_FEEDBACK=1 —
# then the gate says so, every prompt closes with the call for its role, and a
# record lands in .sdd/log/feedback.log. It is written and never read, so these
# cases are what notice it broken.
check_feedback() {
  local work="$TMP/feedback" out rc ok

  printf 'feedback\n'
  rm -rf "$work" && cp -R "$FIXTURES/two-stacks/tree" "$work" && rm -rf "$work/.sdd" && mkdir -p "$work/.sdd" || exit 1
  printf 'SDD_BUILD_BACKEND=mvn verify\nSDD_BUILD_FRONTEND=npm test\n' > "$work/.sdd/sdd.conf"

  out="$(cd "$work" && printf 'x\n' | "$SCRIPTS/feedback.sh" script --by=r --command=implement - 2>&1)"; rc=$?
  ok=0
  [[ $rc -eq 0 && "$out" == "FEEDBACK=off" && ! -e "$work/.sdd/log/feedback.log" ]] || ok=1
  (cd "$work" && "$GATE" implement Cart 2>&1) | grep -q '^FEEDBACK=' && ok=1
  (cd "$work" && "$SCRIPTS/spawn-prompt.sh" implement Cart backend HELD=none --print 2>&1) | grep -q 'feedback.sh' && ok=1
  prop_check feedback "off: nothing written, no key, no word in a prompt" "$ok" "exit $rc: $out"

  printf 'SDD_FEEDBACK=1\n' >> "$work/.sdd/sdd.conf"
  out="$(cd "$work" && "$GATE" implement Cart 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -qx 'FEEDBACK=on' || ok=1
  out="$(cd "$work" && "$SCRIPTS/spawn-prompt.sh" implement Cart backend HELD=none --print 2>&1)"
  printf '%s\n' "$out" | grep -qF ".sdd/scripts/feedback.sh <kind> --by=backend-developer --command=implement --feature=Cart - <<'SDD_TEXT'" || ok=1
  prop_check feedback "on: the gate says so, the prompt carries the filled-in call" "$ok" "$(printf '%s' "$out" | tail -n 15 | tr '\n' '~')"

  out="$(cd "$work" && env -u SDD_LOG_DIR SDD_LOG=0 "$SCRIPTS/feedback.sh" missing --by=backend-developer --command=implement --feature=Cart - <<'SDD_TEXT' 2>&1
the prompt named no `code-style.md` $HOME
SDD_TEXT
)"; rc=$?
  ok=0
  [[ $rc -eq 0 && "$out" == "FEEDBACK=written" ]] || ok=1
  grep -q '^## .* | missing | backend-developer | implement | Cart$' "$work/.sdd/log/feedback.log" || ok=1
  grep -qF 'the prompt named no `code-style.md` $HOME' "$work/.sdd/log/feedback.log" || ok=1
  prop_check feedback "a record is written as given, SDD_LOG=0 notwithstanding" "$ok" "exit $rc: $out"

  out="$(cd "$work" && printf 'x\n' | "$SCRIPTS/feedback.sh" opinion --by=r --command=implement - 2>&1)"; rc=$?
  ok=0
  [[ $rc -eq 2 ]] || ok=1
  out="$(cd "$work" && printf '  \n' | "$SCRIPTS/feedback.sh" script --by=r --command=implement - 2>&1)"; rc=$?
  [[ $rc -eq 2 ]] || ok=1
  prop_check feedback "a kind off the list and an empty remark are refused" "$ok" "exit $rc: $out"
}

# The two stops of /sdd-spec-review that used to be judged by eye: the coverage
# matrix, and whether a file with a question still on it may be called ready.
check_spec_review() {
  local work="$TMP/spec-review-check" out rc ok

  printf 'spec-review\n'
  rm -rf "$work" && mkdir -p "$work/_docs/Cart" || exit 1
  cat > "$work/_docs/Cart/new-requirements.md" <<'EOF'
---
status: draft
---

# Requirements — Cart

## Requirements

### REQ-001 — Cart total
- **Description:** x ^req-001

### REQ-002 — Promo codes
- **Description:** y ^req-002

## Open Questions

<!-- hint -->
- Which currency? — recommended: EUR, A-01

## Out of Scope

### REQ-003 — Gift wrapping
EOF
  cat > "$work/_docs/Cart/tasks.md" <<'EOF'
---
status: draft
---

# Tasks — Cart

## Tasks

- [ ] **TASK-001** — Total
  - **Requires:** [REQ-001](new-requirements.md#^req-001), REQ-009
  - **Type:** backend
EOF

  out="$(cd "$work" && "$SCRIPTS/feature-state.sh" Cart 2>&1)"
  ok=0
  [[ "$(printf '%s\n' "$out" | awk '/^[A-Z_]+:$/ { s = $0; next } s == "UNCOVERED:" && NF')" == "REQ-002|Promo codes" ]] || ok=1
  [[ "$(printf '%s\n' "$out" | awk '/^[A-Z_]+:$/ { s = $0; next } s == "UNDECLARED:" && NF')" == "TASK-001|REQ-009" ]] || ok=1
  prop_check spec-review "the matrix stops are computed" "$ok" "$(printf '%s' "$out" | sed -n '/^UNCOVERED:/,/^ANOMALIES:/p' | tr '\n' '~')"

  out="$(cd "$work" && "$EDITOR_SH" status Cart ready new-requirements.md tasks.md 2>&1)"; rc=$?
  ok=0
  [[ $rc -eq 2 && "$out" == *"Open Questions is not empty in: _docs/Cart/new-requirements.md (1 line(s))"* ]] || ok=1
  grep -q '^status: draft$' "$work/_docs/Cart/tasks.md" || ok=1
  prop_check spec-review "ready is refused over an open question" "$ok" "exit $rc: $out"

  out="$(cd "$work" && "$EDITOR_SH" status Cart ready new-requirements.md tasks.md --accept-open 2>&1)"; rc=$?
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  grep -q '^status: ready$' "$work/_docs/Cart/new-requirements.md" || ok=1
  prop_check spec-review "--accept-open readies it as it stands" "$ok" "exit $rc: $out"

  # ── The human's answers ─────────────────────────────────────────
  # Line 18 is the question, 17 the hint comment, 10 a requirement.
  local f="$work/_docs/Cart/new-requirements.md" n_before
  n_before="$(grep -c '' "$f")"
  out="$(cd "$work" && "$EDITOR_SH" answer _docs/Cart/new-requirements.md 18 - 2>&1 <<'SDD_TEXT'
EUR and `USD`, $5 \d
SDD_TEXT
  )"; rc=$?
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  [[ "$(sed -n 18p "$f")" == '- Which currency? — recommended: EUR, A-01 **Answer:** EUR and `USD`, $5 \d' ]] || ok=1
  [[ "$(grep -c '' "$f")" == "$n_before" ]] || ok=1
  prop_check spec-review "an answer is appended to its line and moves none" "$ok" "exit $rc: $out — $(sed -n 18p "$f")"

  ok=0
  for at in 18 17 10 99 x; do
    out="$(cd "$work" && "$EDITOR_SH" answer _docs/Cart/new-requirements.md "$at" "no" 2>&1)"; rc=$?
    [[ $rc -eq 2 ]] || ok=1
  done
  [[ "$(grep -c 'Answer:' "$f")" == "1" ]] || ok=1
  prop_check spec-review "an answer lands on an open question or nowhere" "$ok" "last: exit $rc: $out"

  out="$(cd "$work" && "$EDITOR_SH" answer _docs/Cart/new-requirements.md new "REQ-002 has no task" 2>&1)"; rc=$?
  ok=0; [[ $rc -eq 2 && "$out" == *"carries it"* ]] || ok=1
  out="$(cd "$work" && "$EDITOR_SH" answer _docs/Cart/new-requirements.md new "REQ-002 has no task — **Answer:** not in this feature" 2>&1)"; rc=$?
  [[ $rc -eq 0 && "$out" == *":19"* ]] || ok=1
  [[ "$(sed -n 19p "$f")" == '- REQ-002 has no task — **Answer:** not in this feature' ]] || ok=1
  [[ "$(sed -n 20p "$f")" == '' && "$(sed -n 21p "$f")" == '## Out of Scope' ]] || ok=1
  prop_check spec-review "a decision nobody asked about is a line of its own" "$ok" "exit $rc: $out — $(sed -n 17,21p "$f" | tr '\n' '~')"

  printf -- '---\nstatus: draft\n---\n\n## Open Questions\n' > "$work/_docs/Cart/design.md"
  out="$(cd "$work" && "$EDITOR_SH" answer _docs/Cart/design.md new "Add a task? **Answer:** yes" 2>&1)"; rc=$?
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  [[ "$(sed -n '5,7p' "$work/_docs/Cart/design.md" | tr '\n' '~')" == '## Open Questions~~- Add a task? **Answer:** yes~' ]] || ok=1
  prop_check spec-review "a new line goes into an empty section" "$ok" "exit $rc: $out — $(tr '\n' '~' < "$work/_docs/Cart/design.md")"

  # The scope of a review round is read off the page: an answered line in a
  # file's ## Open Questions makes its record a fold, and the other file stays
  # a full review.
  printf -- '---\nstatus: draft\n---\n# R\n\n## Requirements\n\n### REQ-001 — Cart total\n\n## Open Questions\n\n- Which currency? — recommended: EUR, A-01\n' > "$work/_docs/Cart/new-requirements.md"
  printf -- '---\nstatus: draft\n---\n# Design — Cart\n\n## Open Questions\n\n<!-- - x **Answer:** y -->\n' > "$work/_docs/Cart/design.md"
  printf '# Raw\n' > "$work/_docs/Cart/raw.md"
  out="$(cd "$work" && "$GATE" review Cart 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q '|requirements$' || ok=1
  printf '%s\n' "$out" | grep -q '|design+tasks$' || ok=1
  prop_check spec-review "no answered line: both files get the full review" "$ok" "$(printf '%s' "$out" | sed -n '/^SPAWN:/,/^$/p' | tr '\n' '~')"

  printf -- '---\nstatus: draft\n---\n# R\n\n## Requirements\n\n### REQ-001 — Cart total\n\n## Open Questions\n\n- Which currency? — recommended: EUR, A-01 **Answer:** EUR\n' > "$work/_docs/Cart/new-requirements.md"
  out="$(cd "$work" && "$GATE" review Cart 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q '^requirements-engineer|.sdd/protocols/spec-modes.md,.sdd/protocols/requirements-writing.md,.sdd/protocols/docs-format.md|fold-requirements$' || ok=1
  printf '%s\n' "$out" | grep -q '|design+tasks$' || ok=1
  prop_check spec-review "an answered line makes that file's round a fold, without the checklist" "$ok" "$(printf '%s' "$out" | sed -n '/^SPAWN:/,/^$/p' | tr '\n' '~')"
}

# The build answer goes into .sdd/sdd.conf through a script, so that whoever
# writes it never reads a file that may hold a token.
check_conf_set() {
  local work="$TMP/conf-set" out rc ok

  printf 'conf-set\n'
  rm -rf "$work" && mkdir -p "$work" || exit 1

  out="$(cd "$work" && printf '%s\n' 'mvn verify -Dgroups="fast"' | "$EDITOR_SH" conf-set SDD_BUILD_ROOT - 2>&1)"
  ok=0
  [[ "$out" == *"ACTION=added"* ]] || ok=1
  [[ "$(cat "$work/.sdd/sdd.conf")" == 'SDD_BUILD_ROOT=mvn verify -Dgroups="fast"' ]] || ok=1
  [[ "$("$SCRIPTS/build-command.sh" "$work" | sed -n 's/^ROOT=//p')" == 'mvn verify -Dgroups="fast"' ]] || ok=1
  prop_check conf-set "creates the file, and the reader reads it back" "$ok" "$out / $(tr '\n' '~' < "$work/.sdd/sdd.conf")"

  printf 'JIRA_TOKEN=secret\n# a comment\nSDD_BUILD_ROOT=old\nSDD_LOG=0' > "$work/.sdd/sdd.conf"
  out="$(cd "$work" && "$EDITOR_SH" conf-set SDD_BUILD_ROOT 'make all' 2>&1)"
  ok=0
  [[ "$out" == *"ACTION=replaced"* && "$out" != *secret* ]] || ok=1
  [[ "$(cat "$work/.sdd/sdd.conf")" == $'JIRA_TOKEN=secret\n# a comment\nSDD_BUILD_ROOT=make all\nSDD_LOG=0' ]] || ok=1
  out="$(cd "$work" && "$EDITOR_SH" conf-set SDD_BUILD_FRONTEND 'npm test' 2>&1)"
  [[ "$(tail -2 "$work/.sdd/sdd.conf")" == $'SDD_LOG=0\nSDD_BUILD_FRONTEND=npm test' ]] || ok=1
  out="$(cd "$work" && "$EDITOR_SH" conf-set SDD_BUILD_ROOT 'make all' 2>&1)"
  [[ "$out" == *"ACTION=unchanged"* ]] || ok=1
  prop_check conf-set "rewrites one line, appends, and leaves an answer alone" "$ok" "$out / $(tr '\n' '~' < "$work/.sdd/sdd.conf")"


  out="$(cd "$work" && "$EDITOR_SH" conf-set JIRA_TOKEN x 2>&1)"; rc=$?
  ok=0; [[ $rc -eq 2 ]] || ok=1
  grep -q '^JIRA_TOKEN=secret$' "$work/.sdd/sdd.conf" || ok=1
  prop_check conf-set "writes build keys only" "$ok" "exit $rc: $out"

  # A key set twice: the reader takes the last line, so that is the one written.
  local dup="$TMP/conf-set-dup"
  rm -rf "$dup" && mkdir -p "$dup/.sdd" || exit 1
  printf 'SDD_BUILD_ROOT=first\n  SDD_BUILD_ROOT = "second"\n' > "$dup/.sdd/sdd.conf"
  out="$(cd "$dup" && "$EDITOR_SH" conf-set SDD_BUILD_ROOT second 2>&1)"
  ok=0
  [[ "$out" == *"ACTION=unchanged"* ]] || ok=1
  out="$(cd "$dup" && "$EDITOR_SH" conf-set SDD_BUILD_ROOT third 2>&1)"
  [[ "$(cat "$dup/.sdd/sdd.conf")" == $'SDD_BUILD_ROOT=first\nSDD_BUILD_ROOT=third' ]] || ok=1
  [[ "$("$SCRIPTS/build-command.sh" "$dup" | sed -n 's/^ROOT=//p')" == 'third' ]] || ok=1
  prop_check conf-set "a key set twice is written where the reader reads it" "$ok" "$out / $(tr '\n' '~' < "$dup/.sdd/sdd.conf")"
}

# The backups: one feature and the project's files per snapshot, and only the
# last SDD_BACKUP_KEEP snapshots kept — never a folder the op did not name.
check_backup() {
  local work="$TMP/backup" out ok i left

  printf 'backup\n'
  rm -rf "$work" && mkdir -p "$work/.sdd" "$work/_docs/Cart" "$work/_docs/Promo" "$work/_docs/architecture" "$work/_docs/.backup/mine" || exit 1
  for f in requirements.md architecture/01-context.md Cart/tasks.md Promo/tasks.md; do printf 'x\n' > "$work/_docs/$f"; done
  for i in 1 2 3 4; do mkdir -p "$work/_docs/.backup/2026010$i-000000"; done
  printf 'SDD_BACKUP_KEEP=3\n' > "$work/.sdd/sdd.conf"
  out="$(cd "$work" && "$EDITOR_SH" backup cart 2>&1)"
  left="$(cd "$work/_docs/.backup" && ls | tr '\n' ' ')"
  ok=0
  printf '%s\n' "$out" | grep -qx 'FILES=3' || ok=1
  printf '%s\n' "$out" | grep -qx 'PRUNED=2' || ok=1
  printf '%s\n' "$out" | grep -q 'Promo' && ok=1
  [[ "$left" == 20260103-000000\ 20260104-000000\ 2*\ mine\  ]] || ok=1
  prop_check backup "one feature and the project's files, the oldest pruned, the rest left" "$ok" "$(printf '%s' "$out" | tr '\n' '~') / left: $left"
}

# A two-stack project asks for the build of the stacks a feature builds, and
# no more; a marker goes into the languages a brownfield tree is told by.
check_stacks() {
  local work="$TMP/stacks-check" out ok f

  printf 'stacks\n'
  rm -rf "$work" && mkdir -p "$work/_docs/Cart" "$work/web" "$work/.sdd" || exit 1
  printf '<project/>\n' > "$work/pom.xml"; printf '{}\n' > "$work/web/package.json"
  printf 'SDD_BUILD_BACKEND=mvn verify\n' > "$work/.sdd/sdd.conf"
  for f in new-requirements design; do
    printf -- '---\nstatus: ready\n---\n\n# %s\n\nBody.\n' "$f" > "$work/_docs/Cart/$f.md"
  done
  printf -- '---\nstatus: ready\n---\n\n# Tasks\n\n## Tasks\n\n- [ ] **TASK-001** — a\n  - **Requires:** REQ-001\n  - **Type:** backend\n' \
    > "$work/_docs/Cart/tasks.md"

  out="$(cd "$work" && "$GATE" implement Cart 2>&1)"
  ok=0; printf '%s\n' "$out" | grep -q '^GATE=ok$' || ok=1
  prop_check stacks "a backend-only feature needs no frontend build" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  printf -- '- [ ] **TASK-002** — b\n  - **Requires:** REQ-001\n  - **Type:** frontend\n' >> "$work/_docs/Cart/tasks.md"
  out="$(cd "$work" && "$GATE" implement Cart 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q '^GATE=ask$' || ok=1
  printf '%s\n' "$out" | grep -q 'holds no SDD_BUILD_FRONTEND' || ok=1
  prop_check stacks "a frontend task asks for the frontend build" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  # The proposal names only the scripts package.json has: a `build` it lacks
  # would fail before a test ran.
  printf '{ "scripts": { "test": "node --test" } }\n' > "$work/web/package.json"
  out="$(cd "$work" && "$SCRIPTS/build-command.sh" . 2>&1)"
  ok=0; printf '%s\n' "$out" | grep -qx 'web|package.json|cd web && npm test|frontend' || ok=1
  printf '{ "scripts": { "build": "tsc", "test": "jest" } }\n' > "$work/web/package.json"
  out="$out~$(cd "$work" && "$SCRIPTS/build-command.sh" . 2>&1)"
  printf '%s\n' "$out" | grep -qx 'web|package.json|cd web && npm run build && npm test|frontend' || ok=1
  printf '{}\n' > "$work/web/package.json"
  prop_check stacks "the npm proposal names only the scripts package.json has" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  # The same backend-only feature under /sdd-code-fix: a finding is about this
  # feature's code, so its stacks are the breakdown's.
  ( cd "$work" && sed -i.bak '/TASK-002/,$d' _docs/Cart/tasks.md && rm -f _docs/Cart/tasks.md.bak \
      && printf -- '---\nverdict: BLOCKED\n---\n\n# Review\n' > _docs/Cart/review.md )
  out="$(cd "$work" && "$GATE" code-fix Cart 2>&1)"
  ok=0; printf '%s\n' "$out" | grep -q 'SDD_BUILD_FRONTEND' && ok=1
  prop_check stacks "code-fix asks only for the stacks the feature has" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  # Backend done, frontend open: the backend role is not spawned, so its build
  # is not asked for.
  printf -- '- [ ] **TASK-002** — b\n  - **Requires:** REQ-001\n  - **Type:** frontend\n' >> "$work/_docs/Cart/tasks.md"
  ( cd "$work" && sed -i.bak 's/- \[ \] \*\*TASK-001/- [x] **TASK-001/' _docs/Cart/tasks.md && rm -f _docs/Cart/tasks.md.bak \
      && printf 'SDD_BUILD_FRONTEND=npm test\n' > .sdd/sdd.conf )
  out="$(cd "$work" && "$GATE" implement Cart 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q '^GATE=ok$' || ok=1
  printf '%s\n' "$out" | grep -q '^ROLE_ORDER=frontend$' || ok=1
  printf '%s\n' "$out" | grep -q '^backend-developer' && ok=1
  prop_check stacks "a stack with every task done is not spawned" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  # One package.json and backend tasks: detection sees a frontend only. The root
  # command stands in for the backend, and with none the backend is asked for.
  rm -f "$work/pom.xml"; rm -rf "$work/web"; printf '{}\n' > "$work/package.json"
  ( cd "$work" && sed -i.bak 's/- \[x\] \*\*TASK-001/- [ ] **TASK-001/; s/Type:\*\* frontend/Type:** backend/' _docs/Cart/tasks.md \
      && rm -f _docs/Cart/tasks.md.bak && printf 'SDD_BUILD_ROOT=npm test\n' > .sdd/sdd.conf )
  out="$(cd "$work" && "$GATE" implement Cart 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q '^GATE=ok$' || ok=1
  printf '%s\n' "$out" | grep -q '^BUILD_BACKEND=npm test$' || ok=1
  prop_check stacks "the root command stands in for an undetected stack" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  printf 'SDD_BUILD_FRONTEND=npm test\n' > "$work/.sdd/sdd.conf"
  out="$(cd "$work" && "$GATE" implement Cart 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q '^GATE=ask$' || ok=1
  printf '%s\n' "$out" | grep -q 'No build command for the backend stack: the tasks of this feature build it' || ok=1
  prop_check stacks "an undetected stack with no answer is asked for" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  ok=0
  for f in a.rs b.php c.kts d.swift; do
    printf 'x\n' > "$work/$f"
    ( cd "$work" && "$EDITOR_SH" marker "$f" 1 note ) >/dev/null 2>&1 || ok=1
    grep -q '^// TODO Code Review: note' "$work/$f" || ok=1
  done
  prop_check stacks "markers in rs, php, kts, swift" "$ok" "$(head -1 "$work/a.rs")"
}

# Two features handed one number, and a reworded entry that was retired: the
# promotion stops instead of writing one feature's requirement over another's.
check_collisions() {
  local work="$TMP/collisions" out rc ok line
  printf 'collisions\n'
  rm -rf "$work" && mkdir -p "$work/_docs/Promo" "$work/_docs/Cart" || exit 1
  cat > "$work/_docs/requirements.md" <<'EOR'
<!-- Next free number: REQ-003 -->

## Requirements

- **REQ-001** — Catalog listing. A shopper browses. *(Source: Catalog)* ^req-001
- **REQ-002** — Cart holds items. A shopper keeps items. *(Source: Cart, superseded by REQ-009)* ^req-002
EOR
  printf -- '---\nstatus: ready\n---\n\n# R\n\n## Requirements\n\n### REQ-001 — Promo codes\n- **Description:** x ^req-001\n' > "$work/_docs/Promo/new-requirements.md"
  printf -- '---\nstatus: ready\n---\n\n# D\n\nBody.\n' > "$work/_docs/Promo/design.md"
  printf -- '---\nstatus: ready\n---\n\n# T\n\n## Tasks\n\n- [x] **TASK-001** — P\n  - **Requires:** REQ-001\n  - **Type:** backend\n' > "$work/_docs/Promo/tasks.md"
  printf 'raw\n' > "$work/_docs/Promo/raw.md"
  mkdir -p "$work/_docs/architecture" && printf '# Overview\n\nText.\n' > "$work/_docs/architecture/01-system-overview.md"
  printf '| Topic | Path |\n' > "$work/_docs/architecture.index.md"

  out="$(cd "$work" && "$GATE" actualize Promo 2>&1)"
  ok=0
  printf '%s\n' "$out" | grep -q '^GATE=stop$' || ok=1
  printf '%s\n' "$out" | grep -q 'already holds REQ-001 as an entry of Catalog — two features were handed one number' || ok=1
  prop_check collisions "actualize stops on a number another feature's entry holds" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  out="$(cd "$work" && "$EDITOR_SH" compile-entry Promo REQ-001 final "Promo codes. x" 2>&1)"; rc=$?
  ok=0; [[ $rc -eq 2 && "$out" == *"is an entry of Catalog, not of Promo"* ]] || ok=1
  grep -q 'Catalog listing. A shopper browses. \*(Source: Catalog)\*' "$work/_docs/requirements.md" || ok=1
  prop_check collisions "final never writes over another feature's entry" "$ok" "exit $rc: $out"

  out="$(cd "$work" && "$GATE" actualize Promo --verify 2>&1)"; rc=$?
  ok=0; [[ $rc -eq 2 && "$out" == *"is an entry of Catalog, not of Promo"* ]] || ok=1
  prop_check collisions "verify does not count another feature's entry" "$ok" "exit $rc: $(printf '%s' "$out" | tr '\n' '~')"

  # Refining a retired entry is a stop; refining a live one keeps every mark.
  printf -- '---\nstatus: ready\n---\n\n# R\n\n## Requirements\n\n### REQ-004 — Bigger cart\n- **Refines:** REQ-002\n- **Description:** x ^req-004\n' > "$work/_docs/Promo/new-requirements.md"
  out="$(cd "$work" && "$GATE" actualize Promo 2>&1)"
  ok=0; printf '%s\n' "$out" | grep -q 'REQ-002 is superseded by REQ-009 — a retired requirement is not reworded' || ok=1
  prop_check collisions "a retired entry is not refined" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  ( cd "$work" && "$EDITOR_SH" compile-entry Promo REQ-002 refine "Cart holds items. More of them." ) >/dev/null 2>&1
  line="$(grep 'REQ-002\*\*' "$work/_docs/requirements.md")"
  ok=0; [[ "$line" == *'*(Source: Cart, refined by Promo, superseded by REQ-009)*'* ]] || ok=1
  prop_check collisions "a rewording keeps the superseded mark" "$ok" "the entry reads: $line"

  # Two features declaring one number, reported before either is promoted.
  printf -- '---\nstatus: draft\n---\n\n## Requirements\n\n### REQ-004 — Cart badge\n' > "$work/_docs/Cart/new-requirements.md"
  out="$(cd "$work" && "$SCRIPTS/next-req.sh" . 2>&1)"
  ok=0; printf '%s\n' "$out" | awk '/^[A-Z_]+:$/ { s = $0; next } s == "COLLISIONS:" && NF' | grep -qx 'REQ-004|Cart,Promo' || ok=1
  out="$(cd "$work" && "$GATE" actualize Promo 2>&1)"
  printf '%s\n' "$out" | grep -q 'Declared by more than one feature: REQ-004 (Cart,Promo)' || ok=1
  prop_check collisions "one number declared by two features is reported" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"
}

# A feature that declares no requirement has no compilation entry to be told
# actualized by: the `actualized:` property of its new-requirements.md is the
# mark, written by spec-edit.sh as the last write of the promotion.
# The findings of a review, as /sdd-code-fix gets them: the place out of either
# form of `Where:`, a range read as its first line, and the stack of the build
# file nearest above the file — `-` where no build file settles it.
check_findings() {
  local work="$TMP/findings-check" out ok exp f
  printf 'findings\n'
  rm -rf "$work" && mkdir -p "$work/_docs/Cart" "$work/web" "$work/.sdd" || exit 1
  printf '{}\n' > "$work/web/package.json"
  mkdir -p "$work/api" && printf '<project/>\n' > "$work/api/pom.xml"
  printf 'SDD_BUILD_BACKEND=mvn verify\nSDD_BUILD_FRONTEND=cd web && npm test\n' > "$work/.sdd/sdd.conf"
  for f in new-requirements design; do
    printf -- '---\nstatus: ready\n---\n\n# %s\n\nBody.\n' "$f" > "$work/_docs/Cart/$f.md"
  done
  printf -- '---\nstatus: ready\n---\n\n# T\n\n## Tasks\n\n- [x] **TASK-001** — a\n  - **Type:** backend\n- [x] **TASK-002** — b\n  - **Type:** frontend\n' \
    > "$work/_docs/Cart/tasks.md"
  cat > "$work/_docs/Cart/review.md" <<'SDD_REVIEW'
---
verdict: BLOCKED
---

# Code Review — Cart

## Findings

<!--
### F-09 — Critical — Security

> [!danger] Where: `api/X.java:1`
-->

### F-01 — Critical — Security

> [!danger] Where: `api/src/Cart.java:42`
> **What:** x

### F-02 — Minor — Style

> [!note] Where: `web/src/app.ts:10-14`

### F-03 — Suggestion — Quality

> [!tip] Where: `README.md`

### F-04 — Major — Spec Deviation

> [!warning] **What:** no place.

### F-05 — Major — Performance
- **Where:** `api/src/Repo.java:7`

## Requirement coverage

Where: `api/Elsewhere.java:3`
SDD_REVIEW
  exp='F-01|Critical|Security|api/src/Cart.java|42|backend
F-02|Minor|Style|web/src/app.ts|10|frontend
F-03|Suggestion|Quality|README.md|-|-
F-04|Major|Spec Deviation|-|-|-
F-05|Major|Performance|api/src/Repo.java|7|backend'
  out="$(cd "$work" && "$GATE" code-fix Cart 2>&1)"
  ok=0; [[ "$(printf '%s\n' "$out" | sed -n '/^FINDINGS:$/,/^$/p' | sed '1d;/^$/d')" == "$exp" ]] || ok=1
  prop_check findings "two stacks: each finding goes to the build file above it" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  # No build file above it: the type of the tasks that name the file decides,
  # and tasks of both types naming it leave the choice to the human.
  printf -- '---\nstatus: ready\n---\n\n# T\n\n## Tasks\n\n- [x] **TASK-001** — a\n  - **Type:** backend\n- [x] **TASK-002** — b\n  - **Type:** frontend\n  - **Description:** Update `README.md`.\n' \
    > "$work/_docs/Cart/tasks.md"
  out="$(cd "$work" && "$GATE" code-fix Cart 2>&1)"
  ok=0; printf '%s\n' "$out" | grep -qx 'F-03|Suggestion|Quality|README.md|-|frontend' || ok=1
  prop_check findings "no build file: the tasks that name the file give the stack" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"
  printf -- '---\nstatus: ready\n---\n\n# T\n\n## Tasks\n\n- [x] **TASK-001** — a\n  - **Type:** backend\n  - **Description:** Link `README.md`.\n- [x] **TASK-002** — b\n  - **Type:** frontend\n  - **Description:** Update `README.md`.\n' \
    > "$work/_docs/Cart/tasks.md"
  out="$(cd "$work" && "$GATE" code-fix Cart 2>&1)"
  ok=0; printf '%s\n' "$out" | grep -qx 'F-03|Suggestion|Quality|README.md|-|-' || ok=1
  prop_check findings "tasks of both types name the file: the human names the role" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  # One stack in the breakdown: every finding is that stack's, placed or not.
  sed -i.bak '/TASK-002/,$d' "$work/_docs/Cart/tasks.md" && rm -f "$work/_docs/Cart/tasks.md.bak"
  out="$(cd "$work" && "$GATE" code-fix Cart 2>&1)"
  ok=0; [[ "$(printf '%s\n' "$out" | sed -n '/^FINDINGS:$/,/^$/p' | grep -c '|backend$')" == "5" ]] || ok=1
  prop_check findings "one stack: every finding is the feature's" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"
}

# A rewrite replaces the file by a rename, so a run cut short never leaves half
# of it. What a rename would lose is kept: the mode of a script a marker lands
# in, and a symlink, which is written through rather than replaced.
check_replace() {
  local work="$TMP/replace-check" edit="$SCRIPTS/spec-edit.sh" ok
  printf 'replace\n'
  rm -rf "$work" && mkdir -p "$work/bin" "$work/real" || exit 1
  printf '#!/bin/sh\necho one\necho two\n' > "$work/bin/run.sh" && chmod 755 "$work/bin/run.sh"
  printf 'a: 1\nb: 2\n' > "$work/real/conf.yml" && ln -s ../real/conf.yml "$work/bin/conf.yml"

  ( cd "$work" && SDD_LOG=0 "$edit" marker bin/run.sh 3 'Two is wrong.' ) >/dev/null 2>&1
  ( cd "$work" && SDD_LOG=0 "$edit" marker bin/conf.yml 2 'B is wrong.' ) >/dev/null 2>&1
  ok=0
  [[ -x "$work/bin/run.sh" ]] && grep -q 'Two is wrong' "$work/bin/run.sh" \
    && [[ -L "$work/bin/conf.yml" ]] && grep -q 'B is wrong' "$work/real/conf.yml" \
    && [[ -z "$(find "$work" -name '*.sdd-new.*')" ]] || ok=1
  prop_check replace "mode and symlink survive" "$ok" \
    "after two markers: run.sh $( [[ -x "$work/bin/run.sh" ]] && echo keeps || echo lost ) +x, conf.yml $( [[ -L "$work/bin/conf.yml" ]] && echo 'is still a link' || echo 'is no longer a link' ), leftovers: $(find "$work" -name '*.sdd-new.*' | tr '\n' ' ')"
}

check_no_requirements() {
  local work="$TMP/no-reqs" state="$SCRIPTS/feature-state.sh" out rc ok f
  printf 'no-requirements\n'
  rm -rf "$work" && mkdir -p "$work/_docs/Tidy" "$work/_docs/architecture" || exit 1
  printf '<!-- Next free number: REQ-002 -->\n\n## Requirements\n\n- **REQ-001** — Catalog. Browse. *(Source: Catalog)* ^req-001\n' > "$work/_docs/requirements.md"
  f="$work/_docs/Tidy/new-requirements.md"
  printf -- '---\ntype: requirements\nstatus: ready\ntags:\n  - sdd/requirements\n---\n\n# R\n\n## Requirements\n\nNone — a refactor.\n' > "$f"
  printf -- '---\nstatus: ready\n---\n\n# D\n\nBody.\n' > "$work/_docs/Tidy/design.md"
  printf -- '---\nstatus: ready\n---\n\n# T\n\n## Tasks\n\n- [x] **TASK-001** — Tidy\n  - **Type:** backend\n' > "$work/_docs/Tidy/tasks.md"
  printf 'raw\n' > "$work/_docs/Tidy/raw.md"
  printf '# Overview\n\nText.\n' > "$work/_docs/architecture/01-system-overview.md"
  printf '| Topic | Path |\n' > "$work/_docs/architecture.index.md"

  out="$(cd "$work" && "$state" Tidy 2>&1)"
  ok=0; printf '%s\n' "$out" | grep -qx 'STAGE=implemented' || ok=1
  [[ "$out" != *"holds no entry sourced by this feature"* ]] || ok=1
  prop_check no-requirements "no mark: implemented, and no complaint about entries it never declared" "$ok" "$(printf '%s' "$out" | tr '\n' '~')"

  out="$(cd "$work" && "$GATE" actualize Tidy --verify 2>&1)"; rc=$?
  ok=0; [[ $rc -eq 2 && "$out" == *"carries no 'actualized:' property"* ]] || ok=1
  prop_check no-requirements "verify fails while the mark is missing" "$ok" "exit $rc: $(printf '%s' "$out" | tr '\n' '~')"

  out="$(cd "$work" && "$EDITOR_SH" actualized Tidy 2>&1)"; rc=$?
  ok=0; [[ $rc -eq 0 ]] || ok=1
  [[ "$(sed -n 3,4p "$f" | tr '\n' '~')" == "status: ready~actualized: $(date +%Y-%m-%d)~" ]] || ok=1
  prop_check no-requirements "the mark goes in as a property under status" "$ok" "exit $rc: $out — $(tr '\n' '~' < "$f")"

  out="$(cd "$work" && "$state" Tidy 2>&1)"
  ok=0; printf '%s\n' "$out" | grep -qx 'STAGE=actualized' || ok=1
  out="$(cd "$work" && "$GATE" actualize Tidy --verify 2>&1)"; rc=$?
  [[ $rc -eq 0 ]] || ok=1
  prop_check no-requirements "with the mark: actualized, and verify passes" "$ok" "exit $rc: $(printf '%s' "$out" | tr '\n' '~')"

  ( cd "$work" && "$EDITOR_SH" actualized Tidy ) >/dev/null 2>&1
  ok=0; [[ "$(grep -c '^actualized:' "$f")" == 1 ]] || ok=1
  prop_check no-requirements "a second run rewrites the mark, never adds one" "$ok" "$(tr '\n' '~' < "$f")"

  # promote takes the same mark for such a feature, and refuses words for it.
  out="$(cd "$work" && "$EDITOR_SH" promote Tidy 2>&1)"; rc=$?
  ok=0
  [[ $rc -eq 0 && "$out" == *"ACTUALIZED=$(date +%Y-%m-%d)"* && "$(grep -c '^actualized:' "$f")" == 1 ]] || ok=1
  out="$(cd "$work" && printf 'REQ-002|x\n' | "$EDITOR_SH" promote Tidy - 2>&1)"; rc=$?
  [[ $rc -eq 2 && "$out" == *'declares no requirement'* ]] || ok=1
  prop_check no-requirements "promote marks it, and refuses wording" "$ok" "exit $rc: $out"

  printf '# R\n\n> Status: ready\n\n## Requirements\n\nNone.\n' > "$f"
  ( cd "$work" && "$EDITOR_SH" actualized Tidy ) >/dev/null 2>&1
  ok=0; [[ "$(sed -n 4p "$f")" == "> Actualized: $(date +%Y-%m-%d)" ]] || ok=1
  prop_check no-requirements "a document without frontmatter gets the blockquote form" "$ok" "$(tr '\n' '~' < "$f")"

  printf -- '---\nstatus: ready\n---\n\n## Requirements\n\n### REQ-002 — Tidy\n- **Description:** x ^req-002\n' > "$f"
  out="$(cd "$work" && "$EDITOR_SH" actualized Tidy 2>&1)"; rc=$?
  ok=0; [[ $rc -eq 2 && "$out" == *"declares REQ-002"* ]] || ok=1
  grep -q 'actualized' "$f" && ok=1
  prop_check no-requirements "a feature with requirements is refused the mark" "$ok" "exit $rc: $out"
}

job_body() {
  local name="$1"; shift
  # Nothing a job runs has a question to ask: every case is scripted, and a
  # script under test that stops for an answer is a bug in the case, not a
  # prompt for whoever started the suite. Closed here rather than at each call
  # site — a job that inherits a terminal blocks the whole run on a read no one
  # is watching.
  exec < /dev/null
  RESULTS="$TMP_ROOT/res/$name"
  : > "$RESULTS"
  printf '1\n' > "$TMP_ROOT/rc/$name"
  job_env "j-$name"
  local start=$SECONDS
  "$@"
  printf '%s %s\n' "$(( SECONDS - start ))" "$name" > "$TMP_ROOT/time/$name"
  printf '0\n' > "$TMP_ROOT/rc/$name"
}

KNOWN_CHECKS=","
start_job() {
  local name="$1"
  case "$name" in
    fixture-*) ;;
    *) KNOWN_CHECKS="$KNOWN_CHECKS$name,"
       [[ -z "$CHECKS" || ",$CHECKS," == *",$name,"* ]] || return 0 ;;
  esac
  JOB_NAMES+=("$name")
  if (( JOBS == 1 )); then
    ( job_body "$@" ) > "$TMP_ROOT/out/$name" 2>&1
    return 0
  fi
  while (( $(jobs -rp | wc -l) >= JOBS )); do wait -n 2>/dev/null || true; done
  ( job_body "$@" ) > "$TMP_ROOT/out/$name" 2>&1 &
}

# ── The queue ─────────────────────────────────────────────────────
start_job names            check_names
start_job feature-name     check_feature_name
start_job name-everywhere  check_name_everywhere
start_job log              check_log
start_job format           check_format
start_job build            check_build
start_job init-verify      check_init_verify
start_job spec-verify      check_spec_verify
start_job interrupted      check_interrupted
start_job domains          check_domains
start_job taken            check_taken
start_job relations        check_relations
start_job text             check_text
start_job raw              check_raw
start_job blocked-set      check_blocked_set
start_job start            check_start
start_job spec-review      check_spec_review
start_job feedback         check_feedback
start_job conf-set         check_conf_set
start_job backup           check_backup
start_job stacks           check_stacks
start_job collisions       check_collisions
start_job findings         check_findings
start_job replace          check_replace
start_job no-requirements  check_no_requirements
start_job jira-tokens      check_jira_tokens
start_job lib-source       check_suite lib-source
start_job confluence-fetch   check_suite confluence
start_job confluence-publish check_suite confluence publish.sh
start_job confluence-search  check_suite confluence search.sh
start_job jira-fetch         check_suite jira
start_job jira-publish       check_suite jira publish.sh

# A check named on the command line that the queue does not hold would narrow
# the run to nothing and pass.
for name in $(printf '%s' "$CHECKS" | tr ',' ' '); do
  [[ "$name" == "none" || "$KNOWN_CHECKS" == *",$name,"* ]] || {
    printf 'ERROR=no such check: %s — one of%s\n' "$name" "$(printf '%s' "$KNOWN_CHECKS" | tr ',' ' ')" >&2; exit 1; }
done

if (( NO_FIXTURES )); then
  [[ -z "$SELECTED" ]] || { printf 'ERROR=--no-fixtures and fixtures named:%s\n' "$SELECTED" >&2; exit 1; }
else
  [[ -n "$SELECTED" ]] || SELECTED="$(cd "$FIXTURES" && ls -d */ 2>/dev/null | sed 's#/$##')"
fi

for name in $SELECTED; do
  [[ -d "$FIXTURES/$name" ]] || { printf 'ERROR=no such fixture: %s\n' "$name" >&2; exit 1; }
done
for name in $SELECTED; do
  start_job "fixture-$name" run_fixture "$name"
done

wait

# ── The report ────────────────────────────────────────────────────
BAD=0
for name in ${JOB_NAMES[@]+"${JOB_NAMES[@]}"}; do
  [[ -f "$TMP_ROOT/out/$name" ]] && cat "$TMP_ROOT/out/$name"
  [[ "$(cat "$TMP_ROOT/rc/$name" 2>/dev/null)" == "0" ]] || {
    printf 'ERROR=job did not finish: %s\n' "$name" >&2
    BAD=1
  }
done

PASSED=0; FAILED=0; WRITTEN=0
for name in ${JOB_NAMES[@]+"${JOB_NAMES[@]}"}; do
  [[ -f "$TMP_ROOT/res/$name" ]] || continue
  PASSED=$(( PASSED + $(grep -c '^P$' "$TMP_ROOT/res/$name" || true) ))
  FAILED=$(( FAILED + $(grep -c '^F$' "$TMP_ROOT/res/$name" || true) ))
  WRITTEN=$(( WRITTEN + $(grep -c '^W$' "$TMP_ROOT/res/$name" || true) ))
done

# The jobs that set the wall time: the run is as long as its slowest one.
printf '\nslowest: %s\n' "$(cat "$TMP_ROOT/time/"* 2>/dev/null | sort -rn | head -n 5 | awk '{ printf "%s%s %ss", sep, $2, $1; sep = ", " }')"
printf '\n%s passed, %s failed' "$PASSED" "$FAILED"
(( UPDATE )) && printf ', %s written' "$WRITTEN"
printf '\n'
(( BAD )) && exit 1
(( FAILED > 0 )) && exit 2
exit 0
