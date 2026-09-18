#!/usr/bin/env bash
# Reads the requirement numbers a project has handed out and prints the next
# free one.
#
# The number is taken from the files, never counted by eye: a REQ-### handed out
# twice does not fail, it corrupts the compilation quietly and surfaces features
# later.
#
# Two files hold numbers, because a number is taken before it reaches the
# compilation. A feature declares its requirements in _docs/<Feature>/
# new-requirements.md the moment it is specified; the entries of
# _docs/requirements.md are written by /sdd-actualize alone, when
# the feature is finished. Between those two moments the declaration is the
# whole of the reservation, and a second feature specified meanwhile has to be
# handed a number past it.
#
# A project may group its requirements by domain — `REQ-ACC-003` beside
# `REQ-AUTH-001` — and each domain is a sequence of its own: its own marker, its
# own highest entry, its own next number. Ids carrying no domain are one such
# sequence too, the one a project that never groups anything uses throughout.
#
# Usage: next-req.sh [<project-root>] [<domain>]
#        (default: the current directory, and the undomained sequence)
#
# Prints, for the domain asked about:
#   DOMAIN=<domain>     the domain these keys are about; empty for the
#                       undomained sequence
#   NEXT=REQ-…          the next free number of that domain:
#                       max(counter, highest entry + 1, highest declared + 1)
#   COUNTER=REQ-…       what that domain's `<!-- Next free number: -->` marker
#                       says; empty when absent
#   HIGHEST=REQ-…       the highest number an entry of that domain carries;
#                       empty when there are none
#   DECLARED=REQ-…      the highest number a feature declares in that domain;
#                       empty when there are none
#   DECLARED_IN=<Feature>  the feature folder that declares it; empty with it
#   SOURCE=<where>      where NEXT came from: `counter`, `compilation`, `specs`,
#                       `none` when the domain has handed out nothing yet,
#                       `scan` when the candidate the three sources gave was
#                       moved past a number the specs already write, and `taken`
#                       when it could not be moved past them and NEXT is empty
#   TAKEN=REQ-… REQ-…   the candidates the scan below refused, in the order it
#                       tried them; empty when the first one was free
#   COUNT=<n>           how many entries the compilation holds, every domain
#                       counted — the size of the file, not of one sequence
#   DOMAINS:            one record per domain in use, undomained first:
#                       <domain>|NEXT=…|COUNTER=…|HIGHEST=…|DECLARED=…|DECLARED_IN=…|COUNT=…
#                       where the undomained sequence is written `-` and COUNT
#                       is that domain's entries alone
#   DUPLICATES:         every id carried by more than one entry, one per line
#   NOTES:              what a reader has to know about these files
#
# A domain is in use when an entry, a declaration or a marker names it, so a
# domain a project has decided on and written a marker for is listed before its
# first requirement exists. The domain asked about is always listed, even when
# nothing names it yet — that is what makes NEXT=REQ-<domain>-001 readable as
# the answer it is.
#
# An entry is a line matching `- **REQ-###** — ...`, the format
# `.sdd/templates/requirements.md` fixes. Entries of every status —
# draft, active, superseded — hold their number, so all of them count. A
# declaration is a `### REQ-### — ...` heading of `.sdd/templates/new-requirements.md`.
#
# DUPLICATES: is the compilation's alone: two features declaring one number is a
# collision this script exists to prevent, not a state it reports.
#
# The candidate those three sources give is checked once more, against every id
# the specs mention outside their comments — a `Requires: REQ-014` of a tasks
# file, a design section naming one, a finding written against one. A number
# used by text nobody reserved is a number in use all the same, and the
# candidate moves past it. Five candidates are tried; past that the answer is
# that there is none, and the human repairs the files.
#
# Exit codes: 0 — printed; 1 — <project-root> is not a readable directory, or
#             <domain> is not a domain; 2 — _docs/requirements.md is missing or
#             unreadable; 3 — printed, and the domain asked about has no number:
#             five candidates in a row are written into the specs. NEXT is empty
#             and the ids are in TAKEN.

set -uo pipefail
[[ -r "$(dirname "$0")/lib/log.sh" ]] && . "$(dirname "$0")/lib/log.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -r "$SCRIPT_DIR/lib/format.sh" ]]; then
  printf 'ERROR=missing: %s/lib/format.sh\n' "$SCRIPT_DIR" >&2
  exit 1
