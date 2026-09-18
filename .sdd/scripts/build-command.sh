#!/usr/bin/env bash
# Prints how this project is verified: what the human wrote, and — separately —
# what the build files would propose if they had not.
#
# Usage: build-command.sh [<project-root>]      (default: the current directory)
#
# Prints:
#   SOURCE=config|detected|none   config   — .sdd/sdd.conf answered
#                                 detected — it did not; DETECTED: below is a
#                                            proposal nobody has accepted, and
#                                            the three command keys are empty
#                                 none     — neither answered
#   ROOT=<command>       the whole-project verification. Empty when the project
#                        has two stacks and no root command was written: the two
#                        stack commands are then run one after the other.
#   BACKEND=<command>    what covers the code of one stack. Empty when nothing
#   FRONTEND=<command>   answered for it.
#   DETECTED:            <dir>|<build file>|<command>|<stack>, one per line —
#                        which stacks this project has, and the command each is
#                        usually verified with. A proposal, never a resolution.
#   NOTES:               what a reader has to know about this run
#
# ── The answer is the human's ─────────────────────────────────────
# It lives in `.sdd/sdd.conf`, the file the logger already reads — optional,
# parsed rather than sourced, unknown keys ignored in silence:
#
#   SDD_BUILD_ROOT=mvn clean verify
#   SDD_BUILD_BACKEND=cd backend && mvn clean verify
#   SDD_BUILD_FRONTEND=cd frontend && npm run build && npm test
#
# A command is a string run from the project root, self-contained — `cd` and
# `&&` chains included. Nothing is parsed inside it and no runner is looked for:
# it is the human's line, and the engine's job is to run it, not to judge it.
# The file only; no environment variable stands in for it, or the same project
# would verify differently from one shell to the next.
#
# `SDD_BUILD_ROOT` stands in for the stack of a project that has one stack, and
# for a project whose build no detection knows — a Makefile, a script. It does
# NOT stand in for a missing stack key when the project has two: a role working
# one stack is handed that stack's command, and there is no way to cut a root
# command down to one of them.
#
# ── Detection answers one question ────────────────────────────────
# Which stacks the project has, from files that cannot be worded wrongly. It
# proposes a command for each, and a proposal is all it is: this script never
# substitutes one for a missing answer. Whether the answers are sufficient for
# the shape the project has is `gate.sh`'s verdict, and the `ASK:` it prints
# carries the proposal so the human can accept it in one line. Nothing here is
# an error and nothing here is a note — the gate says it once, in full.
#
# Why the architecture baseline is no longer read: it used to be the first of three
# sources, and the 10.1 log shows what that cost. The `architect` wrote the
# Testing Strategy row as a two-stack project needs it — `cd backend && mvn
# clean verify` — the reader refused it for starting with no known runner, and
# detection then silently supplied the same string. Two things claimed one
# answer and the weaker won by default. The baseline's testing section
# Strategy describes the approach now and holds no command at all.
#
# Exit codes: 0 — printed; 1 — <project-root> is not a readable directory.
#             There is no exit 2: a project with no answer is not a broken
#             environment, it is a question, and the gate is where a question
#             becomes a verdict.

set -uo pipefail
[[ -r "$(dirname "$0")/lib/log.sh" ]] && . "$(dirname "$0")/lib/log.sh"

ROOT_DIR="${1:-.}"
if [[ ! -d "$ROOT_DIR" ]]; then
  printf 'ERROR=not a directory: %s\n' "$ROOT_DIR" >&2
  exit 1
fi

NOTES=()
note() { NOTES+=("$1"); }

# Array sizes are kept as counters: on bash 3.2 an empty array counts as unset
# under `set -u`, and ${#array[@]} would abort the script.
N_DETECTED=0

# ── The config ────────────────────────────────────────────────────
# Parsed the way `lib/log.sh` parses the same file, and for the same reason:
# `. .sdd/sdd.conf` is one line shorter and would execute whatever the file
# holds on every run of every script. A strict read over a fixed set of keys —
# quotes stripped, comments and blank lines skipped, everything else ignored
# without a word.
conf_read() {
  awk '
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      p = index(line, "=")
      if (p < 2) next
      key = substr(line, 1, p - 1)
      val = substr(line, p + 1)
      sub(/[[:space:]]+$/, "", key)
      sub(/^[[:space:]]+/, "", val)
      if (key !~ /^SDD_BUILD_(ROOT|BACKEND|FRONTEND)$/) next
      gsub(/^["\047]|["\047]$/, "", val)
      print key "=" val
    }
  ' "$1" 2>/dev/null
}

CONF="$ROOT_DIR/.sdd/sdd.conf"
CFG_ROOT=""; CFG_BACKEND=""; CFG_FRONTEND=""

