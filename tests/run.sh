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
# The maven-lib-source skill's own suite lives in `lib-source/run.sh` and is
# called from here as one job: it builds a Maven repository of its own, which is
# not a shape a fixture of this file can hold. Run it alone while changing that
# script; run this one to be told whether it still passes.
#
# Last of the three, it calls lib/format.sh directly, on the values and the file
# shapes no fixture can produce: a blank `> Key:` line above a real one, a value
# carrying a backslash or an ampersand, and a compilation source spelled with a
# `|`. These have no golden either — they are properties of one function, and
# recording them as a tree would record the state the defect has nothing to do
# with.
#
# Usage: run.sh [--update] [<fixture> ...]
#   no argument   every fixture
#   <fixture>     the name of a directory under fixtures/
#   --update      overwrite the golden files with what the scripts print now.
#                 A golden is a decision: run this only after reading the diff
#                 the plain run printed, never to make a red run green.
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
#                     the expected output of one jira-fetch.sh run from
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
JIRA_SH="$SCRIPTS/jira-fetch.sh"
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
implement-backend|implement|backend|
implement-frontend|implement|frontend|
code-review-review-set|code-review|review-set|
code-fix-backend|code-fix|findings-backend|TRIAGE=Critical and Major fixed, the rest gets a marker.;FINDINGS=F-01 CartService.java:42 — the total ignores the discount.\nF-02 CartService.java:57 — no test for an empty cart.
code-fix-frontend|code-fix|findings-frontend|TRIAGE=Fix everything.;FINDINGS=F-03 cart.component.ts:12 — the total is formatted client-side.
actualize-baseline|actualize|baseline-from-feature|
refused-no-template|implement|no-such-scope|
refused-no-value|code-fix|findings-backend|TRIAGE=Fix everything.
refused-multiline-inline|implement|backend|FEATURE=Cart\nBasket
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
EDIT_CASES='backup|backup
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
marker-java|marker;src/main/java/com/example/CartService.java;3;The total ignores the discount.
marker-unknown-type|marker;web/package.json;2;No comment syntax here.
marker-past-end|marker;_docs/<F>/raw.md;9999;Nowhere near a line.
compile-entry-final|compile-entry;<F>;REQ-002;final
compile-entry-new|compile-entry;<F>;REQ-900;final;Saved carts. A shopper keeps a cart between sessions.
compile-entry-superseded|compile-entry;<F>;REQ-002;superseded-by:REQ-900
compile-entry-no-text|compile-entry;<F>;REQ-900;final
compile-entry-domained|compile-entry;<F>;REQ-ACC-900;final;Password reset. An account holder sets a new password over a mailed link.
section-text|section;_docs/<F>/raw.md;Problem;Shoppers lose the cart when the session drops.
section-heading-hashes|section;_docs/<F>/raw.md;## Problem;Shoppers lose the cart when the session drops.
section-empty|section;_docs/<F>/raw.md;Users
section-no-heading|section;_docs/<F>/raw.md;Nowhere'

# One line per import: <case>|<the fixture's Jira answer>|<argument;argument;…>
# for jira-fetch.sh|<VAR=value;VAR=value> put in its environment, where `<KEY>`
# stands for the feature name of the fixture — for this family that is the issue
# key. A case runs only in a fixture that carries the answer it names, and the
# runner adds `--from-file` itself: no case here can reach the network, and none
# may be written that could.
#
# The environment is built from nothing: HOME points at an empty directory, so
# ~/.config/sdd-kit/tokens.env is missing whatever the machine running the tests
# holds, and JIRA_URL and JIRA_TOKEN are unset unless the case sets them.
JIRA_CASES='key|issue.json|<KEY>;--out;_docs/<KEY>/raw.md|JIRA_URL=https://jira.example.com;JIRA_TOKEN=fixture-token
url|issue.json|https://jira.example.com/browse/<KEY>;--out;_docs/<KEY>/raw.md|JIRA_TOKEN=fixture-token
no-token|issue.json|<KEY>;--out;_docs/<KEY>/raw.md|JIRA_URL=https://jira.example.com
no-url|issue.json|<KEY>;--out;_docs/<KEY>/raw.md|JIRA_TOKEN=fixture-token
empty-description|issue-empty.json|<KEY>;--out;_docs/<KEY>/raw.md|JIRA_URL=https://jira.example.com;JIRA_TOKEN=fixture-token
mixed|issue-mixed.json|<KEY>;--out;_docs/<KEY>/raw.md|JIRA_URL=https://jira.example.com;JIRA_TOKEN=fixture-token'