fi
. "$SCRIPT_DIR/lib/format.sh"

ROOT_DIR="${1:-.}"
if [[ ! -d "$ROOT_DIR" ]]; then
  printf 'ERROR=not a directory: %s\n' "$ROOT_DIR" >&2
  exit 1
fi

# The domain is checked against the same shape the ids are read with: a name
# this does not accept is a name no entry could carry, and answering with a
# number under it would reserve nothing.
DOMAIN="${2:-}"
if [[ -n "$DOMAIN" ]] && ! printf '%s' "$DOMAIN" | grep -Eq '^[A-Z][A-Z0-9]*(-[A-Z][A-Z0-9]*)*$'; then
  printf 'ERROR=not a domain: %s — uppercase, starting with a letter, as in ACC\n' "$DOMAIN" >&2
  exit 1
fi

FILE="$ROOT_DIR/_docs/requirements.md"
if [[ ! -r "$FILE" ]]; then
  printf 'ERROR=missing or unreadable: %s\n' "$FILE" >&2
  exit 2
fi

NOTES=()
note() { NOTES+=("$1"); }
# Counted, not measured with ${#array[@]}: on bash 3.2 an empty array counts as
# unset under `set -u` and would abort the script.
COUNT=0

# ── Everything the three sources say, as one stream ───────────────
# One line per fact, tagged by where it came from: `E` an entry, `D` a
# declaration, `C` a marker. The domain travels in the record rather than in the
# name of a variable, because bash 3.2 has no associative array to hold one
# bucket per domain — the aggregation below is awk's.
STREAM=""
add() { STREAM="$STREAM$1"$'\n'; }

while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  add "E $(md_req_domain "$id")|$(md_req_number "$id")|"
  COUNT=$(( COUNT + 1 ))
done < <(md_req_ids "$FILE")

# Every feature is read, not just the one a caller is working on: the number
# this prints has to be free of all of them.
for d in "$ROOT_DIR"/_docs/*/; do
  [[ -d "$d" ]] || continue
  f="$d/new-requirements.md"
  [[ -r "$f" ]] || continue
  folder="${d%/}"; folder="${folder##*/}"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    add "D $(md_req_domain "$id")|$(md_req_number "$id")|$folder"
  done < <(md_req_declared "$f")
done

while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  add "C $(md_req_domain "$id")|$(md_req_number "$id")|"
done < <(md_counters "$FILE")

# The domain asked about is a domain in use whether or not anything names it:
# `next-req.sh . ACC` in a project with no ACC requirement answers
# REQ-ACC-001, and the record it answers from has to exist.
add "A $DOMAIN||"

# ── One record per domain ─────────────────────────────────────────
# awk keeps the buckets and does the comparisons as numbers; the shell below
# only formats. `-` stands for the undomained sequence throughout, in the
# records this prints and in the section the caller reads.
TABLE="$(printf '%s' "$STREAM" | awk '
  {
    tag = $1
    rest = substr($0, index($0, " ") + 1)
    n = split(rest, f, "|")
    dom = f[1]; num = f[2] + 0; who = f[3]
    key = (dom == "" ? "-" : dom)
    if (!(key in seen)) { seen[key] = 1; order[++k] = key }
    if (tag == "E") {
      count[key]++
      if (num > high[key]) high[key] = num
      id = key "|" num
      if (id in entry) dup[id] = 1
      entry[id] = 1
    } else if (tag == "D") {
      if (num > decl[key]) { decl[key] = num; declin[key] = who }
    } else if (tag == "C") {
      # A file carrying the same marker twice is the humans business; the first
      # one is what md_counter reads, so it is what this counts with.
      if (!(key in counter)) counter[key] = num
    }
  }
  END {
    for (i = 1; i <= k; i++) {
      key = order[i]
      next_num = 1; src = "none"
      if (key in counter && counter[key] > next_num) { next_num = counter[key]; src = "counter" }
      if (high[key] + 1 > next_num) { next_num = high[key] + 1; src = "compilation" }
      if (decl[key] + 1 > next_num) { next_num = decl[key] + 1; src = "specs" }
      printf "%s|%d|%s|%s|%s|%s|%s|%d\n", key, next_num, src,
        (key in counter ? counter[key] "" : ""),
        (high[key] ? high[key] "" : ""),
        (decl[key] ? decl[key] "" : ""),
        (key in decl ? declin[key] : ""),
        count[key] + 0
    }
    for (id in dup) print "DUP|" id
  }
