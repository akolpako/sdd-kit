# shellcheck shell=bash
# The record a script run leaves on disk, written in one place.
#
# Sourced, never run, and sourced before the script reads its arguments, so the
# module sees the raw `$@`:
#   [[ -r "$(dirname "$0")/lib/log.sh" ]] && . "$(dirname "$0")/lib/log.sh"
#
# The scripts are run by the agent, inside a host session. Their output goes
# into a context the human never sees and which dies with the session, so a run
# that went wrong leaves nothing to look at afterwards — no argv, no exit code,
# no ERROR= line. This module gives every run a record under `.sdd/log/`.
#
# The log is written and never read. No script, prompt or command may branch on
# its contents: the moment something reads it, it becomes state carried between
# steps outside the working tree, which is the one thing the engine does not do.
# It is for a human, after the fact.
#
# The mechanism is a re-exec wrapper. The first shell to reach the sourcing line
# runs the script again as a child with both streams captured, replays them to
# the real streams unchanged, appends the record and exits with the child's
# status. The parent executes only the script's header, above the sourcing line;
# the work happens once, in the child.
#
# Not an EXIT trap, which would be shorter: gate.sh, spec-edit.sh and
# spawn-prompt.sh already own one for their temporary files, and a second
# `trap … EXIT` silently replaces the first. Not explicit calls either — gate.sh
# alone has dozens of exit paths, and the branch somebody forgets to instrument
# is the branch that was failing. The wrapper catches every path, a `set -u`
# abort and a syntax error included.
#
# The invariant everything else rests on: **stdout byte-identical, stderr
# byte-identical, exit code the child's.** The goldens under `tests/` compare
# exactly those three, and a diff there is this module breaking its promise.
#
# A nested script's record is appended BEFORE its parent's — gate.sh runs
# feature-state.sh, build-command.sh, next-req.sh and review-set.sh, and each of
# those records is written while the gate is still running, where the gate's own
# is written after its child exits. This is the mechanism, not a bug. The run id
# is inherited through the environment and ties the records of one run together.
#
# What this module must never do: change a byte on stdout or stderr, or the exit
# code; fail a script — every write is best-effort, and an unwritable log
# directory is silence, not an error; detect the host; create anything when
# there is no `.sdd/` in the current directory and no SDD_LOG_DIR, so a script
# run from an unrelated tree writes nothing.
#
# Configuration — `.sdd/sdd.conf`, optional, absent by default, created by the
# human. The engine's built-in values below are the defaults and no file is
# shipped. Precedence: the environment, then the file, then these defaults.
#
#   SDD_LOG        0 turns logging off entirely           (default: on)
#   SDD_LOG_DIR    where records are written              (default: <cwd>/.sdd/log)
#   SDD_LOG_MAX    size at which sdd.log rotates to sdd.log.1  (default: 1 MB)
#   SDD_LOG_HEAD   leading lines kept per stream          (default: 40)
#   SDD_LOG_TAIL   trailing lines kept per stream         (default: 10)
#
# The file is parsed, not sourced: `. .sdd/sdd.conf` is one line shorter and
# would execute whatever the file contains on every run of every script. Unknown
# keys are ignored in silence. It is read once, in the outer wrapper; the child
# and everything nested below it receive the resolved values through the
# environment and never read it again.

SDD_LOG_NAME="$(basename "$0")"

# spawn-prompt.sh is exempt from the per-stream cap: its stdout is logged whole.
# That output is the assignment a role received, and *the role did the wrong
# thing* is a question only the full text answers. It cannot be recovered any
# other way — the prompt is rendered from a gate run over the tree as it stood
# at that moment, and by the time anybody is reading the log the tree has moved
# on. Everything else in the log is a verdict or an edit, small by nature and
# reproducible by re-running; this one is neither. Leave the exemption where it
# is rather than making the module uniform.
SDD_LOG_FULL_STDOUT=" spawn-prompt.sh "

