#!/usr/bin/env bash
# The engine feedback of every project this clone was installed into, grouped by
# kind — for the human who maintains the engine. Reads, never writes.
#
# Usage: ./feedback-collect.sh [<kind>]
#   <kind>   script | conflict | missing | unused | skill — only that kind
#
# Reads installed-repos.txt next to this file (`<path><TAB><host>` per line) and
# the `.sdd/log/feedback.log` of each path, as `.sdd/scripts/feedback.sh` wrote
# it. A project with no log is skipped. Not installed: it lives outside `.sdd/`.

set -uo pipefail
HERE="${0%/*}"; [[ "$HERE" == "$0" ]] && HERE="."
LIST="$HERE/installed-repos.txt"
WANT="${1:-}"
case "$WANT" in ""|script|conflict|missing|unused|skill) ;;
  *) printf 'ERROR=not a kind: %s\n' "$WANT" >&2; exit 2 ;; esac
[[ -r "$LIST" ]] || { printf 'ERROR=no %s\n' "$LIST" >&2; exit 1; }

for kind in script conflict missing unused skill; do
  [[ -z "$WANT" || "$WANT" == "$kind" ]] || continue
  printf '# %s\n\n' "$kind"
  while IFS=$'\t' read -r repo _; do
    log="$repo/.sdd/log/feedback.log"
    [[ -n "$repo" && -r "$log" ]] || continue
    awk -v kind="$kind" -v repo="$repo" '
      /^## / { n = split($0, f, " \\| "); keep = (n >= 5 && f[2] == kind); if (keep) print "## " repo " | " substr($0, 4); next }
      keep { print }
    ' "$log"
  done < "$LIST"
done