[[ -x "$GATE" ]]      || { printf 'ERROR=not executable: %s\n' "$GATE" >&2; exit 1; }
[[ -x "$RENDERER" ]]  || { printf 'ERROR=not executable: %s\n' "$RENDERER" >&2; exit 1; }
[[ -x "$EDITOR_SH" ]] || { printf 'ERROR=not executable: %s\n' "$EDITOR_SH" >&2; exit 1; }
[[ -d "$FIXTURES" ]]  || { printf 'ERROR=no fixtures directory: %s\n' "$FIXTURES" >&2; exit 1; }

UPDATE=0
SELECTED=""
while (( $# > 0 )); do
  case "$1" in
    --update) UPDATE=1 ;;
    -h|--help) sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/out" "$TMP_ROOT/res" "$TMP_ROOT/rc" || exit 1

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
    out="$(cd "$project" && "$RENDERER" init "$scope" ${argv[@]+"${argv[@]}"} 2>"$err")"; rc=$?
  else
    out="$(cd "$project" && "$RENDERER" "$cmd" "$feature" "$scope" ${argv[@]+"${argv[@]}"} 2>"$err")"; rc=$?
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

# One jira-fetch.sh run, over its own copy of the project. The golden holds what
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
  local work="$TMP/format-check" ok n v val out

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

  # A compilation record is three fields split on `|`. A source carrying one
  # used to shift every field after it: the status was read as the source, and
  # the entry landed in the wrong counter — the one that decides `actualized`
  # against `implemented`.
  mkdir -p "$work/pipe/_docs/Ca|rt" || exit 1
  printf '# Requirements Compilation\n\n<!-- Next free number: REQ-002 -->\n\n## Requirements\n\n- **REQ-001** — Cart holds items. A shopper keeps picked items until checkout. *(Source: Ca|rt, draft)*\n' \
    > "$work/pipe/_docs/requirements.md"
  printf '# Requirements — Ca|rt\n\n> Status: ready\n\n## Requirements\n\n### REQ-001 — Cart holds items\n\nA shopper keeps picked items until checkout.\n' \
    > "$work/pipe/_docs/Ca|rt/new-requirements.md"
  out="$(cd "$work/pipe" && "$SCRIPTS/feature-state.sh" 'Ca|rt' 2>&1)"
  n="$(printf '%s\n' "$out" | sed -n '/^COMPILATION_ENTRIES:$/,$p' | sed -n '2p')"
  v="$(printf '%s\n' "$out" | awk -F= '$1 == "COMPILATION_DRAFT" { print $2 }')"
  ok=0
  [[ "$v" == "1" && "$n" == "REQ-001|draft" ]] || ok=1
  prop_check format "compilation source is |-sanitized" "$ok" \
    "the record came back as '$n' and COMPILATION_DRAFT=$v, where 'REQ-001|draft' and 1 are the entry"
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
    warn="$(printf '%s\n' "$out" | sed -n 's/^NAME_WARN=//p')"
    ok=0
    if [[ "$want" == "quiet" ]]; then
      [[ -z "$warn" ]] || ok=1
    else
      [[ -n "$warn" ]] || ok=1
    fi
    prop_check name "$name is $want" "$ok" \
      "NAME_WARN=${warn:-<empty>}"
  done <<EOF
$cases
EOF
}

