# shellcheck shell=bash
# The formats of the files under `_docs/`, read in one place.
#
# Sourced, never run:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   . "$SCRIPT_DIR/lib/format.sh"
#
# Every script that reads one of these formats reads it from here. Three
# scanners of the same HTML comment disagreed on which entries exist, and the
# disagreement did not fail — it handed out a REQ number twice and wrote an
# entry into the template's example block.
#
#   md_uncomment <file>            the file with comment text cut out
#   md_comment_open <file>         true when a comment is left open at EOF
#   md_field <file> <key>          the value of the field, as written — the
#                                  YAML property `key: value` of the leading
#                                  frontmatter, or the `> Key: value` line of a
#                                  file that carries no frontmatter
#   md_status <file>               the first word of the `status` field,
#                                  lowercased, or `absent`
#   md_field_line <file> <key>     the line number of that field's line — the
#                                  same line `md_field` reads the value off, so
#                                  a blank one is skipped by both
#   md_field_set <file> <key> <v>  the file with that line rewritten, to stdout,
#                                  in the form the line already had
#   md_req_is_id <text>            true when it is a requirement id
#   md_req_domain <REQ-…>          its domain, empty for an undomained id
#   md_req_number <REQ-…>          its number, as written
#   md_req_id <domain> <n>         the id those two make, zero-padded to three
#   md_req_ids <file>              the ids of the compilation entries, in file
#                                  order
#   md_req_lines <file> <REQ-…>    the line numbers of the entries carrying it
#   md_req_declared <file>         the ids of the requirements a feature's
#                                  new-requirements.md declares, in file order
#   md_counter <file> [<domain>]   REQ-… the `<!-- Next free number: -->`
#                                  marker of that domain says; empty when there
#                                  is none. The default domain is the empty one
#   md_counters <file>             every marker the file carries, in file order
#   md_counter_set <file> <REQ-…>  the file with that domain's marker moved, to
#                                  stdout — inserted under the last marker when
#                                  the domain has none yet
#   md_untouched <file> <tmpl>     true when the file holds nothing outside
#                                  what its template shipped with — the
#                                  scaffold, copied and never written into
#
# The two `_set` readers write nothing: they print, and the caller decides
# whether the file is replaced.
#
# Line numbers are the numbers of the file itself: the scanner cuts the comment
# out of its line and prints the line either way, so a reader and a writer see
# the same file. A file that is not there prints nothing and is not an error —
# every caller already knows whether it required the file.

# A requirement id, in one place: `REQ-###`, or `REQ-<DOMAIN>-###` when the
# project groups its requirements — `REQ-ACC-003`. A domain segment is
# uppercase and starts with a letter, which is what keeps the number itself from
# reading as one, and several segments may be chained (`REQ-ACC-SUB-003`).
#
# The regex is leftmost-longest, so `REQ-ACC-003` matches whole rather than
# stopping at a `REQ-` with no number behind it.
MD_REQ_RE='REQ-([A-Z][A-Z0-9]*-)*[0-9]+'

# The same id for awk, with the two readers built on it: `md_id(s)` is the first
# id on a line, empty when there is none. Prepend it to a program that needs it:
#   awk "$MD_AWK_ID"'  { print md_id($0) }'
MD_AWK_ID='
function md_id(s,   r) {
  if (!match(s, /REQ-([A-Z][A-Z0-9]*-)*[0-9]+/)) return ""
  return substr(s, RSTART, RLENGTH)
}
'

# An entry of requirements.md, the format its template fixes. It is
# an awk function rather than a variable: a regex handed to `awk -v` loses its
# backslashes to escape processing, and the pattern would stop matching.
# Prepend it to a program that needs it:  awk "$MD_AWK_ENTRY"'  md_is_entry($0) { … }'
MD_AWK_ENTRY="$MD_AWK_ID"'
function md_is_entry(s) { return s ~ /^-[[:space:]]*\*\*REQ-([A-Z][A-Z0-9]*-)*[0-9]+\*\*/ }
'

