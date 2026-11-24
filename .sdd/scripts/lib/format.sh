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
#   md_field_put <file> <key> <v> <anchor>
#                                  the same, inserting the field under the
#                                  <anchor> field's line when it is not there
#   md_req_is_id <text>           true when it is a requirement id
#   md_req_domain <REQ-…>          its domain, empty for an undomained id
#   md_req_number <REQ-…>          its number, as written
#   md_req_id <domain> <n>         the id those two make, zero-padded to three
#   md_req_ids <file>              the ids of the compilation entries, in file
#                                  order
#   md_req_lines <file> <REQ-…>    the line numbers of the entries carrying it
#   md_req_declared <file>         the ids of the requirements a feature's
#                                  new-requirements.md declares, in file order
#   md_req_relations <file>       one record per requirement it declares:
#                                  `<REQ-…>|new|`, `<REQ-…>|refines|<REQ-…>`
#                                  or `<REQ-…>|supersedes|<REQ-…>`; one
#                                  with a second such line `<REQ-…>|many|<REQ-…>`
#   md_unpromoted <compilation> <new-requirements> <feature>
#                                  one record per requirement the feature
#                                  declares that the compilation does not hold
#                                  as declared: `<REQ>|<reason>|<detail>`
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
#   md_findings <file>             one record per finding of a review.md, in
#                                  file order: `F-##|severity|category|file|line`,
#                                  `-` for a part the finding does not give
#   md_features <specs>            the feature folders under it, one per line
#   md_feature_folder <specs> <name>
#                                  the folder under <specs> the name is on disk:
#                                  itself, else the one differing in case alone,
#                                  else the name as given
#   md_start_commit <file>         the commit of a feature's starting point,
#   md_start_dirty <file>          and the paths that were dirty at it — the
#                                  file is `_docs/<Feature>/$MD_START_FILE`
#
# The `_set` and `_put` readers write nothing: they print, and the caller decides
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
# A bash match rather than grep: this runs once per id, and starting a program
# per call was most of what reading a project cost.
MD_REQ_RE_WHOLE="^$MD_REQ_RE\$"
md_req_is_id() {
  [[ "${1:-}" =~ $MD_REQ_RE_WHOLE ]]
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
#
# The scanner is a function, so a reader runs it as the first rule of its own
# program — one awk per read, where `md_uncomment | awk` started two. The state
# is reset per file, so one program can read several.
MD_AWK_STRIP='
function md_strip(s,   rest, out, p) {
  rest = s; out = ""
  while (rest != "") {
    if (md_incomment) {
      p = index(rest, "-->")
      if (p == 0) break
      rest = substr(rest, p + 3); md_incomment = 0
    } else {
      p = index(rest, "<!--")
      if (p == 0) { out = out rest; break }
      out = out substr(rest, 1, p - 1); rest = substr(rest, p + 4); md_incomment = 1
    }
  }
  return out
}
FNR == 1 { md_incomment = 0 }
{ $0 = md_strip($0) }
'

md_uncomment() {
  [[ -f "$1" ]] || return 0
  awk "$MD_AWK_STRIP"'{ print }' "$1"
}

# `md_uncomment <file> | awk [opts] <program>` in one program: the program sees
# every line with its comment text cut out, and the line numbers of the file.
# Usage: md_awk <file> <program> [awk options ...]. A missing file prints
# nothing, as md_uncomment does.
md_awk() {
  local file="$1" prog="$2"
  shift 2
  [[ -f "$file" ]] || return 0
  awk "$@" "$MD_AWK_STRIP$prog" "$file"
}

md_comment_open() {
  [[ -f "$1" ]] || return 1
  [[ -n "$(awk "$MD_AWK_STRIP"'END { if (md_incomment) print "open" }' "$1")" ]]
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
BEGIN { k = tolower(k) }
NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
fm && /^(---|\.\.\.)[[:space:]]*$/ { fm = 0; next }
'

# The value of the field, whole and as written — where `md_status` takes the
# first word and lowercases it, this keeps `APPROVED WITH MINOR ISSUES` in one
# piece. A quoted YAML value comes back without its quotes: a value carrying a
# colon has to be quoted, and the quotes are the format's, not the value's.
md_field() {
  md_awk "$1" "$MD_AWK_FIELD"'
    fm && tolower($0) ~ "^" k "[[:space:]]*:" {
      v = md_value($0)
      if (v != "") { print v; exit }
    }
    !fm && tolower($0) ~ "^>[[:space:]]*" k "[[:space:]]*:" {
      v = md_value($0)
      if (v != "") { print v; exit }
    }
  ' -v k="$2"
}

# The `status` field of a document, as the first word of its value.
# `absent` when the document carries none.
md_status() {
  local w
  [[ -f "$1" ]] || { printf 'absent'; return 0; }
  # The field and its first word in one program: md_field's rules, then the
  # word taken off the value it would have printed.
  w="$(md_awk "$1" "$MD_AWK_FIELD"'
    function first_word(v,   a, w) {
      split(v, a, /[[:space:]]+/)
      w = a[1]
      gsub(/^[^A-Za-z]+|[^A-Za-z]+$/, "", w)
      return tolower(w)
    }
    fm && tolower($0) ~ "^" k "[[:space:]]*:" {
      v = md_value($0)
      if (v != "") { print first_word(v); exit }
    }
    !fm && tolower($0) ~ "^>[[:space:]]*" k "[[:space:]]*:" {
      v = md_value($0)
      if (v != "") { print first_word(v); exit }
    }
  ' -v k=status)"
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
  md_awk "$1" "$MD_AWK_FIELD"'
    fm && tolower($0) ~ "^" k "[[:space:]]*:" {
      if (md_value($0) != "") { print NR; exit }
    }
    !fm && tolower($0) ~ "^>[[:space:]]*" k "[[:space:]]*:" {
      if (md_value($0) != "") { print NR; exit }
    }
  ' -v k="$2"
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

# A field the document may not carry yet: rewritten where it is, otherwise
# inserted as the line after the <anchor> field, in the form that line has — a
# frontmatter property `key: value`, or `> Key: value` in a document written
# before frontmatter. Fails, printing nothing, when there is no anchor line to
# put it under: a field is never added where the format has no field block.
md_field_put() {
  local n
  if [[ -n "$(md_field_line "$1" "$2")" ]]; then
    md_field_set "$1" "$2" "$3"
    return
  fi
  n="$(md_field_line "$1" "$4")"
  [[ -n "$n" ]] || return 1
  MD_KEY="$2" MD_VAL="$3" awk -v n="$n" '
    { print }
    NR == n {
      k = tolower(ENVIRON["MD_KEY"])
      if ($0 ~ /^>/) printf "> %s%s: %s\n", toupper(substr(k, 1, 1)), substr(k, 2), ENVIRON["MD_VAL"]
      else           printf "%s: %s\n", k, ENVIRON["MD_VAL"]
    }
  ' "$1"
}

md_req_ids() {
  md_awk "$1" "$MD_AWK_ENTRY"'
    md_is_entry($0) { print md_id($0) }
  '
}

md_req_lines() {
  md_awk "$1" "$MD_AWK_ENTRY"'
    md_is_entry($0) { if (md_id($0) == want) print NR }
  ' -v want="$2"
}

# Why <name> cannot be a feature folder under _docs/, or nothing when it can.
# A feature name is a path segment and nothing more: a separator, `.`/`..` or a
# leading dot would put the files a command writes somewhere other than
# _docs/<name>/. A trailing slash is refused rather than trimmed — the name is
# used on disk exactly as given. `architecture` is the baseline's folder, in any
# case: on a case-insensitive filesystem `Architecture` opens the same one.
md_name_problem() {
  local bad lower
  lower="$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z')"
  [[ "$lower" == "architecture" ]] && { printf "it is the architecture baseline's folder"; return 0; }
  case "$1" in
    "")       printf 'it is empty'; return 0 ;;
    */*|*\\*) printf 'it carries a path separator'; return 0 ;;
    .|..)     printf "it is '%s'" "$1"; return 0 ;;
    .*)       printf 'it starts with a dot'; return 0 ;;
  esac
  bad="$(printf '%s' "$1" | LC_ALL=C tr -d 'A-Za-z0-9._-')"
  [[ -z "$bad" ]] || printf "it holds '%s'" "$bad"
}

# The feature folders under <specs>, in the shell's sorted order: a glob rather
# than find | sed | sort — dot-folders and links left out, no program started,
# and `architecture/`, the baseline's sections, which no command takes as a
# feature.
md_features() {
  local d
  for d in "$1"/*/; do
    d="${d%/}"
    [[ -d "$d" && ! -L "$d" ]] || continue
    [[ "${d##*/}" == "architecture" ]] && continue
    printf '%s\n' "${d##*/}"
  done
  return 0
}

# The folder a feature name is on disk under <specs>. On a case-insensitive
# filesystem `_docs/cart` opens `_docs/Cart`, and a step that only compared the
# argument with itself would never notice — so the name is compared against the
# folders actually there: the same name first, then one differing in case alone.
# A name no folder matches comes back as given. Dot-folders and links are not
# features. Read by the shell, no program started.
md_feature_folder() {
  local name found=""
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ "$name" == "$2" ]] && { printf '%s' "$name"; return 0; }
    if [[ -z "$found" ]]; then
      shopt -s nocasematch
      [[ "$name" == "$2" ]] && found="$name"
      shopt -u nocasematch
    fi
  done <<< "$(md_features "$1")"
  printf '%s' "${found:-$2}"
}

