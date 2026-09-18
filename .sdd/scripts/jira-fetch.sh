#!/usr/bin/env bash
# The import of a Jira issue into a feature's raw.md: the one place that knows
# how to reach the instance, how its wiki markup becomes Markdown, and where an
# attachment goes.
#
# The line between this script and the model: the script owns the request, the
# conversion and the file it writes; nothing about the issue's meaning is
# decided here. /sdd-next-story calls it after gate.sh has agreed the feature
# may be created.
#
# Usage: jira-fetch.sh <issue-url-or-key> --out <path> [--root <dir>] [--from-file <json>]
#
# Prints KEY=value lines, then ATTACHMENTS: and NOTES: blocks. Exit codes:
# 0 — the file was written; 1 — the environment is wrong (no curl, no jq, no
# library); 2 — the run cannot proceed (no token, an HTTP error, an answer that
# will not parse) and nothing was written.

set -uo pipefail
[[ -r "$(dirname "$0")/lib/log.sh" ]] && . "$(dirname "$0")/lib/log.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -r "$SCRIPT_DIR/lib/format.sh" ]]; then
  printf 'ERROR=missing: %s/lib/format.sh\n' "$SCRIPT_DIR" >&2
  exit 1
fi
# The file this script writes lives under _docs/, and how a file there is read
# is knowledge that belongs in one place: `md_uncomment` is what finds a
# heading in .sdd/templates/raw.md and in the issue's own text.
. "$SCRIPT_DIR/lib/format.sh"

# ── Arguments ─────────────────────────────────────────────────────
ROOT_DIR="."
OUT=""
FROM_FILE=""
ARGS=()
while (( $# > 0 )); do
  case "$1" in
    --root)      ROOT_DIR="${2:-}"; shift ;;
    --out)       OUT="${2:-}"; shift ;;
    --from-file) FROM_FILE="${2:-}"; shift ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
set -- ${ARGS[@]+"${ARGS[@]}"}

[[ -d "$ROOT_DIR" ]] || { printf 'ERROR=not a directory: %s\n' "$ROOT_DIR" >&2; exit 1; }
cd "$ROOT_DIR" || exit 1

die2() { printf 'ERROR=%s\n' "$1" >&2; exit 2; }

# ── The config ────────────────────────────────────────────────────
# JIRA_URL and JIRA_TOKEN, read from ~/.config/sdd-kit/tokens.env first and
# then from <root>/.sdd/sdd.conf, the second overriding the first. Both files
# are ignored by git, and the token file holds nothing but secrets, so it wants
# `chmod 600 ~/.config/sdd-kit/tokens.env` — it is created 644.
#
# Parsed the way `lib/log.sh` and `build-command.sh` parse the same file, and
# for the same reason: `. .sdd/sdd.conf` is one line shorter and would execute
# whatever the file holds on every run of every script. A strict read over a
# fixed set of keys — quotes stripped, comments and blank lines skipped,
# everything else ignored without a word.
conf_read() {
  awk '
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      sub(/^export[[:space:]]+/, "", line)
      p = index(line, "=")
      if (p < 2) next
      key = substr(line, 1, p - 1)
      val = substr(line, p + 1)
      sub(/[[:space:]]+$/, "", key)
      sub(/^[[:space:]]+/, "", val)
      if (key !~ /^JIRA_(URL|TOKEN)$/) next
      gsub(/^["\047]|["\047]$/, "", val)
      print key "=" val
    }
  ' "$1" 2>/dev/null
}

# The token file first, then the project's own config, which overrides it: the
# home file is where a token belongs, the project file is where an instance
# that differs from the usual one is named. A missing file is not an error.
TOKEN_FILE="${HOME:-}/.config/sdd-kit/tokens.env"
CONF=".sdd/sdd.conf"
JIRA_URL_CFG=""
JIRA_TOKEN_CFG=""

conf_load() {
  local file="$1" key val
  [[ -r "$file" ]] || return 0
  while IFS='=' read -r key val; do
    case "$key" in
      JIRA_URL)   JIRA_URL_CFG="$val" ;;
      JIRA_TOKEN) JIRA_TOKEN_CFG="$val" ;;
    esac
  done <<EOF
$(conf_read "$file")
EOF
  return 0
}

conf_load "$TOKEN_FILE"
conf_load "$CONF"