# A requirement of a feature's new-requirements.md, the format its template fixes:
# `### REQ-### — <short title>`. The heading level is not pinned, because a
# level is a document's business and the number is what this reads. Kept as an
# awk function for the same reason as the one above.
MD_AWK_DECL="$MD_AWK_ID"'
function md_is_req_heading(s) { return s ~ /^#+[[:space:]]*REQ-([A-Z][A-Z0-9]*-)*[0-9]+/ }
'

# The three parts of an id, for the shell. The domain of `REQ-003` is empty:
# undomained ids are a sequence of their own, and every reader here treats the
# empty domain as one more domain rather than as a special case.
#
#   md_req_domain REQ-ACC-003   → ACC
#   md_req_number REQ-ACC-003   → 003
#   md_req_id ACC 3             → REQ-ACC-003
#
# An argument that is not an id at all comes back empty from the first two, and
# the caller that cares checks with `md_req_is_id`.
md_req_is_id() {
  printf '%s' "${1:-}" | grep -Eq "^$MD_REQ_RE\$"
}

md_req_domain() {
  local rest="${1#REQ-}"
  md_req_is_id "${1:-}" || return 0
  case "$rest" in
    *-*) printf '%s' "${rest%-*}" ;;
    *)   ;;
  esac
}

md_req_number() {
  md_req_is_id "${1:-}" || return 0
  printf '%s' "${1##*-}"
}

# Three digits is the width the templates write and every golden carries; a
# number past 999 keeps its own width rather than being truncated into a
# collision.
md_req_id() {
  local domain="${1:-}" n="${2:-0}"
  if [[ -n "$domain" ]]; then
    printf 'REQ-%s-%03d' "$domain" "$(( 10#$n ))"
  else
    printf 'REQ-%03d' "$(( 10#$n ))"
  fi
}

# The entry formats of every template live inside HTML comments, example task
# lines and example REQ entries included. Only what is outside the comments is
# real.
#
# The comment is cut out of the line, never the line out of the file: a real
# task carrying a trailing `<!-- note -->` stays a task, where dropping the
# whole line would take it out of the count and out of the stage without a word.
# One scanner serves both uses — `probe=1` asks it whether a comment was left
# open at EOF instead of printing, because a stray `<!--` makes everything after
# it invisible to every parser above.
MD_AWK_UNCOMMENT='
{
  rest = $0; out = ""
  while (rest != "") {
    if (incomment) {
      p = index(rest, "-->")
      if (p == 0) break
      rest = substr(rest, p + 3); incomment = 0
    } else {
      p = index(rest, "<!--")
      if (p == 0) { out = out rest; break }
      out = out substr(rest, 1, p - 1); rest = substr(rest, p + 4); incomment = 1
    }
  }
  if (!probe) print out
}
END { if (probe && incomment) print "open" }
'

md_uncomment() {
  [[ -f "$1" ]] || return 0
  awk -v probe=0 "$MD_AWK_UNCOMMENT" "$1"
}

md_comment_open() {
  [[ -f "$1" ]] || return 1
  [[ -n "$(awk -v probe=1 "$MD_AWK_UNCOMMENT" "$1")" ]]
}

# ── The fields of a document ──────────────────────────────────────
#
# A field is written in one of two forms, and every reader below takes both:
#
#   ---                  the leading YAML frontmatter, which is where the
#   status: draft        templates put it — Obsidian shows it as a property,
#   ---                  and a reader outside Obsidian sees plain YAML
#
#   > Status: draft      the blockquote line the templates used before
#                        frontmatter, still read so that a document written by
#                        an earlier version of the engine keeps its status
#
# Frontmatter wins where a file carries both, and it wins by file order alone:
# it is at the top, and every reader stops at its first match.
#
# `fm` is 1 while the scanner is inside the leading block. Only a `---` on the
# very first line opens one — a `---` further down is a horizontal rule, and a
# file that opens with a rule instead of a property block is not a thing the
# templates write.
MD_AWK_FIELD='
function md_unquote(v,   f, l) {
  if (length(v) >= 2) {
    f = substr(v, 1, 1); l = substr(v, length(v), 1)
    if ((f == "\"" && l == "\"") || (f == "\047" && l == "\047"))
      return substr(v, 2, length(v) - 2)
  }
  return v
}
function md_value(s,   v) {
  v = s
  sub(/^[^:]*:[[:space:]]*/, "", v)
  sub(/[[:space:]]+$/, "", v)
  return md_unquote(v)
}
NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
fm && /^(---|\.\.\.)[[:space:]]*$/ { fm = 0; next }
'