# ── Time ──────────────────────────────────────────────────────────
# Milliseconds since the epoch. `date +%s%N` is GNU; BSD date passes %N through
# untouched, so the result is checked for length rather than trusted, and a date
# without nanoseconds costs the duration its fraction and nothing else.
sdd_log_ms() {
  local t
  t="$(date +%s%N 2>/dev/null)"
  case "$t" in
    ''|*[!0-9]*) t="" ;;
  esac
  if [[ ${#t} -ge 19 ]]; then
    printf '%s' "$(( t / 1000000 ))"
  else
    printf '%s000' "$(date +%s 2>/dev/null)"
  fi
}

sdd_log_stamp() { date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null; }

sdd_log_dur() {
  local ms=$(( $2 - $1 ))
  (( ms < 0 )) && ms=0
  printf '%d.%03ds' "$(( ms / 1000 ))" "$(( ms % 1000 ))"
}

# ── The record ────────────────────────────────────────────────────
# argv as `printf %q` writes it, so a quoted argument, an empty one and one
# carrying a newline all come back readable and distinguishable.
sdd_log_argv() { (( $# > 0 )) && printf ' %q' "$@"; return 0; }

sdd_log_rotate() {
  local log="$1" size
  [[ -f "$log" ]] || return 0
  size="$(wc -c <"$log" 2>/dev/null)"
  size="${size// /}"
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  (( size >= SDD_LOG_MAX )) && mv -f "$log" "$log.1" 2>/dev/null
  return 0
}

# One block per stream, every line carrying a `| ` prefix — a KEY=value line a
# script printed cannot then be mistaken for a record of the log's own. A stream
# that produced nothing gets no block. The omission marker carries no prefix, so
# it is not read as output either.
sdd_log_stream() {
  local label="$1" f="$2" head="$3" tail="$4" n
  [[ -s "$f" ]] || return 0
  printf '%s:\n' "$label"
  n="$(awk 'END { print NR }' "$f" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  # awk rather than sed: a stream whose last line carries no newline would
  # otherwise run into the block that follows it.
  awk -v head="$head" -v tail="$tail" -v n="$n" '
    head <= 0 || n <= head + tail { print "| " $0; next }
    NR <= head                    { print "| " $0; next }
    NR == head + 1                { printf "… %d lines omitted\n", n - head - tail }
    NR > n - tail                 { print "| " $0 }
  ' "$f" 2>/dev/null
  return 0
}

sdd_log_record() {
  local rc="$1" start="$2" end="$3" out="$4" err="$5"
  shift 5
  local log="$SDD_LOG_DIR/sdd.log" head="$SDD_LOG_HEAD"
  case "$SDD_LOG_FULL_STDOUT" in *" $SDD_LOG_NAME "*) head=0 ;; esac
  mkdir -p "$SDD_LOG_DIR" 2>/dev/null || return 0
  sdd_log_rotate "$log"
  {
    printf '== %s run=%s exit=%s dur=%s %s%s\n' \
      "$(sdd_log_stamp)" "$SDD_LOG_RUN" "$rc" "$(sdd_log_dur "$start" "$end")" \
      "$SDD_LOG_NAME" "$(sdd_log_argv ${1+"$@"})"
    printf 'cwd=%s\n' "$PWD"
    sdd_log_stream stdout "$out" "$head" "$SDD_LOG_TAIL"
    sdd_log_stream stderr "$err" "$SDD_LOG_HEAD" "$SDD_LOG_TAIL"
    # stderr is silenced before the append, not after: a redirection bash
    # cannot open is reported on whichever stderr is current at that point,
    # and an unwritable log would print onto the script's own.
  } 2>/dev/null >>"$log"
  return 0
}

sdd_log_write_note() {
  local event="$1"
  shift
  [[ -n "${SDD_LOG_DIR:-}" ]] || return 0
  mkdir -p "$SDD_LOG_DIR" 2>/dev/null || return 0
  {
    printf '== %s run=%s note=%s %s\n' \
      "$(sdd_log_stamp)" "${SDD_LOG_RUN:-}" "$event" "$SDD_LOG_NAME"
    printf '%s\n' "$*" | sed 's/^/| /'
  } 2>/dev/null >>"$SDD_LOG_DIR/sdd.log"
  return 0
}

# What a script has to say that its raw output does not carry. Defined as a
# no-op when logging is off, so a caller never branches on whether it is on.
sdd_log_note() { :; }

# ── The child ─────────────────────────────────────────────────────
# The re-exec of the wrapper below, and only it. The flag is dropped from the
# environment on the way in: the scripts this one runs are not this run, and
# each of them wraps and logs itself.
if [[ "${SDD_LOG_CHILD:-}" == "1" ]]; then
  unset SDD_LOG_CHILD
  sdd_log_note() { sdd_log_write_note "$@"; }
  return 0
fi

# ── Configuration ─────────────────────────────────────────────────
# The known keys, as written, one KEY=value per line. A strict read over a fixed
# set: quotes are stripped, comments and blank lines skipped, everything else
# ignored without a word.
sdd_log_conf_read() {
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
      if (key !~ /^SDD_LOG(_DIR|_MAX|_HEAD|_TAIL)?$/) next
      gsub(/^["\047]|["\047]$/, "", val)
      print key "=" val
    }
  ' "$1" 2>/dev/null
}

sdd_log_num() {
  case "${1:-}" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *)           printf '%s' "$1" ;;
  esac
}

# Prints nothing and returns 1 when logging is off — the caller then leaves the
# script to run unwrapped, in this same process.
sdd_log_resolve() {
  local key val dir
  local c_log="" c_dir="" c_max="" c_head="" c_tail=""

  # A run id already in the environment means an outer wrapper resolved
  # everything and exported it. The file is read once per run: a nested script
  # re-reading it could disagree with its own parent halfway through.
  if [[ -z "${SDD_LOG_RUN:-}" && -r "$PWD/.sdd/sdd.conf" ]]; then
    while IFS='=' read -r key val; do
      case "$key" in
        SDD_LOG)      c_log="$val" ;;
        SDD_LOG_DIR)  c_dir="$val" ;;
        SDD_LOG_MAX)  c_max="$val" ;;
        SDD_LOG_HEAD) c_head="$val" ;;
        SDD_LOG_TAIL) c_tail="$val" ;;
      esac
    done <<EOF
