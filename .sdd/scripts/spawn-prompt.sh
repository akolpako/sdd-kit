#!/usr/bin/env bash
# The spawn prompt of one assignment, rendered from a template — the whole text
# a role is given, printed ready to relay.
#
# The command runs this and hands the output to the role word for word: it adds
# nothing and drops nothing. What goes into a prompt is `.sdd/prompts/`, and the
# values are this run's own — the gate's, and the `KEY=value` arguments for what
# only a human or a role could have said.
#
# Usage: spawn-prompt.sh <command> <FeatureName> <scope> [KEY=value ...]
#   init            takes no feature name: spawn-prompt.sh init <scope> [KEY=value ...]
#   <scope>         the third field of the gate's SPAWN: record
#   KEY=value       a value the gate cannot know: KEPT=, TRIAGE=, FINDINGS=,
#                   BASE=. Nothing may be empty — pass `none` where there is
#                   nothing, so a forgotten argument stays distinguishable from
#                   an answer of "none". BASE= is the one that is not rendered
#                   from the argument: it is handed to the gate as its base-ref
#                   — two detections of a review set produce two sets — and what
#                   the prompt carries is the base the gate resolved.
#
# Every prompt opens with the working directory, written by this script rather
# than by a template: a role is handed `.sdd/...` and `_docs/...` paths by the
# assignment and by every protocol it carries, and nothing else in the prompt
# says what they are relative to. One that cannot resolve a path widens its
# search until it finds something, and widening ends at `/`.
#
# Templates: `.sdd/prompts/<command>-<scope>.md`, addressed to the role.
#   {{KEY}}            inline, replaced by the value; a multi-line value here
#                      is an error, not a squashed line
#   {{KEY}} alone on a line, and {{SECTION:NAME}}
#                      the block form: the whole value, or the whole section of
#                      the gate's output. Nothing to print reads `(none)`
#   A placeholder with no value is an error and no prompt is printed: half an
#   assignment is worse than none.
#
# Exit codes: 0 — the prompt was printed; 1 — the environment is wrong;
#             2 — nothing to render: the gate stopped, this run has no such
#             assignment, there is no template for it, or a value is missing.

set -uo pipefail
[[ -r "$(dirname "$0")/lib/log.sh" ]] && . "$(dirname "$0")/lib/log.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
while (( $# > 0 )); do
  case "$1" in
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

VERDICT="$(printf '%s\n' "$GATE_OUT" | awk 'index($0, "GATE=") == 1 { sub(/^[^=]*=/, ""); print; exit }')"
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

# Half an assignment is worse than none: nothing is printed unless all of it is.
if [[ $FAIL -ne 0 ]]; then
  printf 'ERROR=no prompt was printed for %s: fix the values above and run it again\n' "$SCOPE" >&2
  exit 2
fi

cat "$RENDERED"
exit 0
