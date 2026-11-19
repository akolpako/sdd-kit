#!/usr/bin/env bash
# The spawn prompt of one assignment, rendered from a template — the whole text
# a role is given, written to a file the role is pointed at.
#
# The text never passes through the command that spawns: a prompt retyped into
# a spawn call costs its whole length in output and can come out reworded, with
# nothing to tell. The command passes one line, PASS=, and the role reads the
# rest from disk. What goes into a prompt is `.sdd/prompts/`, and the values are
# this run's own — the gate's, and the `KEY=value` arguments for what only a
# human or a role could have said.
#
# Usage: spawn-prompt.sh <command> <FeatureName> <scope> [KEY=value ...] [--print]
#
# Prints:
#   PROMPT=<path>   .sdd/run/<command>-<FeatureName>-<scope>.md (init:
#                   init-<scope>.md), absolute, overwritten by the next run of
#                   the same assignment
#   PASS=<line>     the whole of what the spawn call carries
# --print prints the prompt itself instead and writes no file — for a human
# reading what a role would get.
#   init            takes no feature name: spawn-prompt.sh init <scope> [KEY=value ...]
#   <scope>         the third field of the gate's SPAWN: record
#   KEY=value       a value the gate cannot know: KEPT=, HELD=, TRIAGE=,
#                   FINDINGS=, BASE=. Nothing may be empty — pass `none` where there is
#                   nothing, so a forgotten argument stays distinguishable from
#                   an answer of "none". BASE= is the one that is not rendered
#                   from the argument: it is handed to the gate as its base-ref
#                   — two detections of a review set produce two sets — and what
#                   the prompt carries is the base the gate resolved.
#   -               the values that are somebody's words — TRIAGE=, FINDINGS= —
#                   read from stdin instead, as blocks under a `KEY:` line of
#                   their own, passed through a quoted here-document:
#                     spawn-prompt.sh code-fix Cart findings-backend - <<'SDD_VALUES'
#                     TRIAGE:
#                     the human's answer
#                     FINDINGS:
#                     F-01 …
#                     SDD_VALUES
#                   On a command line inside double quotes, a backtick in
#                   them would run and a `$` would expand. A key given both
#                   ways is an error.
#
# Every prompt opens with two lines written by this script rather than by a
# template. The first names the core every role works under — `.sdd/AGENTS.md`
# and any `.sdd/rules/*.md` — to be read unless the host already loaded it: a
# Copilot CLI sub-agent is handed neither, and nothing else would tell it that
# nobody commits. The second is the working directory: a role is handed `.sdd/...` and `_docs/...` paths by the
# assignment and by every protocol it carries, and nothing else in the prompt
# says what they are relative to. One that cannot resolve a path widens its
# search until it finds something, and widening ends at `/`.
#
# With SDD_FEEDBACK=1 in `.sdd/sdd.conf`, every prompt closes with a paragraph
# on the feedback log and the `feedback.sh` call for this role, command and
# feature (see feedback.sh). Without it, nothing is added.
#
# Templates: `.sdd/prompts/<command>-<scope>.md`, addressed to the role.
#   {{KEY}}            inline, replaced by the value; a multi-line value here
#                      is an error, not a squashed line. An empty value reads
#                      `(none)`, as a block does: a sentence with a hole in it
#                      reads as a number or a ref nobody gave
#   {{KEY}} alone on a line, and {{SECTION:NAME}}
#                      the block form: the whole value, or the whole section of
#                      the gate's output. Nothing to print reads `(none)`
#   A placeholder with no value is an error and no prompt is printed: half an
#   assignment is worse than none.
#
# Exit codes: 0 — the prompt was written (printed, under --print); 1 — the environment is wrong;
#             2 — nothing to render: the gate stopped, this run has no such
#             assignment, there is no template for it, or a value is missing.

set -uo pipefail
SDD_HERE="${0%/*}"; [[ "$SDD_HERE" == "$0" ]] && SDD_HERE="."
[[ -r "$SDD_HERE/lib/log.sh" ]] && . "$SDD_HERE/lib/log.sh"

SCRIPT_DIR="$(cd "$SDD_HERE" && pwd)"
[[ -r "$SDD_HERE/lib/conf.sh" ]] && . "$SDD_HERE/lib/conf.sh"
GATE="$SCRIPT_DIR/gate.sh"
PROMPTS="$SCRIPT_DIR/../prompts"

[[ -x "$GATE" ]]     || { printf 'ERROR=not executable: %s\n' "$GATE" >&2; exit 1; }
[[ -d "$PROMPTS" ]]  || { printf 'ERROR=no prompts directory: %s\n' "$PROMPTS" >&2; exit 1; }