# The environment wins over both files, so a one-off run against another
# instance needs no edit to either.
JIRA_URL="${JIRA_URL:-$JIRA_URL_CFG}"
JIRA_TOKEN="${JIRA_TOKEN:-$JIRA_TOKEN_CFG}"

if [[ -z "$JIRA_TOKEN" ]]; then
  die2 "no JIRA_TOKEN — set it in $TOKEN_FILE or in $CONF (chmod 600 the token file)"
fi

# ── The tools ─────────────────────────────────────────────────────
# jq is the engine's first external dependency, and it is required on every
# path: even a --from-file run parses the same JSON. curl is required only when
# the answer has to come off the network.
command -v jq >/dev/null 2>&1 || { printf 'ERROR=missing: jq\n' >&2; exit 1; }
if [[ -z "$FROM_FILE" ]]; then
  command -v curl >/dev/null 2>&1 || { printf 'ERROR=missing: curl\n' >&2; exit 1; }
fi

# ── The argument ──────────────────────────────────────────────────
# One argument carries both the issue and, when it is a link, the instance it
# came from. A link is the form a human already has in the clipboard, and it
# names its own host, so no configuration is consulted for it.
ARG="${1:-}"
[[ -n "$ARG" ]] || die2 "no issue — jira-fetch.sh <issue-url-or-key> --out <path>"
[[ -n "$OUT" ]] || die2 "no --out — jira-fetch.sh <issue-url-or-key> --out <path>"

KEY=""
BASE=""
if [[ "$ARG" == *"/browse/"* ]]; then
  # Everything to the left of /browse/ is the base, so an instance served under
  # a context path works without being told about it. Anything the browser
  # appended after the key — a query, a fragment — is not part of the key.
  BASE="${ARG%%/browse/*}"
  KEY="${ARG#*/browse/}"
  KEY="${KEY%%[?#]*}"
  KEY="${KEY%%/*}"
elif printf '%s' "$ARG" | LC_ALL=C grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$'; then
  KEY="$ARG"
  BASE="$JIRA_URL"
  [[ -n "$BASE" ]] || die2 "no JIRA_URL — a bare key needs the instance; set JIRA_URL in $TOKEN_FILE or in $CONF, or pass the browse URL instead"
else
  die2 "not an issue key or a browse URL: $ARG"
fi
BASE="${BASE%/}"
printf '%s' "$KEY" | LC_ALL=C grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$' \
  || die2 "not an issue key: $KEY"

# ── The temporary directory ───────────────────────────────────────
# One trap, owned here. lib/log.sh says why it matters: a second `trap … EXIT`
# replaces the first without a word, and the directory would survive the run.
# The whole file is built in here and moved into place at the very end, so a
# failure half-way through leaves --out exactly as it was.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sdd-jira.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

replace_file() {
  local target="$1" source="$2"
  cat "$source" > "$target" || { printf 'ERROR=could not write %s\n' "$target" >&2; exit 1; }
}

# A counter, not ${#NOTES[@]}: on bash 3.2 an empty array counts as unset under
# `set -u` and reading its length aborts the script.
NOTES=(); N_NOTE=0
note() { NOTES+=("$1"); N_NOTE=$(( N_NOTE + 1 )); }

# ── The answer ────────────────────────────────────────────────────
# --from-file is the same path with the network taken out of it: everything
# downstream reads $TMP/issue.json and cannot tell the two apart. Every test
# runs through it.
BODY="$TMP/issue.json"
if [[ -n "$FROM_FILE" ]]; then
  [[ -r "$FROM_FILE" ]] || die2 "cannot read $FROM_FILE"
  cat "$FROM_FILE" > "$BODY" || die2 "cannot read $FROM_FILE"
