#!/usr/bin/env bash
# The regression tests of install.sh: runs the installer against a temporary
# project per case and diffs the tree it left against the golden recorded next
# to the fixture.
#
# A fixture is a scenario — the target directory the installer starts from, and
# the sequence of runs performed on it. The golden is what the installer left:
# the tree listing, where every installed file carries the engine file it was
# copied from, every other real file carries its content, and the registry
# carries its lines. The manifest is recorded once, with its checksums replaced
# by a fixed token — a checksum is stable but it is noise in a diff, and the
# claim worth keeping is which paths the manifest names. Paths
# are relative and the temporary root is normalized away, so a golden written on
# one machine is read on the next.
#
# An installed file is recorded by the engine file it came from rather than by
# its content, because that source is the whole claim of an install:
# .claude/agents/architect.md is right only if it holds
# <engine>/.sdd/agents/architect.md. The installer writes copies, so the match
# is made on content — a golden carrying the content itself would hold the whole
# engine inline and would change on every engine edit. A symlink, which only an
# install from an older engine leaves behind, is still recorded by the path it
# points at.
#
# What is NOT recorded is the installer's stdout — a line per installed file, a
# hundred and thirty of them per install, saying what the tree already says.
# Its stderr is, in full: that is where every refusal is written.
#
# Usage: run.sh [--update] [<fixture> ...]
#   no argument   every fixture
#   <fixture>     the name of a directory under fixtures/
#   --update      overwrite the golden files with what the installer leaves now.
#                 A golden is a decision: run this only after reading the diff
#                 the plain run printed, never to make a red run green.
#
# The environment it reads:
#   SDD_TEST_JOBS   how many fixtures run at once. Default: the machine's
#                   cores. 1 puts the suite back on one, which is what to
#                   reach for when a failure looks like it might be the
#                   harness rather than the installer.
#
# A fixture directory holds:
#   steps             sourced with the target in place: the runs that make up
#                     the scenario, written with the helpers below
#   case              optional, KEY=value: GIT=yes|no (default no),
#                     MKDIRS=<space-separated directories created in the
#                     target, for the empty ones git cannot carry>
#   tree/             optional, the project the scenario starts from, copied
#                     into the target
#   git-setup         optional, GIT=yes only: sourced in the target instead of
#                     the default single commit
#   registry          optional, seeds the registry before the first run; the
#                     word <target> in it becomes the target's path
#   golden.txt        what the scenario leaves behind
#
# What a `steps` file has to work with:
#   $TARGET           the project, absolute
#   $ENGINE           the engine the installer is run from, absolute — a
#                     throwaway copy of this repository's .sdd/ and installer,
#                     which a case is free to delete from or plant in
#   sdd <arg>...      run the installer; records the arguments, the exit code
#                     and whatever went to stderr
#   show <label> <cmd>...
#                     run a command in the target and record its output — for a
#                     claim no tree listing can carry, such as what git sees
#   said <what> <text>
#                     the claim that the last run printed <text> — for what only
#                     its stdout says, such as how many edited files were kept
#   expect <what> <cmd>...
#                     run a command in the target and record whether it held.
#                     A failed expectation fails the run on its own, so --update
#                     cannot write it away
#   snapshot <name> / expect_unchanged <name> <what>
#                     the tree now, and the claim that it has not moved since —
#                     what "the refused run left the target alone" means
#
# The registry is the state the installer keeps outside the target, and a case
# that reached the real one would still pass its diff — the damage would only
# surface later, as a --sync walking directories deleted hours ago. Every case
# gets its own registry inside the temporary root, and the runner checks that
# is where SDD_REGISTRY points before each one.
#
# Exit codes: 0 — every case matched (or was written under --update);
#             1 — the environment is wrong; 2 — a case differs from its golden
#             or an expectation failed, and the diff was printed.

# ── Bash version gate ─────────────────────────────────────────────
# This runner executes install.sh, which needs mapfile, namerefs and fractional
# read timeouts — bash 4+. macOS ships 3.2.57. tests/run.sh is held to 3.2
# because the engine's scripts are; a runner that starts the installer inherits
# the installer's floor. Fail here rather than skip the cases: a silent skip
# reads like a pass.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  echo "tests/install/run.sh requires bash 4+ (this is ${BASH_VERSION:-not bash}; macOS ships 3.2)." >&2
  echo "Install a newer one:  brew install bash" >&2
  echo "Then re-run:          $0" >&2
  exit 1
fi

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$ENGINE_ROOT/install.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