# Where a feature's code starts: `_docs/<Feature>/.implement-start`, written
# once by `spec-edit.sh start` before /sdd-implement spawns its first role and
# never rewritten, read by review-set.sh. Nothing is written into git for it —
# the commands that took it only read. The format:
#   COMMIT=<the commit HEAD was on>
#   DATE=<YYYY-MM-DD>
#
#   DIRTY:
#   <a path the working tree held changed or untracked at that moment>
MD_START_FILE=".implement-start"
md_start_commit() {
  local line
  [[ -f "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == COMMIT=* ]] && { printf '%s' "${line#COMMIT=}"; return 0; }
  done < "$1"
  return 0
}
md_start_dirty() {
  local line inside=0
  [[ -f "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "DIRTY:" ]]; then inside=1; continue; fi
    [[ $inside -eq 1 && -n "$line" ]] && printf '%s\n' "$line"
  done < "$1"
  return 0
}

# The feature an entry belongs to — the first name inside its `*(Source: …)*`,
# as written. Empty when the compilation holds no entry with that id, or the
# entry names no source. Whose entry it is decides whether a feature promoting
# that number writes its own entry or someone else's.
md_req_source() {
  md_awk "$1" "$MD_AWK_ENTRY"'
    md_is_entry($0) && md_id($0) == want {
      p = index($0, "(Source:"); if (p == 0) exit
      rest = substr($0, p + 8); q = index(rest, ")"); if (q > 0) rest = substr(rest, 1, q - 1)
      split(rest, part, ","); src = part[1]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", src)
      print src; exit
    }
  ' -v want="$2"
}

# Whether a feature was promoted as it declares, in one place: the stage
# (feature-state.sh) and the postcondition of /sdd-actualize (gate.sh --verify)
# read it here, so the two cannot disagree about the same compilation. A record
# per way a declared requirement is not there as declared — a replacement can
# owe two:
#   <REQ>|missing|             new, supersedes — no entry carries the number
#   <REQ>|foreign|<source>     new, supersedes — the entry is another feature's
#   <REQ>|no-target|<target>   supersedes — the replaced requirement has no entry
#   <REQ>|unmarked|<target>    supersedes — its entry does not say
#                              `superseded by <REQ>`
#   <REQ>|unrefined|<target>   refines — its entry is neither this feature's nor
#                              carries `refined by <feature>`
# The first entry of a number is the one read, as everywhere else; sources are
# compared as folders are, case aside. Nothing printed is a feature promoted.
md_unpromoted() {
  local decl
  decl="$(md_req_relations "$2")"
  [[ -n "$decl" ]] || return 0
  if [[ ! -f "$1" ]]; then
    printf '%s\n' "$decl" | awk -F'|' 'NF && $2 != "refines" { print $1 "|missing|" } NF && $2 == "refines" { print $1 "|unrefined|" $3 }'
    return 0
  fi
  SDD_DECL="$decl" SDD_FEATURE="$3" md_awk "$1" "$MD_AWK_ENTRY"'
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    BEGIN { me = tolower(ENVIRON["SDD_FEATURE"]) }
    md_is_entry($0) {
      id = md_id($0)
      if (id in seen) next
      seen[id] = 1; src[id] = ""; mine[id] = 0; sup[id] = ""
      p = index($0, "(Source:")
      if (p == 0) next
      rest = substr($0, p + 8); q = index(rest, ")"); if (q > 0) rest = substr(rest, 1, q - 1)
      n = split(rest, part, ",")
      src[id] = trim(part[1])
      for (i = 2; i <= n; i++) {
        f = trim(part[i])
        if (f ~ /^refined by /) { if (tolower(trim(substr(f, 12))) == me) mine[id] = 1 }
        else if (f ~ /^superseded by /) sup[id] = md_id(f)
      }
    }
    END {
      n = split(ENVIRON["SDD_DECL"], rec, "\n")
      for (i = 1; i <= n; i++) {
        if (split(rec[i], r, "|") < 2) continue
        d = r[1]; rel = r[2]; t = r[3]
        if (rel == "refines") {
          if (t == "" || !(t in seen) || (tolower(src[t]) != me && !mine[t])) print d "|unrefined|" t
          continue
        }
        # A replacement owes two things, its own entry and the mark on the
        # one it replaced, and each missing one is a record of its own.
        if (!(d in seen))                print d "|missing|"
        else if (tolower(src[d]) != me)  print d "|foreign|" src[d]
        if (rel != "supersedes")         continue
        if (t == "" || !(t in seen))     print d "|no-target|" t
        else if (sup[t] != d)            print d "|unmarked|" t
      }
    }
  '
}

# What a feature declares is what holds the number: the entry in
# requirements.md is written when the feature is actualized, and
# until then this heading is the only record that the number is in use.
md_req_declared() {
  md_awk "$1" "$MD_AWK_DECL"'
    md_is_req_heading($0) { print md_id($0) }
  '
}

# What each declared requirement is to the compilation, which is what
# /sdd-actualize acts on: an entry of its own, a rewording of an entry already
# there, or the replacement of one. The relation is a line under the heading,
# the format `.sdd/templates/new-requirements.md` fixes:
#
#   ### REQ-031 — Guest checkout
#   - **Supersedes:** [REQ-012](../requirements.md#^req-012)
#
# and a requirement carrying neither line is `new`. The target is the first id
# after the key, so the link text and a bare `REQ-012` read the same. A key with
# no id behind it comes back with an empty target — the caller says so rather
# than this reader guessing which of the two the line meant to be. A requirement
# relates to one entry at most: a second relation line under one heading comes
# back as `many`, the first target kept, so the caller stops on it rather than
# promote one relation and drop the other unseen.
#
# A requirement moved under `## Out of Scope` is not among them: its heading
# still holds the number, which is `md_req_declared`'s business, and nothing of
# it is promoted.
md_req_relations() {
  md_awk "$1" "$MD_AWK_DECL"'
    function flush() { if (id != "") print id "|" rel "|" target; id = "" }
    /^##[[:space:]]/ { oos = (tolower($0) ~ /^##[[:space:]]+out of scope/) }
    md_is_req_heading($0) {
      flush()
      if (!oos) { id = md_id($0); rel = "new"; target = "" }
      next
    }
    /^#+[[:space:]]/ { flush(); next }
    id != "" && match($0, /\*\*(Refines|Supersedes):\*\*/) {
      if (rel != "new") { rel = "many"; next }
      key = substr($0, RSTART, RLENGTH); rest = substr($0, RSTART + RLENGTH)
      rel = (key ~ /Refines/) ? "refines" : "supersedes"
      target = md_id(rest)
    }
    END { flush() }
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
  [[ "$(md_awk "$1" "$MD_AWK_SKELETON")" == "$(md_awk "$2" "$MD_AWK_SKELETON")" ]]
}

# The hint of each `## ` section: the comment right under the heading, joined
# into one line. Prints `<heading>|<hint>` per section that has one, in file
# order. Read off a template, where the hint is what a section asks for — the
# wording a command phrases its question from, without opening the file.
md_hints() {
  [[ -f "$1" ]] || return 0
  awk '
    /^## / { h = substr($0, 4); sub(/[[:space:]]+$/, "", h); under = 1; next }
    under && !c && /^[[:space:]]*<!--/ { c = 1; t = ""; sub(/^[[:space:]]*<!--/, "") }
    c {
      line = $0; end = 0
      if (index(line, "-->")) { sub(/-->.*/, "", line); end = 1 }
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line != "") t = (t == "" ? line : t " " line)
      if (end) { print h "|" t; c = 0; under = 0 }
      next
    }
    under && NF { under = 0 }
  ' "$1"
}

# The lines of `## Open Questions` that carry an answer — `**Answer:**` on the
# line is the whole discriminator, as the spec-modes protocol fixes it. Prints
# their count, 0 for none or for a file that is not there. The template's
# example lives in a comment and is cut out first.
md_answered() {
  local n
  n="$(md_awk "$1" '
    /^## / { inside = ($0 ~ /^## Open Questions[[:space:]]*$/); next }
    inside && index($0, "**Answer:**") { n++ }
    END { print n + 0 }')"
  printf '%s\n' "${n:-0}"
}

# The findings of a code review, the format `.sdd/templates/review.md` fixes:
#
#   ### F-01 — Critical — Security
#
#   > [!danger] Where: `src/main/java/.../CartController.java:42`
#   > **What:** …
#
# and the list form a report written before the callouts carries,
# `- **Where:** \`path:42\``. The heading gives the number, the severity and the
# category; the first `Where:` under it gives the place — the first backticked
# span on that line when there is one, the rest of the line when there is not.
# The line is the number after the last colon; a range (`:42-48`) is read as
# its first line, which is where a marker above it belongs, and a place with no
# number has none. A part the finding does not give comes back as `-`, never as
# a guess: which line a finding about a whole file is about is not this
# reader's to say.
#
# The template's example lives in a comment, and the comment is cut out first:
# a fresh report has no findings.
md_findings() {
  md_awk "$1" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function orno(s) { s = trim(s); return s == "" ? "-" : s }
    function flush() {
      if (id != "") print id "|" orno(sev) "|" orno(cat) "|" orno(file) "|" orno(line)
      id = ""
    }
    /^#+[[:space:]]/ {
      flush()
      if (match($0, /^#+[[:space:]]+F-[0-9]+/)) {
        head = substr($0, RSTART, RLENGTH); sub(/^#+[[:space:]]+/, "", head)
        id = head; sev = ""; cat = ""; file = ""; line = ""; placed = 0
        rest = substr($0, RSTART + RLENGTH)
        gsub(/—|–/, "|", rest); gsub(/[[:space:]]-[[:space:]]/, "|", rest)
        n = split(rest, part, "|"); k = 0
        for (i = 1; i <= n; i++) {
          p = trim(part[i]); if (p == "") continue
          k++; if (k == 1) sev = p; else if (k == 2) cat = p
        }
      }
      next
    }
    id != "" && !placed && match($0, /Where:/) {
      placed = 1
      where = substr($0, RSTART + RLENGTH); gsub(/\*/, "", where)
      if (match(where, /`[^`]+`/)) where = substr(where, RSTART + 1, RLENGTH - 2)
      where = trim(where)
      if (match(where, /:[0-9]+([-–][0-9]+)?$/)) {
        line = substr(where, RSTART + 1, RLENGTH - 1); sub(/[-–].*$/, "", line)
        where = substr(where, 1, RSTART - 1)
      }
      file = where
    }
    END { flush() }
  '
}