# ── Arguments ─────────────────────────────────────────────────────
CMD="${1:-}"
case "$CMD" in
  init|specify|review|implement|code-review|code-fix|actualize) ;;
  new) printf 'ERROR=/sdd-next-story spawns nobody: there is no prompt to render\n' >&2; exit 1 ;;
  "")  printf 'ERROR=no command: spawn-prompt.sh <command> <FeatureName> <scope> [KEY=value ...]\n' >&2; exit 1 ;;
  *)   printf 'ERROR=unknown command: %s\n' "$CMD" >&2; exit 1 ;;
esac

# The internal token and the slash command a human types are not always the
# same word: /sdd-spec-review runs under the token `review`.
SLASH="$CMD"
[[ "$CMD" == "review" ]] && SLASH="spec-review"

FEATURE=""
if [[ "$CMD" == "init" ]]; then
  SCOPE="${2:-}"
  shift $(( $# > 2 ? 2 : $# ))
else
  FEATURE="${2:-}"
  SCOPE="${3:-}"
  [[ -n "$FEATURE" ]] || { printf 'ERROR=no feature name: spawn-prompt.sh %s <FeatureName> <scope>\n' "$CMD" >&2; exit 1; }
  shift $(( $# > 3 ? 3 : $# ))
fi
[[ -n "$SCOPE" ]] || { printf 'ERROR=no scope: it is the third field of the gate SPAWN: record\n' >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sdd-prompt.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
VALS="$TMP/values"; SECS="$TMP/sections"; ARGS="$TMP/arguments"
mkdir -p "$VALS" "$SECS" "$ARGS"

BASE_ARG=""
FROM_STDIN=0
PRINT=0
while (( $# > 0 )); do
  case "$1" in
    -)
      FROM_STDIN=1
      ;;
    --print)
      PRINT=1
      ;;
    [A-Z]*=*)
      key="${1%%=*}"; val="${1#*=}"
      case "$key" in
        *[!A-Z0-9_]*) printf 'ERROR=not a key: %s — KEY=value, upper case\n' "$key" >&2; exit 1 ;;
      esac
      [[ -n "$val" ]] || { printf 'ERROR=empty value: %s= — pass `none` where there is nothing\n' "$key" >&2; exit 1; }
      printf '%s' "$val" > "$ARGS/$key"
      # BASE is an input to the gate, not a value to render: review-set.sh
      # resolves it — detecting one where the human named none, dropping one it
      # has nothing to take a diff against — and the resolved value is what the
      # review set was actually taken against. An argument shadowing it would
      # hand the role a prompt naming a base and an empty root beside it.
      [[ "$key" == "BASE" ]] && { BASE_ARG="$val"; rm -f "$ARGS/BASE"; }
      ;;
    *) printf 'ERROR=not KEY=value: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

# The blocks of stdin: a `KEY:` line opens one, and everything up to the next
# such line is its value, with the blank lines around it trimmed.
if [[ $FROM_STDIN -eq 1 ]]; then
  cat > "$TMP/stdin"
  mkdir -p "$TMP/stdin.d" || exit 1
  awk -v dir="$TMP/stdin.d" '
    /^[A-Z][A-Z0-9_]*:$/ { key = substr($0, 1, length($0) - 1); n[key] = 0; order[++k] = key; next }
    key == "" { if (NF) { bad = 1 }; next }
    { n[key]++; line[key, n[key]] = $0 }
    END {
      if (bad) { print "ERROR=stdin holds text before its first KEY: line" > "/dev/stderr"; exit 1 }
      for (i = 1; i <= k; i++) {
        key = order[i]; first = 1; last = n[key]
        while (first <= last && line[key, first] ~ /^[[:space:]]*$/) first++
        while (last >= first && line[key, last] ~ /^[[:space:]]*$/) last--
        f = dir "/" key
        printf "" > f
        for (j = first; j <= last; j++) print line[key, j] > f
        close(f)
      }
    }
  ' "$TMP/stdin" || exit 1
  for f in "$TMP/stdin.d"/*; do
    [[ -f "$f" ]] || continue
    key="${f##*/}"
    [[ -s "$f" ]] || { printf 'ERROR=empty value: %s: on stdin — write `none` where there is nothing\n' "$key" >&2; exit 1; }
    [[ "$key" != "BASE" ]] || { printf 'ERROR=BASE= is an argument, never a block of stdin\n' >&2; exit 1; }
    [[ ! -f "$ARGS/$key" ]] || { printf 'ERROR=%s is given twice, as an argument and on stdin\n' "$key" >&2; exit 1; }
    # The file holds the value with its last newline; a value is compared and
    # rendered without it, as an argument would be.
    printf '%s' "$(cat "$f")" > "$ARGS/$key"
  done
fi

TEMPLATE="$PROMPTS/$CMD-$SCOPE.md"
if [[ ! -f "$TEMPLATE" ]]; then
  printf 'ERROR=no template .sdd/prompts/%s-%s.md: /sdd-%s has no assignment called %s\n' "$CMD" "$SCOPE" "$SLASH" "$SCOPE" >&2
  exit 2
fi

# ── This run, as the gate sees it ─────────────────────────────────
GATE_ERR="$TMP/gate.err"
if [[ "$CMD" == "init" ]]; then
  GATE_OUT="$("$GATE" init --prompt-data 2>"$GATE_ERR")"; GATE_RC=$?
elif [[ "$CMD" == "code-review" ]]; then
  GATE_OUT="$("$GATE" "$CMD" "$FEATURE" "$BASE_ARG" --prompt-data 2>"$GATE_ERR")"; GATE_RC=$?
else
  GATE_OUT="$("$GATE" "$CMD" "$FEATURE" --prompt-data 2>"$GATE_ERR")"; GATE_RC=$?
fi

if [[ $GATE_RC -eq 1 ]]; then
  [[ -s "$GATE_ERR" ]] && cat "$GATE_ERR" >&2
  exit 1
fi

# A here-string, not `printf | awk`: awk exits at the first match, and a printf
# still writing into the pipe then fails with "Broken pipe" on stderr wherever
# SIGPIPE is ignored (a CI runner is one such place).
VERDICT="$(awk 'index($0, "GATE=") == 1 { sub(/^[^=]*=/, ""); print; exit }' <<<"$GATE_OUT")"
if [[ "$VERDICT" != "ok" && "$VERDICT" != "ask" ]]; then
  printf 'ERROR=the gate says GATE=%s for /sdd-%s: nothing is spawned from this run, so no prompt is rendered\n' "$VERDICT" "$SLASH" >&2
  exit 2
fi

# The gate's own output format, read the way every other script reads it: a
# KEY=value line, then SECTION: blocks that end at the next header.
printf '%s\n' "$GATE_OUT" | awk -v vals="$VALS" -v secs="$SECS" '
  /^[A-Z][A-Z0-9_]*=/ {
    key = $0; sub(/=.*/, "", key)
    value = $0; sub(/^[^=]*=/, "", value)
    printf "%s", value > (vals "/" key)
    next
  }
  /^[A-Z][A-Z0-9_]*:$/ {
    name = $0; sub(/:$/, "", name)
    current = secs "/" name
    printf "" > current
    next
  }
  NF && current { print >> current }
'

# The assignment itself: the SPAWN: record of this scope, relayed field by field.
RECORD="$(printf '%s\n' "$GATE_OUT" | awk -v want="$SCOPE" '
  /^[A-Z][A-Z0-9_]*:$/ { inside = ($0 == "SPAWN:"); next }
  inside && NF {
    n = split($0, f, "|")
    if (n == 3 && f[3] == want) { print; exit }
  }
')"
if [[ -z "$RECORD" ]]; then
  printf 'ERROR=this run has no assignment for %s: the gate printed no SPAWN: record with that scope\n' "$SCOPE" >&2
  exit 2
fi

# An argument wins over a key of the same name: it is what the human or the role
# said, and the gate could only have guessed at it. `BASE` is not among them —
# it was taken out above, because there the gate resolves rather than guesses.
for f in "$ARGS"/*; do
  [[ -f "$f" ]] && cp "$f" "$VALS/$(basename "$f")"
done

ROLE="${RECORD%%|*}"
rest="${RECORD#*|}"
PROTOCOLS="${rest%%|*}"
printf '%s' "$ROLE" > "$VALS/ROLE"
printf '%s' "$SCOPE" > "$VALS/SCOPE"
printf '%s' "$PROTOCOLS" | tr ',' '\n' > "$VALS/PROTOCOLS"

# ── Rendering ─────────────────────────────────────────────────────
FAIL=0

fail() { printf 'ERROR=%s\n' "$1" >&2; FAIL=1; }

# A block token owns its line: the value goes in whole, however many lines it is.
emit_block() {
  local token="$1" name body
  case "$token" in
    SECTION:*)
      name="${token#SECTION:}"
      if [[ ! -f "$SECS/$name" ]]; then
        fail "no section $name: in the gate output — /sdd-$SLASH does not print it"
        return
      fi
      body="$(cat "$SECS/$name")"
      ;;
    *)
      if [[ ! -f "$VALS/$token" ]]; then
        fail "no value for {{$token}}: the gate did not print it and no argument carried it"
        return
      fi
      body="$(cat "$VALS/$token")"
      ;;
  esac
  if [[ -n "$body" ]]; then printf '%s\n' "$body"; else printf '(none)\n'; fi
}

# An inline token is one line of a sentence: a value with a newline in it would
# be read as the sentence ending early.
render_inline() {
  local line="$1" out="" head token value
  while [[ "$line" == *'{{'*'}}'* ]]; do
    head="${line%%\{\{*}"
    out="$out$head"
    line="${line#*\{\{}"
    token="${line%%\}\}*}"
    line="${line#*\}\}}"
    if [[ ! -f "$VALS/$token" ]]; then
      fail "no value for {{$token}}: the gate did not print it and no argument carried it"
      return
    fi
    value="$(cat "$VALS/$token")"
    if [[ "$value" == *$'\n'* ]]; then
      fail "the value of {{$token}} is more than one line: give the placeholder a line of its own"
      return
    fi
    [[ -n "$value" ]] || value='(none)'
    out="$out$value"
  done
  printf '%s%s\n' "$out" "$line"
}

RENDERED="$TMP/prompt.txt"
: > "$RENDERED"

# The root every relative path below is counted from. It is the directory this
# script was run in, which is the project root the command was typed in — the
# same one the gate read `_docs/` from a moment ago. Written here so that a
# prompt added later cannot be the one that leaves it out.
CORE='`.sdd/AGENTS.md`'
for r in .sdd/rules/*.md; do
  [[ -f "$r" ]] && CORE="$CORE, \`$r\`"
done
printf 'The rules every role works under: %s. Read them first, unless your\ninstructions already carry them.\n\n' "$CORE" >> "$RENDERED"
printf 'Working directory: %s\nEvery `.sdd/...` and `_docs/...` path below and in the protocols it names is\nrelative to it.\n\n' "$PWD" >> "$RENDERED"

while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    '{{'*'}}')
      inner="${line#\{\{}"; inner="${inner%\}\}}"
      case "$inner" in
        *'{{'*|*'}}'*) render_inline "$line" >> "$RENDERED" ;;
        *) emit_block "$inner" >> "$RENDERED" ;;
      esac
      ;;
    *'{{'*) render_inline "$line" >> "$RENDERED" ;;
    *) printf '%s\n' "$line" >> "$RENDERED" ;;
  esac
done < "$TEMPLATE"

# The feedback log, when the project turned it on (SDD_FEEDBACK=1): one closing
# paragraph, the same in every scope, with the call already filled in — the
# role picks the kind and writes the words. Off, the prompt carries no word of
# it, and no golden changes.
if declare -F sdd_feedback_on >/dev/null && sdd_feedback_on; then
  cat >> "$RENDERED" <<EOF_TAIL

## Feedback on the engine

This project keeps a log of what gets in the way of the engine's assignments.
When something in this one did, write one record per fact, naming the engine
file it is about — a script, a protocol, this assignment, a skill:

.sdd/scripts/feedback.sh <kind> --by=$ROLE --command=$CMD --feature=${FEATURE:--} - <<'SDD_TEXT'
<what happened, and the file it is about>
SDD_TEXT

<kind> is one of: \`script\` — a script failed or printed what it could not
have; \`conflict\` — two engine files ask for different things, both named;
\`missing\` — the assignment lacked something: what you looked up, and where you
found it; \`unused\` — it had you read or load something you did not need;
\`skill\` — a skill's rule is wrong for this project, or its script failed.
Write it when it happens, not at the end; a problem you worked around is
still one — a script that exited non-zero, a rule you had to guess at. A
record changes nothing in your work: a script that failed is still reported
in your reply. Nothing to say — write nothing.
EOF_TAIL
fi

# Half an assignment is worse than none: nothing is printed unless all of it is.
if [[ $FAIL -ne 0 ]]; then
  printf 'ERROR=no prompt was printed for %s: fix the values above and run it again\n' "$SCOPE" >&2
  exit 2
fi

if [[ $PRINT -eq 1 ]]; then
  cat "$RENDERED"
  exit 0
fi

# Written whole or not at all: a role pointed at half a file would take it for
# the whole assignment.
OUT_DIR="$PWD/.sdd/run"
if [[ "$CMD" == "init" ]]; then OUT="$OUT_DIR/init-$SCOPE.md"; else OUT="$OUT_DIR/$CMD-$FEATURE-$SCOPE.md"; fi
mkdir -p "$OUT_DIR" && cp "$RENDERED" "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT" \
  || { rm -f "$OUT.tmp"; printf 'ERROR=could not write %s\n' "$OUT" >&2; exit 1; }
printf 'PROMPT=%s\nPASS=Your assignment is in %s. Read it whole and follow it.\n' "$OUT" "$OUT"
exit 0