')"

# The undomained sequence first, then the domains in alphabetical order: the
# order the stream happened to have is the order of the files, and a reader
# comparing two runs would be reading a diff of file order.
ROWS="$(printf '%s\n' "$TABLE" | grep -v '^DUP|' | sort -t'|' -k1,1 | awk -F'|' '$1 == "-"; ')"
ROWS="$ROWS
$(printf '%s\n' "$TABLE" | grep -v '^DUP|' | sort -t'|' -k1,1 | awk -F'|' '$1 != "-"')"

# ── The id formatting, once ───────────────────────────────────────
# The records carry bare numbers; every id a reader sees is built here, so the
# padding and the domain segment are written in one place.
key_of() { [[ -z "$1" ]] && printf '%s' "-" || printf '%s' "$1"; }
dom_of() { [[ "$1" == "-" ]] && printf '' || printf '%s' "$1"; }
id_of() { [[ -z "$2" ]] && return 0; md_req_id "$(dom_of "$1")" "$2"; }

# ── The number against what the specs already write ───────────────
# The three sources above are the places a number is *reserved*; they are not
# every place a number is *used*. A task requiring REQ-014, a design section
# naming it, a review finding against it — none of those is an entry or a
# declaration, and a number handed out over one of them collides with text a
# human is already reading as that requirement.
#
# So the candidate is checked against every id the specs mention, and moved past
# the ones already spoken for. Five candidates, no further: a sequence with five
# consecutive numbers mentioned and none of them reserved is not a sequence this
# script can walk out of, and guessing further would hand out a number over
# whatever comes next. What it does then is refuse — the human repairs the
# files, the script does not paper over them.
#
# The mentions are read with the comments cut out, which is what keeps the hint
# block of `.sdd/templates/requirements.md` — REQ-001, REQ-012, REQ-014,
# REQ-031 in prose nobody wrote — from reserving numbers in every project
# copied from it. A marker is a comment too, and a marker naming the candidate
# is the number being handed out rather than a use of it.
SCAN_LIMIT=5

mentioned_ids() {
  local f
  [[ -d "$ROOT_DIR/_docs" ]] || return 0
  while IFS= read -r f; do
    [[ -r "$f" ]] || continue
    md_uncomment "$f" | grep -oE "$MD_REQ_RE"
  done < <(find "$ROOT_DIR/_docs" -type f -name '*.md' 2>/dev/null | sort) | sort -u
}

MENTIONED="$(mentioned_ids)"

# One row at a time, because every domain's answer is read by somebody: NEXT is
# the queried domain's, and the DOMAINS: table is where a session that picked
# another domain reads its own.
TAKEN=""; SCAN_RC=0
SCANNED_ROWS=""
while IFS='|' read -r key n src counter highest decl declin cnt; do
  [[ -n "$key" ]] || continue
  dom="$(dom_of "$key")"
  tries=0; taken=""
  while (( tries < SCAN_LIMIT )); do
    id="$(md_req_id "$dom" "$n")"
    printf '%s\n' "$MENTIONED" | grep -qx "$id" || break
    taken="${taken:+$taken }$id"
    n=$(( n + 1 )); tries=$(( tries + 1 ))
  done
  if [[ -n "$taken" ]]; then
    if (( tries >= SCAN_LIMIT )); then
      # Nothing is handed out: an empty NEXT is a caller's answer to give up on,
      # where a number over text already written is one it would act on.
      n=""; src="taken"
      note "$SCAN_LIMIT number(s) in a row are already written into the specs: $taken. No number is issued for ${dom:-the undomained} requirements until the human repairs the files — the numbers are used by text nobody reserved."
    else
      src="scan"
      note "$taken $([[ "$taken" == *" "* ]] && printf 'are' || printf 'is') written into the specs without being reserved — no entry and no declaration carries $([[ "$taken" == *" "* ]] && printf 'them' || printf 'it'). The next ${dom:+$dom }number moves past $([[ "$taken" == *" "* ]] && printf 'them' || printf 'it') to $(md_req_id "$dom" "$n")."
    fi
    [[ "$key" == "$(key_of "$DOMAIN")" ]] && { TAKEN="$taken"; [[ -z "$n" ]] && SCAN_RC=3; }
  fi
  SCANNED_ROWS="$SCANNED_ROWS$key|$n|$src|$counter|$highest|$decl|$declin|$cnt"$'\n'