# The value of the field, whole and as written — where `md_status` takes the
# first word and lowercases it, this keeps `APPROVED WITH MINOR ISSUES` in one
# piece. A quoted YAML value comes back without its quotes: a value carrying a
# colon has to be quoted, and the quotes are the format's, not the value's.
md_field() {
  md_uncomment "$1" | awk -v k="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" "$MD_AWK_FIELD"'
    fm && tolower($0) ~ "^" k "[[:space:]]*:" {
      v = md_value($0)
      if (v != "") { print v; exit }
    }
    !fm && tolower($0) ~ "^>[[:space:]]*" k "[[:space:]]*:" {
      v = md_value($0)
      if (v != "") { print v; exit }
    }
  '
}

# The `status` field of a document, as the first word of its value.
# `absent` when the document carries none.
md_status() {
  local v w
  [[ -f "$1" ]] || { printf 'absent'; return 0; }
  v="$(md_field "$1" status)"
  w="$(printf '%s' "$v" | awk '
    {
      split($0, a, /[[:space:]]+/)
      w = a[1]
      gsub(/^[^A-Za-z]+|[^A-Za-z]+$/, "", w)
      if (w != "") { print tolower(w); exit }
    }
  ')"
  [[ -z "$w" ]] && w="absent"
  printf '%s' "$w"
}

# Where the line is, for whoever rewrites it. Empty when there is none.
#
# A line whose value is empty is skipped, exactly as `md_field` skips it: the
# two are a reader and a writer of the same line, and a file carrying the key
# twice with the first one blank used to send them to different lines. The write
# then landed on the line nothing reads, and the next read reported the old
# value as if nothing had been written. A file whose only such line is blank now
# has no line number at all, so `md_field_set` fails and the caller says so —
# the value is not inserted where the reader would not have found it.
md_field_line() {
  md_uncomment "$1" | awk -v k="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" "$MD_AWK_FIELD"'
    fm && tolower($0) ~ "^" k "[[:space:]]*:" {
      if (md_value($0) != "") { print NR; exit }
    }
    !fm && tolower($0) ~ "^>[[:space:]]*" k "[[:space:]]*:" {
      if (md_value($0) != "") { print NR; exit }
    }
  '
}

# Only the line the key names changes, and only the first one: the value is
# rewritten whole, everything else in the file stays byte for byte.
#
# The key and the value reach awk through the environment rather than through
# `-v`, which runs its argument through escape processing before the program
# sees it: a `\n` in a value arrives as a real newline and splits the line in
# two, and the second half is no longer a field line at all. `> Verdict:` is
# free text out of a review report, so this is a value the engine does not
# control.
md_field_set() {
  local n
  n="$(md_field_line "$1" "$2")"
  [[ -n "$n" ]] || return 1
  MD_KEY="$2" MD_VAL="$3" awk -v n="$n" '
    NR == n {
      # A frontmatter property keeps the key exactly as the document wrote it;
      # the blockquote form is rewritten whole, as it always was.
      if ($0 ~ /^>/) {
        printf "> %s: %s\n", ENVIRON["MD_KEY"], ENVIRON["MD_VAL"]
      } else {
        head = $0
        sub(/:.*$/, ":", head)
        printf "%s %s\n", head, ENVIRON["MD_VAL"]
      }
      next
    }
    { print }
  ' "$1"
}

md_req_ids() {
  md_uncomment "$1" | awk "$MD_AWK_ENTRY"'
    md_is_entry($0) { print md_id($0) }
  '
}

md_req_lines() {
  md_uncomment "$1" | awk -v want="$2" "$MD_AWK_ENTRY"'
    md_is_entry($0) { if (md_id($0) == want) print NR }
  '
}

# What a feature declares is what holds the number: the entry in
# requirements.md is written when the feature is actualized, and
# until then this heading is the only record that the number is in use.
md_req_declared() {
  md_uncomment "$1" | awk "$MD_AWK_DECL"'
    md_is_req_heading($0) { print md_id($0) }
  '
}

# The counter marker is read out of the raw file on purpose: it lives inside an
# HTML comment, which is what keeps it out of the rendered document.
md_counter() {
  local domain="${2:-}" id
  [[ -f "$1" ]] || return 0
  while IFS= read -r id; do
    [[ "$(md_req_domain "$id")" == "$domain" ]] || continue
    printf '%s\n' "$id"
    return 0
  done < <(md_counters "$1")
}