check_build() {
  local work="$TMP/build-check" bc="$SCRIPTS/build-command.sh"
  local out ok

  printf 'build command\n'
  rm -rf "$work" || exit 1

  # <name>|<build files, space separated>|<sdd.conf lines, ; separated>|
  # <expected ROOT>|<expected BACKEND>|<expected FRONTEND>|<expected SOURCE>|
  # <the SDD_BUILD_* keys the gate has to ask for, space separated>
  local cases='backend-answered|pom.xml|SDD_BUILD_ROOT=mvn -q verify|mvn -q verify|mvn -q verify||config|
backend-stack-key|pom.xml|SDD_BUILD_BACKEND=mvn -q verify|mvn -q verify|mvn -q verify||config|
backend-missing|pom.xml|||||detected|SDD_BUILD_BACKEND
frontend-answered|package.json|SDD_BUILD_ROOT=npm test|npm test||npm test|config|
frontend-missing|package.json|||||detected|SDD_BUILD_FRONTEND
two-answered|backend/pom.xml frontend/package.json|SDD_BUILD_BACKEND=cd backend && mvn verify;SDD_BUILD_FRONTEND=cd frontend && npm test||cd backend && mvn verify|cd frontend && npm test|config|
two-root-only|backend/pom.xml frontend/package.json|SDD_BUILD_ROOT=make all|make all|||config|SDD_BUILD_BACKEND SDD_BUILD_FRONTEND
two-half|backend/pom.xml frontend/package.json|SDD_BUILD_BACKEND=cd backend && mvn verify||cd backend && mvn verify||config|SDD_BUILD_FRONTEND
no-stack-answered|Makefile|SDD_BUILD_ROOT=make verify|make verify|make verify|make verify|config|
no-stack-missing|Makefile|||||none|SDD_BUILD_ROOT'

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
    run_case "$fixture" "$cmd" "$project" "$FEATURE" "$EXTRA"
  done

  local line name pcmd pscope pargs
  while IFS='|' read -r name pcmd pscope pargs; do
    [[ -n "$name" ]] || continue
    # A base-ref the fixture names reaches the renderer the way a command passes
    # it on: two detections of a review set produce two sets.
    if [[ "$pcmd" == "code-review" && -n "$EXTRA" && "$pargs" != *BASE=* ]]; then
      pargs="BASE=$EXTRA${pargs:+;$pargs}"
    fi
    run_prompt_case "$fixture" "$name" "$pcmd" "$pscope" "$pargs" "$project" "$FEATURE"
  done <<EOF
$PROMPT_CASES
EOF

  local vcmd vopts
  while IFS='|' read -r name vcmd vopts; do
    [[ -n "$name" ]] || continue
    run_verify_case "$fixture" "$name" "$vcmd" "$vopts" "$project" "$FEATURE"
  done <<EOF
$VERIFY_CASES
EOF

  local eargs
  while IFS='|' read -r name eargs; do
    [[ -n "$name" ]] || continue
    run_edit_case "$fixture" "$name" "$eargs" "$project" "$FEATURE"
  done <<EOF
$EDIT_CASES
EOF

  local jjson jargs jenv
  while IFS='|' read -r name jjson jargs jenv; do
    [[ -n "$name" ]] || continue
    run_jira_case "$fixture" "$name" "$jjson" "$jargs" "$jenv" "$project" "$FEATURE"
  done <<EOF
$JIRA_CASES
EOF
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
# The maven-lib-source skill has a suite of its own: it needs a Maven repository
# built here out of javac and jar, which no fixture of this suite can hold, and
# it is useful on its own while that script is being changed. Called from here
# it is one job like any other, and the verdict it prints is folded into this
# count so a failure there fails the run.
check_lib_source() {
  local out rc summary p f i

  out="$("$SCRIPT_DIR/lib-source/run.sh" 2>&1)"; rc=$?
  summary="$(printf '%s\n' "$out" | tail -1)"
  printf '%s\n' "$out" | sed '$d'

  p="$(printf '%s' "$summary" | sed -n 's/^\([0-9][0-9]*\) passed.*/\1/p')"
  f="$(printf '%s' "$summary" | sed -n 's/.*, \([0-9][0-9]*\) failed$/\1/p')"
  if [[ -z "$p" || -z "$f" ]]; then
    fail
    printf '  FAILED   lib-source — tests/lib-source/run.sh printed no verdict, exit %s\n' "$rc"
    return 0
  fi

  for (( i = 0; i < p; i++ )); do pass; done
  for (( i = 0; i < f; i++ )); do fail; done
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
  "$@"
  printf '0\n' > "$TMP_ROOT/rc/$name"
}

start_job() {
  local name="$1"
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
start_job log              check_log
start_job format           check_format
start_job build            check_build
start_job init-verify      check_init_verify
start_job spec-verify      check_spec_verify
start_job interrupted      check_interrupted
start_job domains          check_domains
start_job taken            check_taken
start_job lib-source       check_lib_source

[[ -n "$SELECTED" ]] || SELECTED="$(cd "$FIXTURES" && ls -d */ 2>/dev/null | sed 's#/$##')"

for name in $SELECTED; do
  [[ -d "$FIXTURES/$name" ]] || { printf 'ERROR=no such fixture: %s\n' "$name" >&2; exit 1; }
done
for name in $SELECTED; do
  start_job "fixture-$name" run_fixture "$name"
done

wait

# ── The report ────────────────────────────────────────────────────
BAD=0
for name in "${JOB_NAMES[@]}"; do
  [[ -f "$TMP_ROOT/out/$name" ]] && cat "$TMP_ROOT/out/$name"
  [[ "$(cat "$TMP_ROOT/rc/$name" 2>/dev/null)" == "0" ]] || {
    printf 'ERROR=job did not finish: %s\n' "$name" >&2
    BAD=1
  }
done

PASSED=0; FAILED=0; WRITTEN=0
for name in "${JOB_NAMES[@]}"; do
  [[ -f "$TMP_ROOT/res/$name" ]] || continue
  PASSED=$(( PASSED + $(grep -c '^P$' "$TMP_ROOT/res/$name" || true) ))
  FAILED=$(( FAILED + $(grep -c '^F$' "$TMP_ROOT/res/$name" || true) ))
  WRITTEN=$(( WRITTEN + $(grep -c '^W$' "$TMP_ROOT/res/$name" || true) ))
done

printf '\n%s passed, %s failed' "$PASSED" "$FAILED"
(( UPDATE )) && printf ', %s written' "$WRITTEN"
printf '\n'
(( BAD )) && exit 1
(( FAILED > 0 )) && exit 2
exit 0
