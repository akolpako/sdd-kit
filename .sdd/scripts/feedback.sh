#!/usr/bin/env bash
# Writes one remark about the engine into the feedback log — a fact about a
# script, a protocol, a prompt or a skill that got in the way of a run, for the
# human who maintains the engine to read after the fact.
#
# The log is like the run log: written, never read. No script, prompt or command
# branches on it, and a remark changes nothing in the run that wrote it — a
# script that failed is still reported as it would be without one.
#
# Usage: feedback.sh <kind> --by=<role|orchestrator> --command=<command>
#                    [--feature=<FeatureName>] -
#   <kind>       a closed list, so the file holds remarks about the engine and
#                not prose about the project:
#                  script    an engine script failed, or printed what the
#                            assignment says it could not
#                  conflict  two engine files ask for different things — both
#                            named
#                  missing   the assignment lacked something: what had to be
#                            looked up, and where it was found
#                  unused    the assignment had something read or loaded that
#                            was not needed — a file, a protocol, a skill
#                  skill     a skill's rule is wrong for this project, or its
#                            script did not work
#   -            the remark itself, on stdin, through a quoted here-document
#
# Writes: <log dir>/feedback.log, appended, never rotated — the log dir is
# SDD_LOG_DIR as lib/log.sh resolves it (`.sdd/log/` by default); SDD_LOG does
# not switch this on or off. One record per call:
#   ## <YYYY-MM-DDTHH:MM:SS> | <kind> | <by> | <command> | <FeatureName or ->
#   <the remark, as given>
#   (an empty line)
#
# On only when SDD_FEEDBACK=1 is in `.sdd/sdd.conf` (or the environment). Off,
# it reads its stdin, writes nothing and exits 0: an instruction that outlived
# the key fails nothing.
#
# Prints FEEDBACK=written, or FEEDBACK=off.
# Exit codes: 0 — written, or off; 1 — the environment is wrong (the log cannot
#             be written); 2 — the call is wrong: an unknown kind, no --by= or
#             --command=, no `-`, or an empty remark.

set -uo pipefail
SDD_HERE="${0%/*}"; [[ "$SDD_HERE" == "$0" ]] && SDD_HERE="."
[[ -r "$SDD_HERE/lib/log.sh" ]] && . "$SDD_HERE/lib/log.sh"
[[ -r "$SDD_HERE/lib/conf.sh" ]] || { printf 'ERROR=missing: %s/lib/conf.sh\n' "$SDD_HERE" >&2; exit 1; }
. "$SDD_HERE/lib/conf.sh"

KIND="${1:-}"; BY=""; COMMAND=""; FEATURE="-"; STDIN=0
[[ $# -gt 0 ]] && shift
for arg in ${1+"$@"}; do
  case "$arg" in
    --by=*)      BY="${arg#--by=}" ;;
    --command=*) COMMAND="${arg#--command=}" ;;
    --feature=*) FEATURE="${arg#--feature=}" ;;
    -)           STDIN=1 ;;
    *) printf 'ERROR=unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if ! sdd_feedback_on; then
  [[ $STDIN -eq 1 ]] && cat > /dev/null
  printf 'FEEDBACK=off\n'
  exit 0
fi

case "$KIND" in
  script|conflict|missing|unused|skill) ;;
  *) printf 'ERROR=not a kind: %s — script, conflict, missing, unused or skill\n' "${KIND:-<empty>}" >&2; exit 2 ;;
esac
[[ -n "$BY" && -n "$COMMAND" ]] || { printf 'ERROR=--by= and --command= are both required: who writes, and in which command\n' >&2; exit 2; }
[[ $STDIN -eq 1 ]] || { printf 'ERROR=the remark goes on stdin, after `-`, through a quoted here-document\n' >&2; exit 2; }
TEXT="$(cat)"
[[ -n "${TEXT//[[:space:]]/}" ]] || { printf 'ERROR=an empty remark: nothing to write — with nothing to say, make no call\n' >&2; exit 2; }

DIR="${SDD_LOG_DIR:-}"
if [[ -z "$DIR" ]]; then
  while IFS= read -r line; do DIR="${line#*=}"; done <<EOF_CONF
$(sdd_conf_read "$PWD/.sdd/sdd.conf" '^SDD_LOG_DIR$')
EOF_CONF
fi
[[ -n "$DIR" ]] || DIR="$PWD/.sdd/log"
case "$DIR" in /*) ;; *) DIR="$PWD/$DIR" ;; esac
mkdir -p "$DIR" 2>/dev/null || { printf 'ERROR=could not create %s\n' "$DIR" >&2; exit 1; }

{ printf '## %s | %s | %s | %s | %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$KIND" "$BY" "$COMMAND" "$FEATURE"
  printf '%s\n\n' "$TEXT"; } >> "$DIR/feedback.log" || { printf 'ERROR=could not write %s/feedback.log\n' "$DIR" >&2; exit 1; }
printf 'FEEDBACK=written\n'
exit 0