# Every marker the file carries, in file order — one per domain, and the
# undomained one among them. A project that groups its requirements holds one
# marker per group: a domain's numbers are its own sequence, and a single
# counter over all of them would hand out `REQ-ACC-014` into a file whose
# highest ACC entry is 003.
md_counters() {
  [[ -f "$1" ]] || return 0
  awk "$MD_AWK_ID"'
    match($0, /Next free number:[[:space:]]*REQ-([A-Z][A-Z0-9]*-)*[0-9]+/) {
      print md_id(substr($0, RSTART, RLENGTH))
    }
  ' "$1"
}

# The value comes through the environment for the reason `md_field_set` gives,
# and the line is rebuilt around the match rather than handed to `sub()`: in a
# replacement `&` stands for the whole matched text, and awks disagree on what a
# backslash does there. `match` gives the span, `substr` puts the value in
# untouched, and neither character means anything on the way.
md_counter_set() {
  local domain last
  [[ -f "$1" ]] || return 1
  domain="$(md_req_domain "${2:-}")"
  # Which marker is rewritten follows from the value: `REQ-ACC-004` moves the
  # ACC marker and leaves every other one where it stands. A domain the file
  # carries no marker for gets one of its own, written under the last marker
  # there is — a file with no marker at all still fails, because a counter
  # inserted where the format has no place for it is a counter nobody reads.
  last="$(awk '/Next free number:[[:space:]]*REQ-/ { n = NR } END { if (n) print n }' "$1")"
  [[ -n "$last" ]] || return 1
  MD_VAL="$2" MD_DOMAIN="$domain" awk -v last="$last" "$MD_AWK_ID"'
    BEGIN { val = ENVIRON["MD_VAL"]; domain = ENVIRON["MD_DOMAIN"] }
    function md_domain_of(id,   rest) {
      rest = substr(id, 5)
      if (rest ~ /^([A-Z][A-Z0-9]*-)+[0-9]+$/) { sub(/-[0-9]+$/, "", rest); return rest }
      return ""
    }
    !seen && match($0, /Next free number:[[:space:]]*REQ-([A-Z][A-Z0-9]*-)*[0-9]+/) {
      # The span is kept before md_id() is called: its own match() overwrites
      # RSTART and RLENGTH, and the line would be rebuilt around the wrong one.
      st = RSTART; len = RLENGTH
      if (md_domain_of(md_id(substr($0, st, len))) == domain) {
        $0 = substr($0, 1, st - 1) "Next free number: " val substr($0, st + len)
        seen = 1
      }
    }
    { print }
    NR == last && !seen { printf "<!-- Next free number: %s -->\n", val; seen = 1 }
  ' "$1"
}

# The skeleton of a file: what it holds outside its HTML comments, with the
# trailing spaces and the blank lines gone and the H1 title dropped.
#
# The comments are cut rather than compared, because whether the hint comments
# are left standing is the writer's business — `project-baseline.md` says a
# standing hint is the scaffold, and `code-style.md`'s `derived: confirm or
# correct` markers have to survive being filled in. What makes a file written is
# the text outside them.
#
# The title goes because `scaffold feature` writes the feature name into it, and
# a file whose only edit is its own name has not been filled in.
#
# The frontmatter goes for the same reason and one more: `scaffold` writes the
# feature name into its properties too, and the `status` property is rewritten
# by `spec-edit.sh status` on a file nobody has otherwise touched. Comparing it
# would make a fresh scaffold read as written, which is the one thing this
# function exists to tell apart.
MD_AWK_SKELETON='
NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
fm && /^(---|\.\.\.)[[:space:]]*$/ { fm = 0; next }
fm { next }
!seen && /^#[[:space:]]/ { seen = 1; next }
{ sub(/[[:space:]]+$/, ""); if ($0 != "") print }
'

# True when the file is its template and nothing more: the copy `scaffold` made
# and nobody has written into.
#
# It is a fact about content, where `-s` and `[^[:space:]]` are facts about a
# file existing — a fresh template passes both of those, which is what lets a
# setup interrupted after the copy read as a finished one ever after.
#
# A file that is not there is not untouched, it is absent, and every caller
# already knows the difference; same for a template, which every caller checks
# before it gets here.
md_untouched() {
  [[ -f "$1" && -f "$2" ]] || return 1
  [[ "$(md_uncomment "$1" | awk "$MD_AWK_SKELETON")" \
     == "$(md_uncomment "$2" | awk "$MD_AWK_SKELETON")" ]]
}