[[ -x "$INSTALLER" ]] || { printf 'ERROR=not executable: %s\n' "$INSTALLER" >&2; exit 1; }
[[ -d "$FIXTURES" ]]  || { printf 'ERROR=no fixtures directory: %s\n' "$FIXTURES" >&2; exit 1; }

UPDATE=0
SELECTED=""
while (( $# > 0 )); do
  case "$1" in
    --update) UPDATE=1 ;;
    -h|--help) sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'ERROR=unknown option: %s\n' "$1" >&2; exit 1 ;;
    *)  SELECTED="$SELECTED $1" ;;
  esac
  shift
done

# Every fixture gets a temporary root of its own under this one, so two of them
# running at the same time share no path — not the target, not the registry, not
# the scratch files a step writes through. What the goldens see is unchanged: a
# fixture's own root is what `normalize` rewrites to `<tmp>`, so a scenario reads
# back the same way whether it ran alone or beside twenty-six others.
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sdd-install-tests.XXXXXX")" || exit 1
# TMPDIR carries a trailing slash on macOS, and mktemp keeps the double slash it
# makes. The installer resolves the target with `cd && pwd` and writes the
# collapsed form into the registry, so a path normalized against the uncollapsed
# one comes back through the golden with the machine's name still on it.
TMP_ROOT="$(cd "$TMP_ROOT" && pwd)" || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/out" "$TMP_ROOT/res" "$TMP_ROOT/rc" || exit 1

# git reads the machine's identity, its default branch and its global ignore
# file. A test that inherits those passes on one machine and fails on the next.
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_DATE="2026-01-01T00:00:00+0000"
export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"

# The temporary root of one job, and everything that hangs off it. HOME is per
# job for the same reason the root is: the git identity is written into it, and
# a job must not be reading a file another job is still writing.
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
  TRANSCRIPT="$TMP/actual.txt"
  EXPECT_FAILS="$TMP/expect-fails.txt"
  : > "$EXPECT_FAILS"
}

FIXTURE=""
TARGET=""
ENGINE=""
INSTALLER_UNDER_TEST=""
TRANSCRIPT=""
# The installer's manifest, recorded on its own and never as file content.
MANIFEST_REL=".sdd/.sdd-manifest"
declare -A SUMS=()
declare -A ENGINE_BY_SUM=()
EXPECT_FAILS=""

# A verdict, appended to the job's own result file rather than counted in a
# variable: a job runs in a subshell, and a number raised there dies with it.
# The parent adds the files up once every job has finished.
RESULTS="$TMP_ROOT/res/main"
: > "$RESULTS"
pass()    { printf 'P\n' >> "$RESULTS"; }
fail()    { printf 'F\n' >> "$RESULTS"; }
written() { printf 'W\n' >> "$RESULTS"; }

ESC=$'\033'

# Everything machine-specific out of a line: the engine's path, the temporary
# root, the repository's own path, the colors the installer prints with, and
# commit ids. The engine goes first — its copy lives inside the temporary root.
normalize() {
  sed -e "s#${ENGINE:-$ENGINE_ROOT}#<engine>#g" \
      -e "s#$TMP#<tmp>#g" \
      -e "s#$ENGINE_ROOT#<engine>#g" \
      -e "s/$ESC\[[0-9;?]*[a-zA-Z]//g" \
      -e 's/[0-9a-f]\{40\}/<sha>/g'
}

# ── What a scenario is written with ───────────────────────────────
sdd() {
  local shown rc
  shown="$(printf '%s ' "$@" | normalize)"
  printf '### sdd %s\n' "${shown% }" >> "$TRANSCRIPT"
  "$INSTALLER_UNDER_TEST" "$@" >"$TMP/sdd-out.txt" 2>"$TMP/sdd-err.txt"
  rc=$?
  printf 'exit=%s\n' "$rc" >> "$TRANSCRIPT"
  if [[ -s "$TMP/sdd-err.txt" ]]; then
    printf '### stderr\n' >> "$TRANSCRIPT"
    normalize < "$TMP/sdd-err.txt" >> "$TRANSCRIPT"
  fi
}

show() {
  local label="$1" rc; shift
  printf '### %s\n' "$label" >> "$TRANSCRIPT"
  ( cd "$TARGET" && "$@" ) >"$TMP/show-out.txt" 2>&1
  rc=$?
  normalize < "$TMP/show-out.txt" >> "$TRANSCRIPT"
  printf 'exit=%s\n' "$rc" >> "$TRANSCRIPT"
}