done <<EOF
$ROWS
EOF
ROWS="${SCANNED_ROWS%$'\n'}"

ROW=""
while IFS= read -r r; do
  [[ -n "$r" ]] || continue
  [[ "${r%%|*}" == "$(key_of "$DOMAIN")" ]] || continue
  ROW="$r"
done <<EOF
$ROWS
EOF

IFS='|' read -r _k NEXT_NUM SOURCE COUNTER_NUM HIGHEST_NUM DECLARED_NUM DECLARED_IN _c <<EOF
$ROW
EOF

DUPLICATES=()
N_DUPLICATES=0
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  d="${d#DUP|}"
  DUPLICATES+=("$(id_of "${d%%|*}" "${d##*|}")")
  N_DUPLICATES=$(( N_DUPLICATES + 1 ))
done < <(printf '%s\n' "$TABLE" | grep '^DUP|' | sort)
if [[ $N_DUPLICATES -gt 0 ]]; then
  note "$N_DUPLICATES number(s) are carried by more than one entry. The compilation is already inconsistent — report it before any number is issued."
fi

# ── What the markers say against what the entries carry ───────────
# Per domain, because a marker answers for its own sequence alone: an ACC marker
# standing behind the ACC entries is as wrong as an undomained one behind the
# undomained entries, and neither says anything about the other.
while IFS='|' read -r key _n _s counter highest _d _di _c; do
  [[ -n "$key" ]] || continue
  dom="$(dom_of "$key")"
  if [[ -z "$counter" ]]; then
    [[ -n "$highest" || "$key" == "$(key_of "$DOMAIN")" ]] || continue
    if [[ -z "$dom" ]]; then
      note "No '<!-- Next free number: REQ-### -->' marker in the file — the next number comes from the numbers already in use."
    else
      note "No '<!-- Next free number: REQ-$dom-### -->' marker in the file — the next $dom number comes from the numbers already in use."
    fi
  elif [[ -n "$highest" ]] && (( 10#$counter <= 10#$highest )); then
    note "The marker says $(id_of "$key" "$counter") but an entry already carries $(id_of "$key" "$highest") — the entries win, and the marker is behind. /sdd-actualize is what brings it back in line."
  fi
done <<EOF
$ROWS
EOF

printf 'DOMAIN=%s\n' "$DOMAIN"
printf 'NEXT=%s\n' "$(id_of "$(key_of "$DOMAIN")" "$NEXT_NUM")"
printf 'COUNTER=%s\n' "$(id_of "$(key_of "$DOMAIN")" "$COUNTER_NUM")"
printf 'HIGHEST=%s\n' "$(id_of "$(key_of "$DOMAIN")" "$HIGHEST_NUM")"
printf 'DECLARED=%s\n' "$(id_of "$(key_of "$DOMAIN")" "$DECLARED_NUM")"
printf 'DECLARED_IN=%s\n' "$DECLARED_IN"
printf 'SOURCE=%s\n' "$SOURCE"
printf 'TAKEN=%s\n' "$TAKEN"
printf 'COUNT=%s\n' "$COUNT"

printf '\nDOMAINS:\n'
while IFS='|' read -r key n src counter highest decl declin cnt; do
  [[ -n "$key" ]] || continue
  printf '%s|NEXT=%s|COUNTER=%s|HIGHEST=%s|DECLARED=%s|DECLARED_IN=%s|COUNT=%s\n' \
    "$key" "$(id_of "$key" "$n")" \
    "$(id_of "$key" "$counter")" "$(id_of "$key" "$highest")" \
    "$(id_of "$key" "$decl")" "$declin" "$cnt"
done <<EOF
$ROWS
EOF

printf '\nDUPLICATES:\n'
for d in ${DUPLICATES[@]+"${DUPLICATES[@]}"}; do printf '%s\n' "$d"; done

printf '\nNOTES:\n'
for n in ${NOTES[@]+"${NOTES[@]}"}; do printf '%s\n' "$n"; done

exit $SCAN_RC