else
  URL="$BASE/rest/api/2/issue/$KEY?fields=summary,description,attachment"
  # No -L: a redirect is not followed but reported. Following it would hand the
  # Bearer header to whatever the load balancer points at, and the answer would
  # be a login page that parses as neither JSON nor an error.
  META="$(curl -sS -o "$BODY" \
    -w '%{http_code}\n%{content_type}\n%{redirect_url}\n' \
    -H "Authorization: Bearer $JIRA_TOKEN" \
    -H 'Accept: application/json' \
    "$URL" 2>"$TMP/curl.err")" || {
      die2 "curl failed: $(head -n 1 "$TMP/curl.err" 2>/dev/null)"
    }
  CODE="$(printf '%s\n' "$META" | sed -n 1p)"
  CTYPE="$(printf '%s\n' "$META" | sed -n 2p)"
  REDIR="$(printf '%s\n' "$META" | sed -n 3p)"

  host_of() { printf '%s' "$1" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#[/?#].*$##' -e 's#^[^@]*@##'; }

  case "$CODE" in
    3??)
      # The instance sits behind SSO. Off the VPN every request answers with a
      # redirect to the identity provider and the token never reaches Jira.
      if [[ -n "$REDIR" && "$(host_of "$REDIR")" != "$(host_of "$BASE")" ]]; then
        die2 "Jira answered with a redirect to $(host_of "$REDIR"); the instance is behind SSO and the token never reaches it. Check that the VPN is up."
      fi
      die2 "Jira answered $CODE with a redirect to $REDIR"
      ;;
    401|403) die2 "Jira answered $CODE — the token was rejected. Check JIRA_TOKEN in $TOKEN_FILE or in $CONF." ;;
    404)     die2 "Jira answered 404 — no issue $KEY on $BASE" ;;
    200)     ;;
    *)       die2 "Jira answered $CODE" ;;
  esac

  case "$CTYPE" in
    application/json*) ;;
    *) die2 "the answer from $BASE is $CTYPE, not JSON — that was not Jira" ;;
  esac
fi

jq -e . "$BODY" >/dev/null 2>&1 || die2 "the answer from $BASE will not parse as JSON"

SUMMARY="$(jq -r '.fields.summary // ""' "$BODY")"
jq -r '.fields.description // ""' "$BODY" > "$TMP/description.wiki"

[[ -n "$SUMMARY" ]] || note "The issue has no summary; the title carries the key alone."