# An expectation is recorded twice over: in the transcript, where the golden
# holds it, and in a file the runner reads afterwards. The second is what makes
# it survive --update — a golden can be rewritten, a failed expectation cannot.
expectation() {
  local what="$1" ok="$2"
  if (( ok == 0 )); then
    printf '### expect %s — pass\n' "$what" >> "$TRANSCRIPT"
  else
    printf '### expect %s — FAIL\n' "$what" >> "$TRANSCRIPT"
    printf '%s\t%s\n' "$FIXTURE" "$what" >> "$EXPECT_FAILS"
  fi
}

expect() {
  local what="$1" rc; shift
  ( cd "$TARGET" && "$@" ) >/dev/null 2>&1
  rc=$?
  expectation "$what" "$rc"
}

# The last run's stdout, for the one claim the tree cannot carry: the line
# naming what happened to the files the project edited. The rest of that stdout
# is a line per file, which is why it is not recorded wholesale.
said() {
  local what="$1" pattern="$2"
  if normalize < "$TMP/sdd-out.txt" | grep -qF -- "$pattern"; then
    expectation "$what" 0
  else
    expectation "$what" 1
    printf '    stdout did not carry: %s\n' "$pattern" >> "$TRANSCRIPT"
  fi
}

snapshot() {
  list_tree "$TARGET" > "$TMP/snapshot.$1"
}

expect_unchanged() {
  local name="$1" what="$2"
  list_tree "$TARGET" > "$TMP/snapshot.now"
  if diff -q "$TMP/snapshot.$name" "$TMP/snapshot.now" >/dev/null; then
    expectation "$what" 0
  else
    expectation "$what" 1
    diff -u "$TMP/snapshot.$name" "$TMP/snapshot.now" | sed 's/^/    /' >> "$TRANSCRIPT"
  fi
}