$(sdd_log_conf_read "$PWD/.sdd/sdd.conf")
EOF
  fi

  [[ "${SDD_LOG:-${c_log:-1}}" == "0" ]] && return 1

  dir="${SDD_LOG_DIR:-${c_dir:-}}"
  if [[ -z "$dir" ]]; then
    [[ -d "$PWD/.sdd" ]] || return 1
    dir="$PWD/.sdd/log"
  fi
  case "$dir" in /*) ;; *) dir="$PWD/$dir" ;; esac

  SDD_LOG=1
  SDD_LOG_DIR="$dir"
  SDD_LOG_MAX="$(sdd_log_num "${SDD_LOG_MAX:-${c_max:-}}" 1048576)"
  SDD_LOG_HEAD="$(sdd_log_num "${SDD_LOG_HEAD:-${c_head:-}}" 40)"
  SDD_LOG_TAIL="$(sdd_log_num "${SDD_LOG_TAIL:-${c_tail:-}}" 10)"
  SDD_LOG_RUN="${SDD_LOG_RUN:-$(date +%Y%m%d-%H%M%S 2>/dev/null)-$$}"
  export SDD_LOG SDD_LOG_DIR SDD_LOG_MAX SDD_LOG_HEAD SDD_LOG_TAIL SDD_LOG_RUN
  return 0
}

# ── The wrapper ───────────────────────────────────────────────────
# Returns only when it could not capture the run; the script then goes on
# unwrapped, which is the same silence an unwritable log directory gets.
sdd_log_wrap() {
  local out err rc start end
  out="$(mktemp "${TMPDIR:-/tmp}/sdd-log-out.XXXXXX" 2>/dev/null)" || return 1
  err="$(mktemp "${TMPDIR:-/tmp}/sdd-log-err.XXXXXX" 2>/dev/null)" || { rm -f "$out"; return 1; }

  start="$(sdd_log_ms)"
  SDD_LOG_CHILD=1 "${BASH:-bash}" "$0" ${1+"$@"} >"$out" 2>"$err"
  rc=$?
  end="$(sdd_log_ms)"

  cat "$out"
  cat "$err" >&2

  sdd_log_record "$rc" "$start" "$end" "$out" "$err" ${1+"$@"}

  rm -f "$out" "$err"
  exit "$rc"
}

if sdd_log_resolve; then
  sdd_log_wrap ${1+"$@"}
fi