if [[ -r "$CONF" ]]; then
  while IFS='=' read -r key val; do
    case "$key" in
      SDD_BUILD_ROOT)     CFG_ROOT="$val" ;;
      SDD_BUILD_BACKEND)  CFG_BACKEND="$val" ;;
      SDD_BUILD_FRONTEND) CFG_FRONTEND="$val" ;;
    esac
  done <<EOF
$(conf_read "$CONF")
EOF
fi

# ── Detection: which stacks the project has ───────────────────────
DETECTED=()
HAS_BACKEND=0; HAS_FRONTEND=0

detect_in() {
  local dir="$1" rel cmd
  rel="${dir#"$ROOT_DIR"}"
  rel="${rel#/}"
  [[ -z "$rel" ]] && rel="."

  if [[ -f "$dir/pom.xml" ]]; then
    cmd="mvn clean verify"
    [[ "$rel" != "." ]] && cmd="cd $rel && $cmd"
    DETECTED+=("$rel|pom.xml|$cmd|backend"); N_DETECTED=$(( N_DETECTED + 1 ))
    HAS_BACKEND=1
  elif [[ -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" ]]; then
    local gradle_file="build.gradle"
    [[ -f "$dir/build.gradle.kts" ]] && gradle_file="build.gradle.kts"
    cmd="./gradlew build"
    [[ "$rel" != "." ]] && cmd="cd $rel && $cmd"
    DETECTED+=("$rel|$gradle_file|$cmd|backend"); N_DETECTED=$(( N_DETECTED + 1 ))
    HAS_BACKEND=1
  fi

  if [[ -f "$dir/package.json" ]]; then
    cmd="npm run build && npm test"
    [[ "$rel" != "." ]] && cmd="cd $rel && $cmd"
    DETECTED+=("$rel|package.json|$cmd|frontend"); N_DETECTED=$(( N_DETECTED + 1 ))
    HAS_FRONTEND=1
  fi
}

detect_in "$ROOT_DIR"
while IFS= read -r sub; do
  [[ -n "$sub" ]] || continue
  detect_in "$sub"
done < <(find "$ROOT_DIR" -mindepth 1 -maxdepth 1 -type d \
           ! -name '.*' ! -name node_modules ! -name target ! -name build ! -name dist ! -name out \
           2>/dev/null | sort)

# ── Resolution ────────────────────────────────────────────────────
# Every value here comes from the config. Detection decides only where the root
# command is allowed to stand in for a stack, which is a question about the
# shape of the project and not about what verifies it.
ROOT_CMD="$CFG_ROOT"; BACKEND="$CFG_BACKEND"; FRONTEND="$CFG_FRONTEND"

if [[ $HAS_BACKEND -eq 0 || $HAS_FRONTEND -eq 0 ]]; then
  [[ -z "$BACKEND"  && $HAS_FRONTEND -eq 0 ]] && BACKEND="$CFG_ROOT"
  [[ -z "$FRONTEND" && $HAS_BACKEND  -eq 0 ]] && FRONTEND="$CFG_ROOT"
  # The other way round too: a one-stack project whose only answer is that
  # stack's key has that command as its whole-project verification.
  if [[ -z "$ROOT_CMD" ]]; then
    if   [[ $HAS_BACKEND  -eq 1 ]]; then ROOT_CMD="$BACKEND"
    elif [[ $HAS_FRONTEND -eq 1 ]]; then ROOT_CMD="$FRONTEND"
    fi
  fi
fi

SOURCE="none"
if [[ -n "$CFG_ROOT$CFG_BACKEND$CFG_FRONTEND" ]]; then
  SOURCE="config"
elif [[ $N_DETECTED -gt 0 ]]; then
  SOURCE="detected"
fi

# The one thing worth saying out loud: an answer for a stack the project does
# not appear to have. It is used as written — a Makefile-driven frontend is a
# real thing and detection knows three build files — but a typo in the key name
# lands here too, and silence would leave the command sitting unused.
[[ -n "$CFG_BACKEND"  && $HAS_BACKEND  -eq 0 ]] && \
  note "SDD_BUILD_BACKEND is set and no pom.xml, build.gradle or build.gradle.kts was found. The command is used as written — check the key name if that is not what was meant."
[[ -n "$CFG_FRONTEND" && $HAS_FRONTEND -eq 0 ]] && \
  note "SDD_BUILD_FRONTEND is set and no package.json was found. The command is used as written — check the key name if that is not what was meant."

# ── Output ────────────────────────────────────────────────────────
printf 'SOURCE=%s\n' "$SOURCE"
printf 'ROOT=%s\n' "$ROOT_CMD"
printf 'BACKEND=%s\n' "$BACKEND"
printf 'FRONTEND=%s\n' "$FRONTEND"

printf '\nDETECTED:\n'
for d in ${DETECTED[@]+"${DETECTED[@]}"}; do printf '%s\n' "$d"; done

printf '\nNOTES:\n'
for n in ${NOTES[@]+"${NOTES[@]}"}; do printf '%s\n' "$n"; done

exit 0