# ── Claims a tree listing cannot carry ────────────────────────────
# Every symlink into the engine, for the claim that an uninstall left none.
engine_links() {
  local link
  while IFS= read -r link; do
    [[ -n "$link" ]] || continue
    case "$(readlink "$link")" in
      "$ENGINE"/*) printf '%s\n' "$link" ;;
    esac
  done < <(find "$TARGET" -type l 2>/dev/null)
}

no_engine_links() {
  [[ -z "$(engine_links)" ]]
}

# The paths git would report that belong to the engine. The project's own
# .gitignore is not one of them — the installer writes a block into a file the
# project keeps, and a modified .gitignore is the visible half of that. Nothing
# under .sdd/ is exempt, .sdd/sdd.conf and .sdd/.sdd-manifest included: the
# first holds JIRA_TOKEN, and a personal access token must never reach a commit;
# the second is the installer's own record and belongs to the machine it was
# written on, not to the project's history. Both are covered by the .sdd/ arm of
# the pattern below.
#
# -uall, because git collapses an untracked directory to one line: a plain
# --porcelain would print `?? .sdd/` for a single visible file there and this
# check could not tell that entry from the whole engine being visible. Expanded,
# every visible file is named and the ignored ones stay out of it.
no_engine_in_git_status() {
  ! git status --porcelain -uall | sed 's/^...//' \
    | grep -qE '^(\.sdd/|\.claude/|\.github/(agents|skills|instructions)/|\.github/copilot-instructions\.md$)'
}

git_status_names() {
  [[ -n "$(git status --porcelain -- "$1")" ]]
}

git_ignores() {
  git check-ignore -q -- "$1"
}

git_status_hides() {
  [[ -z "$(git status --porcelain -uall -- "$1")" ]]
}

# ── Which engine file a copy came from ────────────────────────────
# The installer's own checksum command, so the runner reads the same files the
# same way on either platform.
sum_tree() {
  local root="$1" line sum path
  local -a files=()
  SUMS=()
  while IFS= read -r -d '' path; do
    files+=("$path")
  done < <(find "$root" -name .git -prune -o -type f ! -name .DS_Store -print0 2>/dev/null)
  # One shasum for the whole tree. Per file it is a process each, a hundred and
  # thirty of them per listing, and a listing is taken several times a case.
  (( ${#files[@]} )) || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    sum="${line%% *}"
    path="${line#*  }"
    SUMS["$path"]="$sum"
  done < <(shasum -a 256 "${files[@]}" 2>/dev/null)
}

# Every engine file by content. The engine ships no two files with the same
# content, so a checksum names exactly one source; where it somehow named two,
# the first in sorted order wins and the golden stays deterministic.
index_engine() {
  local path sum
  ENGINE_BY_SUM=()
  sum_tree "$ENGINE/.sdd"
  while IFS= read -r path; do
    sum="${SUMS[$path]:-}"
    [[ -n "$sum" ]] || continue
    [[ -n "${ENGINE_BY_SUM[$sum]:-}" ]] && continue
    ENGINE_BY_SUM["$sum"]="${path#"$ENGINE"/}"
  done < <(printf '%s\n' "${!SUMS[@]}" | LC_ALL=C sort)
}

# The engine file a real file in the target is a copy of, if it is one.
engine_source() {
  local sum="$1" src
  src="${ENGINE_BY_SUM[$sum]:-}"
  [[ -n "$src" ]] || return 1
  printf '%s' "$src"
}

# ── The tree, as a golden records it ──────────────────────────────
list_tree() {
  local root="$1" path rel dest src
  # The index is taken here rather than once per case: a scenario is free to
  # edit the engine it installs from, and a listing has to name the engine as
  # it stands when the listing is taken.
  index_engine
  sum_tree "$root"
  while IFS= read -r path; do
    rel="${path#"$root"/}"
    if [[ -L "$path" ]]; then
      dest="$(readlink "$path")"
      case "$dest" in
        "$ENGINE"/*) dest="<engine>/${dest#"$ENGINE"/}" ;;
        *)           dest="$(printf '%s' "$dest" | normalize)" ;;
      esac
      printf 'l  %s -> %s\n' "$rel" "$dest"
    elif [[ -d "$path" ]]; then
      printf 'd  %s/\n' "$rel"
    elif src="$(engine_source "${SUMS[$path]:-}")"; then
      printf 'c  %s = <engine>/%s\n' "$rel" "$src"
    else
      printf 'f  %s\n' "$rel"
    fi
  done < <(find "$root" -mindepth 1 -name .git -prune -o -print 2>/dev/null | LC_ALL=C sort)
}

# The tree, then the content of every real file the installer did not copy in,
# then the manifest, then the registry. A copy is already named by the engine
# file it matches, and its content would only repeat the engine; what is left is
# what the goldens are for — the merged blocks, .gitignore, the project's own
# files — and there content is the only thing that says whether it is right.
record_result() {
  printf '### tree\n' >> "$TRANSCRIPT"
  list_tree "$TARGET" >> "$TRANSCRIPT"

  local path rel
  while IFS= read -r path; do
    [[ -L "$path" ]] && continue
    rel="${path#"$TARGET"/}"
    [[ "$rel" == "$MANIFEST_REL" ]] && continue
    engine_source "${SUMS[$path]:-}" >/dev/null && continue
    printf '### file %s\n' "$rel" >> "$TRANSCRIPT"
    normalize < "$path" >> "$TRANSCRIPT"
  done < <(find "$TARGET" -mindepth 1 -name .git -prune -o -type f -print 2>/dev/null | LC_ALL=C sort)

  # The installer's record of what it wrote. The checksums go out: they are
  # stable, but they are noise in a diff, and the claim worth keeping is which
  # paths the manifest names.
  if [[ -f "$TARGET/$MANIFEST_REL" ]]; then
    printf '### manifest\n' >> "$TRANSCRIPT"
    sed 's/^[0-9a-f]\{64\}/<sum>/' "$TARGET/$MANIFEST_REL" >> "$TRANSCRIPT"
  fi

  printf '### registry\n' >> "$TRANSCRIPT"
  if [[ -s "$SDD_REGISTRY" ]]; then
    normalize < "$SDD_REGISTRY" >> "$TRANSCRIPT"
  fi
}

compare() {
  local fixture="$1" golden="$2" actual="$3"

  if (( UPDATE )); then
    if [[ -f "$golden" ]] && diff -q "$golden" "$actual" >/dev/null; then
      pass
    else
      cat "$actual" > "$golden"
      written
      printf '  written  %s\n' "$fixture"
    fi
    return 0
  fi

  if [[ ! -f "$golden" ]]; then
    fail
    printf '  MISSING  %s — no golden file. Read the output, then record it with --update.\n' "$fixture"
    return 0
  fi

  if diff -q "$golden" "$actual" >/dev/null; then
    pass
  else
    fail
    printf '  FAILED   %s\n' "$fixture"
    diff -u "$golden" "$actual" | sed 's/^/    /'
  fi
}

run_fixture() {
  FIXTURE="$1"
  local dir="$FIXTURES/$FIXTURE"
  local work="$TMP/$FIXTURE"
  local GIT="no" MKDIRS="" d

  [[ -f "$dir/steps" ]] || { printf 'ERROR=no steps file: %s\n' "$dir/steps" >&2; exit 1; }
  if [[ -f "$dir/case" ]]; then
    # shellcheck disable=SC1090
    . "$dir/case"
  fi

  TARGET="$work/project"
  mkdir -p "$TARGET" || exit 1

  # The engine the installer runs from: always a copy of .sdd/ and the
  # installer, never this repository. A scenario may delete from it or plant in
  # it, and the skills someone installed into this clone's .claude/skills/ or
  # .agents/skills/ would otherwise land in every golden.
  ENGINE="$work/engine"
  mkdir -p "$ENGINE" || exit 1
  cp -R "$ENGINE_ROOT/.sdd" "$ENGINE/.sdd" || exit 1
  cp "$INSTALLER" "$ENGINE/install.sh" || exit 1
  INSTALLER_UNDER_TEST="$ENGINE/install.sh"

  [[ -d "$dir/tree" ]] && { cp -R "$dir/tree/." "$TARGET/" || exit 1; }
  for d in $MKDIRS; do
    mkdir -p "$TARGET/$d" || exit 1
  done

  if [[ "$GIT" == "yes" ]]; then
    (
      cd "$TARGET" || exit 1
      git init -q . || exit 1
      if [[ -f "$dir/git-setup" ]]; then
        # shellcheck disable=SC1090
        . "$dir/git-setup"
      else
        git add -A && git commit -qm "fixture"
      fi
    ) >/dev/null 2>&1 || { printf 'ERROR=git fixture setup failed: %s\n' "$FIXTURE" >&2; exit 1; }
  fi

  # Its own registry, inside the temporary root — see the header.
  export SDD_REGISTRY="$work/registry.txt"
  case "$SDD_REGISTRY" in
    "$TMP"/*) ;;
    *) printf 'ERROR=SDD_REGISTRY is not under %s: %s\n' "$TMP" "$SDD_REGISTRY" >&2; exit 1 ;;
  esac
  if [[ -f "$dir/registry" ]]; then
    sed "s#<target>#$TARGET#g" "$dir/registry" > "$SDD_REGISTRY"
  fi

  printf '%s\n' "$FIXTURE"
  : > "$TRANSCRIPT"
  (
    # shellcheck disable=SC1090
    . "$dir/steps"
  )
  record_result
  compare "$FIXTURE" "$dir/golden.txt" "$TRANSCRIPT"
}

# ── The jobs ──────────────────────────────────────────────────────
# A job is one fixture. They share nothing: each gets its own temporary root, its
# own HOME, its own target and its own registry, and each writes its verdicts and
# its output to files of its own. So they run side by side, and the parent
# replays their output afterwards in the order the queue was built — a parallel
# run reads exactly like a serial one.
#
# The number of them at once follows the machine. SDD_TEST_JOBS=1 puts the suite
# back on one core, which is what to reach for when a failure looks like it
# might be the harness rather than the installer.
JOBS="${SDD_TEST_JOBS:-}"
if [[ -z "$JOBS" ]]; then
  JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
fi
case "$JOBS" in ''|*[!0-9]*) JOBS=4 ;; esac
(( JOBS > 0 )) || JOBS=1
# `wait -n` is bash 4.3. Without it a job slot cannot be reclaimed one at a
# time, and the suite runs serially rather than in waves that would idle every
# core but the slowest job's.
if (( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3 )); then
  JOBS=1
fi

JOB_NAMES=()

# The body of one job. The exit code is written before the work starts and
# overwritten when it finishes: a job that dies part-way — `exit 1` out of a
# fixture whose setup failed, a `set -u` abort — leaves the 1 standing, and the
# parent has its answer without depending on a status `wait -n` may already
# have reaped.
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
[[ -n "$SELECTED" ]] || SELECTED="$(cd "$FIXTURES" && ls -d */ 2>/dev/null | sed 's#/$##')"

for name in $SELECTED; do
  [[ -d "$FIXTURES/$name" ]] || { printf 'ERROR=no such fixture: %s\n' "$name" >&2; exit 1; }
done
for name in $SELECTED; do
  start_job "$name" run_fixture "$name"
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

# An expectation that failed is a failure whatever the goldens say. Each job
# recorded its own; the parent reads them in the order the queue was built.
FAILS_SEEN=0
for name in "${JOB_NAMES[@]}"; do
  [[ -s "$TMP_ROOT/j-$name/expect-fails.txt" ]] || continue
  (( FAILS_SEEN )) || printf '\n  Expectations that did not hold:\n'
  FAILS_SEEN=1
  while IFS=$'\t' read -r fixture what; do
    printf '    %s — %s\n' "$fixture" "$what"
    FAILED=$(( FAILED + 1 ))
  done < "$TMP_ROOT/j-$name/expect-fails.txt"
done

printf '\n%s passed, %s failed' "$PASSED" "$FAILED"
(( UPDATE )) && printf ', %s written' "$WRITTEN"
printf '\n'
(( BAD )) && exit 1
(( FAILED > 0 )) && exit 2
exit 0
