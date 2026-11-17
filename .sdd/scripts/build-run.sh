#!/usr/bin/env bash
# Runs the project's build — the human's command, as build-command.sh resolves
# it — and prints the verdict, not the build's own output.
#
# A build prints thousands of lines, and an orchestrator that runs one reads
# every one of them to find out whether it passed. The exit code already says
# so. The output goes to a file; what comes back is green or red, and on red the
# tail where the failure usually is. The whole log stays on disk for whoever
# needs more than the tail.
#
# Usage: build-run.sh <root|backend|frontend> [<project-root>]
#   root       BUILD_ROOT, the whole-project verification
#   backend    BUILD_BACKEND
#   frontend   BUILD_FRONTEND
#
# Prints:
#   BUILD=green|red     the exit code of the command, and nothing else, decides
#   STACK=<the argument>
#   COMMAND=<the command that ran>
#   EXIT=<its exit code>
#   LOG=<path>          .sdd/build/<stack>.log, the whole output, stdout and
#                       stderr together, overwritten by the next run
#   TAIL:               on red only — the last 40 lines of the log
#
# Exit codes: 0 — the build ran, and BUILD= is the answer, red included;
#             1 — the environment is wrong; 2 — the project has no command
#             for that stack: nothing ran, and nothing is guessed in its place.

set -uo pipefail
SDD_HERE="${0%/*}"; [[ "$SDD_HERE" == "$0" ]] && SDD_HERE="."
[[ -r "$SDD_HERE/lib/log.sh" ]] && . "$SDD_HERE/lib/log.sh"

SCRIPT_DIR="$(cd "$SDD_HERE" && pwd)"
STACK="${1:-}"
ROOT_DIR="${2:-.}"

case "$STACK" in
  root|backend|frontend) ;;
  *) printf 'ERROR=not a stack: %s — root, backend or frontend\n' "${STACK:-<empty>}" >&2; exit 1 ;;
esac
[[ -d "$ROOT_DIR" ]] || { printf 'ERROR=not a directory: %s\n' "$ROOT_DIR" >&2; exit 1; }
cd "$ROOT_DIR" || exit 1

BC_OUT="$("$SCRIPT_DIR/build-command.sh" .)" || exit 1
KEY="$(printf '%s' "$STACK" | tr '[:lower:]' '[:upper:]')"
CMD="$(printf '%s\n' "$BC_OUT" | awk -v k="$KEY" 'index($0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit }')"
if [[ -z "$CMD" ]]; then
  printf 'ERROR=no build command for %s: .sdd/sdd.conf answers none — it is written with `spec-edit.sh conf-set`, never guessed\n' "$STACK" >&2
  exit 2
fi

LOG_DIR=".sdd/build"
mkdir -p "$LOG_DIR" || { printf 'ERROR=could not create %s\n' "$LOG_DIR" >&2; exit 1; }
LOG="$LOG_DIR/$STACK.log"

# The human's line, run as they wrote it: `cd` and `&&` chains included. No
# stdin — a build that stops for an answer would wait on a terminal nobody
# reads.
bash -c "$CMD" > "$LOG" 2>&1 < /dev/null
rc=$?

if [[ $rc -eq 0 ]]; then BUILD="green"; else BUILD="red"; fi
printf 'BUILD=%s\nSTACK=%s\nCOMMAND=%s\nEXIT=%s\nLOG=%s\n' "$BUILD" "$STACK" "$CMD" "$rc" "$LOG"
if [[ "$BUILD" == "red" ]]; then
  printf '\nTAIL:\n'
  tail -n 40 "$LOG"
fi
exit 0