# ── Wiki markup to Markdown ───────────────────────────────────────
# Reads the wiki text on stdin, writes Markdown on stdout.
#
# Order matters. A code block is recognised before anything else is looked at
# and nothing inside one is converted, or a Java generic would become a list
# and an underscore in an identifier would become emphasis.
#
# Three shapes below look like defensive programming and are not. All three
# occur in real issues on this instance, and each one breaks a line-by-line
# replacement written against the documented syntax:
#   * a list marker carries a leading space — the line reads " * item", so a
#     ^\* pattern matches none of them;
#   * a heading can sit flush against the paragraph above it, and converted
#     as-is it stops being a heading in Markdown, so a blank line is inserted;
#   * a line can hold a single space, which reads as indentation if left alone.
wiki_to_md() {
  # LC_ALL=C, so awk works on bytes. Every pattern below is ASCII and any
  # other byte is copied through untouched, which makes the conversion the
  # same everywhere; left to the locale, an awk that decodes UTF-8 can stop
  # on a byte it does not recognise and answer with nothing at all.
  LC_ALL=C awk '
  # Inline conversions are stashed as tokens and put back at the end of the
  # line: a converted link must not be searched for emphasis, or a URL holding
  # an underscore would come back italicised.
  function rep_esc(s) { gsub(/\\/, "\\\\", s); gsub(/&/, "\\&", s); return s }
  function stash(s,   k) { NTOK++; k = sprintf("\001%d\002", NTOK); TOK[k] = s; return k }
  function unstash(s,   k, i) {
    for (i = 0; i < 6; i++) {
      if (s !~ /\001[0-9]+\002/) break
      for (k in TOK) if (index(s, k) > 0) gsub(k, rep_esc(TOK[k]), s)
    }
    return s
  }
  function is_word(c) { return c ~ /^[A-Za-z0-9]$/ }
  function enc_spaces(s) { gsub(/ /, "%20", s); return s }
  function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

  # Jira breaks markup up with an empty macro. {*}bold{*} is written where a
  # plain *bold* would run into the character next to it, and {{{}mono{}}}
  # where the monospace text itself begins or ends with a brace. The empty
  # braces render as nothing. Only these shapes are undone: a bare {} anywhere
  # else is left alone, or an empty Java block in a sentence would disappear.
  function unbrace(s) {
    gsub(/\{\{\{\}/, "{{", s)
    gsub(/\{\}\}\}/, "}}", s)
    gsub(/\{\*\}/, "*", s)
    gsub(/\{_\}/, "_", s)
    return s
  }

  function conv_mono(s,   out, p, tail, q, inner) {
    out = ""
    while ((p = index(s, "{{")) > 0) {
      tail = substr(s, p + 2)
      q = index(tail, "}}")
      if (q == 0) break
      inner = substr(tail, 1, q - 1)
      out = out substr(s, 1, p - 1) stash("`" inner "`")
      s = substr(tail, q + 2)
    }
    return out s
  }

  # !name.png!, !name.png|thumbnail! and !name.png|width=300! are the same
  # link: the options are a rendering hint Markdown has no place for. The file
  # name is required to carry an extension, so a bare pair of exclamation
  # marks around a sentence is left alone.
  function conv_images(s,   out, rest, m, tok, bar, fn) {
    out = ""; rest = s
    while (match(rest, /![^!|[:space:]]+\.[A-Za-z0-9]+(\|[^!]*)?!/)) {
      m = substr(rest, RSTART, RLENGTH)
      tok = substr(m, 2, length(m) - 2)
      bar = index(tok, "|")
      fn = (bar > 0) ? substr(tok, 1, bar - 1) : tok
      out = out substr(rest, 1, RSTART - 1) stash("![" fn "](attachments/" enc_spaces(fn) ")")
      rest = substr(rest, RSTART + RLENGTH)
    }
    return out rest
  }

  function conv_links(s,   out, rest, m, inner, bar, text, url) {
    out = ""; rest = s
    while (match(rest, /\[[^][]*\]/)) {
      m = substr(rest, RSTART, RLENGTH)
      inner = substr(m, 2, length(m) - 2)
      bar = index(inner, "|")
      out = out substr(rest, 1, RSTART - 1)
      if (bar > 0) {
        text = substr(inner, 1, bar - 1)
        url = substr(inner, bar + 1)
        out = out stash("[" text "](" url ")")
      } else if (inner ~ /^(https?|ftp|mailto):/) {
        out = out stash("<" inner ">")
      } else {
        out = out stash(m)
      }
      rest = substr(rest, RSTART + RLENGTH)
    }
    return out rest
  }

  # A delimiter only opens emphasis where a word does not already run into it.
  # That single test is what keeps SOME_CONST_NAME out of italics without
  # escaping the underscore: escaping corrupts the identifier for anyone who
  # copies it back out, and _docs/ is read mostly by models.
  function conv_emph(s, d, wrap,   out, rest, p, before, pre, prevc, tail, q, inner, nextc) {
    out = ""; rest = s
    while ((p = index(rest, d)) > 0) {
      before = substr(rest, 1, p - 1)
      pre = out before
      prevc = (pre == "") ? "" : substr(pre, length(pre), 1)
      tail = substr(rest, p + 1)
      q = index(tail, d)
      inner = (q > 1) ? substr(tail, 1, q - 1) : ""
      nextc = (q > 1) ? substr(tail, q + 1, 1) : ""
      if (q > 1 && !is_word(prevc) && prevc != d && nextc != d && !is_word(nextc) &&
          inner !~ /^[[:space:]]/ && inner !~ /[[:space:]]$/) {
        out = pre stash(wrap inner wrap)
        rest = substr(tail, q + 1)
      } else {
        out = pre d
        rest = tail
      }
    }
    return out rest
  }

  # A wrapper that carries no meaning outside Jira: the text it holds stays,
  # the wrapper goes.
  function drop_wrappers(s) {
    gsub(/\{color:[^}]*\}/, "", s)
    gsub(/\{color\}/, "", s)
    gsub(/\{panel:[^}]*\}/, "", s)
    gsub(/\{panel\}/, "", s)
    gsub(/\{anchor:[^}]*\}/, "", s)
    return s
  }

  function conv_inline(s) {
    s = drop_wrappers(s)
    s = unbrace(s)
    s = conv_mono(s)
    s = conv_images(s)
    s = conv_links(s)
    s = conv_emph(s, "*", "**")
    s = conv_emph(s, "_", "*")
    return unstash(s)
  }

  function out_line(l) { NL++; LINES[NL] = l }
  function emit(l) { out_line(inquote ? "> " l : l) }
  function need_blank() { if (NL > 0 && LINES[NL] != "") out_line("") }

  BEGIN {
    NL = 0; NTOK = 0; incode = 0; inquote = 0; waslist = 0; intable = 0
    NBSP = sprintf("%c%c", 194, 160)
  }

  {
    line = $0
    sub(/\r$/, "", line)

    # A non-breaking space is a space in everything this converter decides, and
    # Jira issues are full of them: they arrive with pasted text. Reading bytes,
    # nothing here would recognise one — a list marker followed by one would
    # keep it as the first character of the item, and a line holding nothing
    # else would read as indentation rather than as the blank line it looks
    # like. The character itself is not worth preserving; how it renders is.
    gsub(NBSP, " ", line)

    if (incode) {
      if (line ~ /^[[:space:]]*\{(code|noformat)\}[[:space:]]*$/) {
        out_line("```"); out_line(""); incode = 0
      } else out_line(line)
      next
    }

    if (line ~ /^[[:space:]]*\{(code|noformat)(:[^}]*)?\}[[:space:]]*$/) {
      lang = ""
      if (match(line, /\{code:[^}]*\}/)) {
        spec = substr(line, RSTART + 6, RLENGTH - 7)
        n = split(spec, parts, "|")
        for (i = 1; i <= n; i++) {
          if (parts[i] ~ /^language=/) lang = substr(parts[i], 10)
          else if (index(parts[i], "=") == 0 && lang == "") lang = parts[i]
        }
      }
      need_blank()
      out_line("```" lang)
      incode = 1; waslist = 0; intable = 0
      next
    }

    if (line ~ /^[[:space:]]*\{quote\}[[:space:]]*$/) {
      inquote = !inquote; need_blank(); waslist = 0; intable = 0
      next
    }

    if (line ~ /^[[:space:]]*$/) { out_line(""); waslist = 0; intable = 0; next }

    if (line ~ /^[[:space:]]*h[1-6]\./) {
      t = trim(line)
      lvl = substr(t, 2, 1) + 0
      text = substr(t, 4); sub(/^[[:space:]]+/, "", text)
      hashes = ""
      for (i = 0; i < lvl; i++) hashes = hashes "#"
      need_blank()
      emit(hashes " " conv_inline(text))
      out_line("")
      waslist = 0; intable = 0
      next
    }

    # One branch for both kinds of list, because Jira mixes them: "#*" is a
    # bullet inside a numbered item. The marker does not always spell the whole
    # path, though — a nested bullet under a numbered item is often written
    # "**" — so the kind of each level is remembered from the line that opened
    # it. The indent has to clear the marker of the parent: three columns under
    # "1. ", two under "- ". Two under a numbered parent and Markdown reads the
    # nested item as a paragraph of its own and the nesting is lost.
    if (match(line, /^[[:space:]]*[*#]+[[:space:]]+/)) {
      marks = substr(line, RSTART, RLENGTH); gsub(/[^*#]/, "", marks)
      text = substr(line, RSTART + RLENGTH)
      if (!waslist) { split("", LTYPE); need_blank() }
      depth = length(marks)
      ind = ""
      for (i = 1; i < depth; i++) {
        if (!(i in LTYPE)) LTYPE[i] = substr(marks, i, 1)
        ind = ind (LTYPE[i] == "#" ? "   " : "  ")
      }
      LTYPE[depth] = substr(marks, depth, 1)
      emit(ind (LTYPE[depth] == "#" ? "1. " : "- ") conv_inline(text))
      waslist = 1; intable = 0
      next
    }

    # The header row of a table brings the alignment row with it: Markdown has
    # no table without one, and Jira has no row that says where it goes.
    if (line ~ /^[[:space:]]*\|\|/) {
      row = trim(line); sub(/^\|\|/, "", row); sub(/\|\|$/, "", row)
      n = split(row, cells, /\|\|/)
      o = "|"; sep = "|"
      for (i = 1; i <= n; i++) { o = o " " conv_inline(trim(cells[i])) " |"; sep = sep " --- |" }
      if (!intable) need_blank()
      emit(o); emit(sep)
      intable = 1; waslist = 0
      next
    }

    if (line ~ /^[[:space:]]*\|/) {
      row = trim(line); sub(/^\|/, "", row); sub(/\|$/, "", row)
      n = split(row, cells, /\|/)
      o = "|"
      for (i = 1; i <= n; i++) o = o " " conv_inline(trim(cells[i])) " |"
      if (!intable) need_blank()
      emit(o)
      intable = 1; waslist = 0
      next
    }

    emit(conv_inline(line))
    waslist = 0; intable = 0
  }

  END { for (i = 1; i <= NL; i++) print LINES[i] }
  '
}

# The converter is not allowed to fail quietly. awk can answer with an empty
# result and still exit 0, and the file would then be written as though the
# issue carried no description at all — the one failure that looks exactly like
# a legitimate outcome. A non-zero exit, anything on stderr, or a description
# that went in with text and came out empty is a stop: the --out file is left
# untouched and what awk said is passed on.
wiki_to_md < "$TMP/description.wiki" > "$TMP/description.md" 2> "$TMP/convert.err"
CONV_RC=$?
if (( CONV_RC != 0 )) || [[ -s "$TMP/convert.err" ]]; then
  die2 "the description of $KEY did not convert (exit $CONV_RC): $(tr '\n' ' ' < "$TMP/convert.err")"
fi
if LC_ALL=C grep -q '[^[:space:]]' "$TMP/description.wiki" &&
   ! LC_ALL=C grep -q '[^[:space:]]' "$TMP/description.md"; then
  die2 "the description of $KEY holds text but converted to nothing; nothing was written."
fi

# Not `-s`: jq prints a newline for an empty string, so the file is one byte
# rather than none, and an issue with no description would look like one with a
# blank line in it.
if ! LC_ALL=C grep -q '[^[:space:]]' "$TMP/description.md"; then
  : > "$TMP/description.md"
fi
if [[ ! -s "$TMP/description.md" ]]; then
  note "The issue has an empty description; only the title, the link and the two sections below were written."
fi

# ── The two sections the flow reads by name ───────────────────────
# `## Known constraints` and `## Out of scope` are the only headings anything
# reads by name (.sdd/protocols/architecture-design.md, spec-checklist.md), and
# the human fills them in after the import. Their hint text is copied out of
# .sdd/templates/raw.md rather than repeated here, so it stays one text.
TEMPLATE_RAW="$SCRIPT_DIR/../templates/raw.md"

# The heading and everything under it, up to the next heading of the same level.
section_of() {
  local file="$1" heading="$2"
  awk -v want="$heading" '
    $0 == want { inside = 1; print; next }
    inside && /^## / { inside = 0 }
    inside { print }
  ' "$file"
}

# Whether the issue already brought a heading of that name. md_uncomment is
# what decides it: a heading written inside an HTML comment is not a heading,
# and the same reader answers that question everywhere under _docs/.
has_heading() {
  local file="$1" heading="$2"
  md_uncomment "$file" | LC_ALL=C grep -qxF "$heading"
}

# ── The file ──────────────────────────────────────────────────────
OUT_FILE="$TMP/raw.md"
{
  if [[ -n "$SUMMARY" ]]; then
    printf '# %s — %s\n\n' "$KEY" "$SUMMARY"
  else
    printf '# %s\n\n' "$KEY"
  fi
  printf '%s/browse/%s\n' "$BASE" "$KEY"
  if [[ -s "$TMP/description.md" ]]; then
    printf '\n'
    cat "$TMP/description.md"
  fi
} > "$OUT_FILE"

for heading in '## Known constraints' '## Out of scope'; do
  if has_heading "$TMP/description.md" "$heading"; then
    note "The issue already carries a \`$heading\` heading; it was not appended a second time."
    continue
  fi
  if [[ -r "$TEMPLATE_RAW" ]]; then
    body="$(section_of "$TEMPLATE_RAW" "$heading")"
  else
    body=""
  fi
  [[ -n "$body" ]] || body="$heading"
  printf '\n%s\n' "$body" >> "$OUT_FILE"
done

# Never two blank lines in a row, and no trailing whitespace: the file is read
# by a model and diffed by a test, and both are quieter for it.
awk '
  { sub(/[[:space:]]+$/, "") }
  /^$/ { if (blank) next; blank = 1; print; next }
  { blank = 0; print }
' "$OUT_FILE" > "$TMP/raw.tidy" && mv "$TMP/raw.tidy" "$OUT_FILE"

OUT_DIR="$(dirname "$OUT")"
[[ -d "$OUT_DIR" ]] || mkdir -p "$OUT_DIR" || die2 "cannot create $OUT_DIR"
replace_file "$OUT" "$OUT_FILE"

# ── Attachments ───────────────────────────────────────────────────
# Only what the description points at. An issue collects attachments over its
# life — screenshots of a bug that was fixed, a spreadsheet somebody dropped in
# a comment — and none of that is part of the text being imported. What is not
# referenced is counted in NOTES: and left in Jira.
#
# This runs after raw.md is in place, and that order is the rule: a download
# that fails leaves the file, and its link, exactly as they were written. The
# link points at a file that is not there, and NOTES: names it.
ATT=(); N_ATT=0
att_add() { ATT+=("$1"); N_ATT=$(( N_ATT + 1 )); }

# The names the description references, in the order they appear, each one
# once. The pattern is the one conv_images converts with, so the list and the
# links in the file cannot disagree; a code block is skipped, because a !name!
# inside one was never turned into a link either.
refs_of() {
  awk '
    /^[[:space:]]*\{(code|noformat)(:[^}]*)?\}[[:space:]]*$/ { incode = !incode; next }
    incode { next }
    {
      rest = $0
      while (match(rest, /![^!|[:space:]]+\.[A-Za-z0-9]+(\|[^!]*)?!/)) {
        m = substr(rest, RSTART + 1, RLENGTH - 2)
        bar = index(m, "|")
        if (bar > 0) m = substr(m, 1, bar - 1)
        if (!(m in seen)) { seen[m] = 1; print m }
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

refs_of "$TMP/description.wiki" > "$TMP/refs.txt"
# `grep -c` prints its count and then exits 1 when the count is zero, so a
# `|| printf 0` fallback would append a second zero to the first and every
# arithmetic use of the value below would abort. The count is taken first and
# the fallback covers only an empty result.
N_REF="$(LC_ALL=C grep -c . "$TMP/refs.txt" 2>/dev/null)" || true
N_HAVE="$(jq -r '.fields.attachment // [] | length' "$BODY" 2>/dev/null)" || true
N_REF="${N_REF:-0}"
N_HAVE="${N_HAVE:-0}"

ATT_DIR="$OUT_DIR/attachments"

while IFS= read -r fn; do
  [[ -n "$fn" ]] || continue
  # A name is a name, never a path: an issue is written by anyone with an
  # account, and `!../../../x.png!` would otherwise write outside the feature.
  if [[ "$fn" == */* || "$fn" == .* ]]; then
    note "\`$fn\` was not downloaded: an attachment name may not be a path."
    continue
  fi
  # `last`, not `first`: when a file has been re-uploaded under the same name
  # Jira keeps both, and the newest one is the one the description means.
  url="$(jq -r --arg fn "$fn" '[.fields.attachment[]? | select(.filename == $fn) | .content // empty] | last // ""' "$BODY")"
  if [[ -z "$url" ]]; then
    note "\`$fn\` is referenced by the description but is not attached to the issue; the link was kept and points at nothing."
    continue
  fi
  if [[ -n "$FROM_FILE" ]]; then
    note "\`$fn\` was not downloaded: --from-file is a file read and this run makes no request."
    continue
  fi
  [[ -d "$ATT_DIR" ]] || mkdir -p "$ATT_DIR" || { note "\`$fn\` was not downloaded: $ATT_DIR could not be created."; continue; }
  code="$(curl -sS -o "$TMP/att.bin" -w '%{http_code}' \
    -H "Authorization: Bearer $JIRA_TOKEN" \
    "$url" 2>"$TMP/curl.err")" || code=""
  if [[ "$code" != "200" ]]; then
    note "\`$fn\` was not downloaded: the request answered ${code:-nothing}. The link was kept."
    continue
  fi
  if ! cat "$TMP/att.bin" > "$ATT_DIR/$fn"; then
    note "\`$fn\` was downloaded but could not be written to $ATT_DIR."
    continue
  fi
  att_add "attachments/$fn"
done < "$TMP/refs.txt"

# The link in the Markdown is percent-encoded; the report names the file on
# disk, so it is the one place the name appears as it was uploaded.
if (( N_HAVE > N_REF )); then
  note "$(( N_HAVE - N_REF )) attachment(s) on the issue are not referenced by the description and were not downloaded."
fi

# ── The report ────────────────────────────────────────────────────
OUT_REL="${OUT#./}"
printf 'JIRA=ok\nKEY=%s\nBASE=%s\nSUMMARY=%s\nOUT=%s\n' "$KEY" "$BASE" "$SUMMARY" "$OUT_REL"
printf '\nATTACHMENTS:\n'
if (( N_ATT > 0 )); then
  printf '%s\n' "${ATT[@]}"
fi
printf '\nNOTES:\n'
if (( N_NOTE > 0 )); then
  printf '%s\n' "${NOTES[@]}"
fi
exit 0
