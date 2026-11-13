#!/usr/bin/env bash
# Reads one Confluence Data Center page into a Markdown file, with the images
# and attachments the page shows or links downloaded beside it.
#
# Usage: confluence-fetch.sh <page-url-or-id> [--out <file>] [--tokens <file>]...
#                            [--no-attachments] [--from-file <json>] [--parse-only]
#
# Prints KEY=value lines, then ATTACHMENTS: and NOTES: blocks. Every failure
# prints ERROR= and hint: lines on stderr. Exit codes:
#   0 — the file was written
#   1 — the environment is wrong: no curl or jq, no token, no instance URL
#   2 — usage: no argument, or not a link to a page
#   3 — the page could not be read: HTTP error, SSO redirect, not found
#   4 — the answer was unusable: not JSON, or the page did not convert
# Nothing is written unless the run ends with 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'EOF'
Usage: confluence-fetch.sh <page-url-or-id> [options]

  <page-url-or-id>   any link to a page, as copied from the browser:
                       https://<base>/spaces/<SPACE>/pages/<id>/<Title>
                       https://<base>/pages/viewpage.action?pageId=<id>
                       https://<base>/display/<SPACE>/<Title>
                       https://<base>/x/<code>
                     or a bare page id (needs CONFLUENCE_URL)

  --out <file>       where the Markdown goes; attachments go to attachments/ beside it
                     (default: $TMPDIR/confluence-fetch/<id>/page.md)
  --tokens <file>    a file of KEY=value lines to read the config from; may be
                     given more than once, a later file winning
  --no-attachments   keep the links, download nothing
  --from-file <json> read the REST answer from a file instead of the network
  --parse-only       print what the link resolves to and stop; no request is made

Config: CONFLUENCE_URL and CONFLUENCE_TOKEN (a personal access token), read from the
--tokens files; the environment fills in what no file set.
EOF
}

# ── Arguments ─────────────────────────────────────────────────────
TOKEN_FILES=(); N_TF=0
OUT=""
FROM_FILE=""
NO_ATT=0
PARSE_ONLY=0
ARG=""
while (( $# > 0 )); do
  case "$1" in
    --tokens)         TOKEN_FILES+=("${2:-}"); N_TF=$(( N_TF + 1 )); shift ;;
    --out)            OUT="${2:-}"; shift ;;
    --from-file)      FROM_FILE="${2:-}"; shift ;;
    --no-attachments) NO_ATT=1 ;;
    --parse-only)     PARSE_ONLY=1 ;;
    -h|--help)        usage; exit 0 ;;
    -*)               printf 'ERROR=unknown option: %s\nhint: confluence-fetch.sh --help\n' "$1" >&2; exit 2 ;;
    *)
      if [[ -n "$ARG" ]]; then
        printf 'ERROR=one page per call; got a second argument: %s\n' "$1" >&2; exit 2
      fi
      ARG="$1" ;;
  esac
  shift
done

die() {
  local code="$1" msg="$2" hint="${3:-}"
  printf 'ERROR=%s\n' "$msg" >&2
  [[ -n "$hint" ]] && printf 'hint: %s\n' "$hint" >&2
  exit "$code"
}

[[ -n "$ARG" ]] || die 2 "no page" "confluence-fetch.sh <page-url-or-id> — see --help"

# ── The config ────────────────────────────────────────────────────
# CONFLUENCE_URL and CONFLUENCE_TOKEN come from the tokens files the caller names with
# --tokens, in the order given, a later file winning over an earlier one; the
# environment fills in only what no file set. The script looks for no file of
# its own accord. A file is read, never sourced — `. file` would run whatever
# it holds — and only the two keys below are taken; everything else in it is
# ignored, so a project config that also holds other settings can be passed
# as it is. A file that holds a token wants `chmod 600`.
URL_CFG=""
TOKEN_CFG=""

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
      if (key !~ /^CONFLUENCE_(URL|TOKEN)$/) next
      gsub(/^["\047]|["\047]$/, "", val)
      print key "=" val
    }
  ' "$1" 2>/dev/null
}

conf_load() {
  local file="$1" key val
  [[ -f "$file" && -r "$file" ]] || die 1 "cannot read the tokens file: $file" "pass the path of an existing file with --tokens, or leave --tokens out"
  while IFS='=' read -r key val; do
    case "$key" in
      CONFLUENCE_URL)   URL_CFG="$val" ;;
      CONFLUENCE_TOKEN) TOKEN_CFG="$val" ;;
    esac
  done <<EOF
$(conf_read "$file")
EOF
  return 0
}

TF_LIST=""
for (( i = 0; i < N_TF; i++ )); do
  conf_load "${TOKEN_FILES[$i]}"
  TF_LIST="${TF_LIST:+$TF_LIST, }${TOKEN_FILES[$i]}"
done
CONFLUENCE_URL="${URL_CFG:-${CONFLUENCE_URL:-}}"
CONFLUENCE_TOKEN="${TOKEN_CFG:-${CONFLUENCE_TOKEN:-}}"
CONFLUENCE_URL="${CONFLUENCE_URL%/}"

# Where a missing or wrong value is to be fixed, for the hint: the files that
# were passed, or how to pass one.
put_hint() {
  if (( N_TF > 0 )); then printf 'put %s in %s' "$1" "$TF_LIST"
  else printf 'put %s in a tokens file and pass it with --tokens <file> (none was passed), or set it in the environment' "$1"; fi
}
check_where() {
  if (( N_TF > 0 )); then printf '%s' "$TF_LIST"; else printf 'the environment'; fi
}

# ── The link ──────────────────────────────────────────────────────
# A link names its own instance: everything left of the part that names the
# page is the base, so an instance under a context path needs no config. The
# title in a /spaces/ link is decoration — the id alone names the page.
KIND=""; BASE=""; ID=""; SPACE=""; TITLE=""; TINY=""

urldecode() {
  S="$1" LC_ALL=C awk 'BEGIN {
    s = ENVIRON["S"]; gsub(/\+/, " ", s); out = ""
    while ((p = index(s, "%")) > 0) {
      h = tolower(substr(s, p + 1, 2))
      if (h ~ /^[0-9a-f][0-9a-f]$/) {
        v = (index("0123456789abcdef", substr(h, 1, 1)) - 1) * 16 + index("0123456789abcdef", substr(h, 2, 1)) - 1
        out = out substr(s, 1, p - 1) sprintf("%c", v); s = substr(s, p + 3)
      } else { out = out substr(s, 1, p); s = substr(s, p + 1) }
    }
    printf "%s", out s
  }'
}

parse_link() {
  local a="$1" rest seg
  a="${a%%#*}"
  KIND=""; BASE=""; ID=""; SPACE=""; TITLE=""; TINY=""
  if [[ "$a" =~ ^[0-9]+$ ]]; then
    KIND=id; ID="$a"; BASE="$CONFLUENCE_URL"
    return 0
  fi
  [[ "$a" == http://* || "$a" == https://* ]] || return 1
  if [[ "$a" =~ [?\&]pageId=([0-9]+) ]]; then
    KIND=id; ID="${BASH_REMATCH[1]}"
    if [[ "$a" == */spaces/* ]]; then BASE="${a%%/spaces/*}"
    elif [[ "$a" == */pages/* ]]; then BASE="${a%%/pages/*}"
    else BASE="$CONFLUENCE_URL"; fi
  elif [[ "$a" == */spaces/*/pages/* ]]; then
    BASE="${a%%/spaces/*}"
    rest="${a#*/spaces/*/pages/}"
    seg="${rest%%[/?]*}"
    [[ "$seg" =~ ^[0-9]+$ ]] || return 1
    KIND=id; ID="$seg"
  elif [[ "$a" == */display/* ]]; then
    BASE="${a%%/display/*}"
    rest="${a#*/display/}"
    rest="${rest%%\?*}"
    SPACE="${rest%%/*}"
    [[ "$rest" == */* ]] || return 1
    TITLE="$(urldecode "${rest#*/}")"
    [[ -n "$SPACE" && -n "$TITLE" ]] || return 1
    KIND=title
  elif [[ "$a" == */x/* ]]; then
    BASE="${a%%/x/*}"
    TINY="${a#*/x/}"
    TINY="${TINY%%[/?]*}"
    [[ -n "$TINY" ]] || return 1
    KIND=tiny
  else
    return 1
  fi
  BASE="${BASE%/}"
  return 0
}

parse_link "$ARG" || die 2 "not a link to a Confluence page: $ARG" \
  "pass the page link as the browser shows it (…/spaces/<SPACE>/pages/<id>/…), or the page id"

if (( PARSE_ONLY )); then
  printf 'KIND=%s\nBASE=%s\n' "$KIND" "$BASE"
  case "$KIND" in
    id)    printf 'ID=%s\n' "$ID" ;;
    title) printf 'SPACE=%s\nTITLE=%s\n' "$SPACE" "$TITLE" ;;
    tiny)  printf 'TINY=%s\n' "$TINY" ;;
  esac
  exit 0
fi

# ── The tools ─────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || die 1 "missing: jq" "install jq (macOS: brew install jq)"
if [[ -z "$FROM_FILE" ]]; then
  command -v curl >/dev/null 2>&1 || die 1 "missing: curl"
  [[ -n "$CONFLUENCE_TOKEN" ]] || die 1 "no CONFLUENCE_TOKEN" \
    "create a personal access token in Confluence (profile → Settings → Personal Access Tokens) and $(put_hint 'CONFLUENCE_TOKEN=<token>')"
  [[ -n "$BASE" ]] || die 1 "no CONFLUENCE_URL — a bare page id needs the instance" \
    "$(put_hint 'CONFLUENCE_URL=<base url>'), or pass the page link instead of the id"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/confluence-fetch.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

NOTES=(); N_NOTE=0
note() { NOTES+=("$1"); N_NOTE=$(( N_NOTE + 1 )); }

host_of() { printf '%s' "$1" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#[/?#].*$##' -e 's#^[^@]*@##'; }

# One GET with the token. No -L: a redirect is reported, never followed, so the
# token cannot reach a host other than the one the link names. Sets CODE,
# CTYPE and REDIR.
http_get() {
  local url="$1" out="$2" meta; shift 2
  meta="$(curl -sS -o "$out" \
    -w '%{http_code}\n%{content_type}\n%{redirect_url}\n' \
    -H "Authorization: Bearer $CONFLUENCE_TOKEN" \
    "$@" "$url" 2>"$TMP/curl.err")" \
    || die 3 "curl failed: $(head -n 1 "$TMP/curl.err" 2>/dev/null)" "check the VPN and that $BASE opens in the browser"
  CODE="$(printf '%s\n' "$meta" | sed -n 1p)"
  CTYPE="$(printf '%s\n' "$meta" | sed -n 2p)"
  REDIR="$(printf '%s\n' "$meta" | sed -n 3p)"
}

check_answer() {
  local what="$1"
  case "$CODE" in
    200) ;;
    3??)
      if [[ -n "$REDIR" && "$(host_of "$REDIR")" != "$(host_of "$BASE")" ]]; then
        die 3 "Confluence answered with a redirect to $(host_of "$REDIR"): the instance is behind SSO and the token never reached it" \
          "check that the VPN is up"
      fi
      die 3 "Confluence answered $CODE with a redirect to $REDIR" "pass the link the redirect points at"
      ;;
    401) die 3 "Confluence answered 401 — the token was rejected" \
           "check CONFLUENCE_TOKEN in $(check_where); a token that expired or was revoked has to be created again" ;;
    403) die 3 "Confluence answered 403 — the token's owner may not read $what" "open the page in the browser with the same account" ;;
    404) die 3 "Confluence answered 404 — no $what on $BASE, or no permission to see it" "open the link in the browser to check it" ;;
    *)   die 3 "Confluence answered $CODE for $what" ;;
  esac
  case "$CTYPE" in
    application/json*) ;;
    *) die 4 "the answer from $BASE is ${CTYPE:-untyped}, not JSON — that was not the Confluence REST API" \
         "check that CONFLUENCE_URL or the link points at Confluence, with its context path" ;;
  esac
}

EXPAND="body.export_view,body.storage,version,space,ancestors"
BODY="$TMP/page.json"

if [[ -n "$FROM_FILE" ]]; then
  [[ -r "$FROM_FILE" ]] || die 2 "cannot read $FROM_FILE"
  cat "$FROM_FILE" > "$BODY" || die 2 "cannot read $FROM_FILE"
else
  # A tiny link is resolved by the redirect Confluence answers it with, read
  # but not followed, and only when it stays on the same host.
  if [[ "$KIND" == tiny ]]; then
    http_get "$BASE/x/$TINY" "$TMP/tiny.html"
    case "$CODE" in
      3??)
        [[ -n "$REDIR" && "$(host_of "$REDIR")" == "$(host_of "$BASE")" ]] \
          || die 3 "the tiny link /x/$TINY redirects to ${REDIR:-nowhere}, off $BASE" "check that the VPN is up, or pass the full page link"
        parse_link "$REDIR" && [[ "$KIND" != tiny ]] \
          || die 3 "the tiny link /x/$TINY redirects to $REDIR, which is not a page link" "open the link in the browser and pass the page link"
        ;;
      401) check_answer "the tiny link /x/$TINY" ;;
      404) die 3 "no page behind the tiny link /x/$TINY on $BASE" ;;
      *)   die 3 "the tiny link /x/$TINY answered $CODE instead of a redirect" "open it in the browser and pass the page link" ;;
    esac
  fi

  if [[ "$KIND" == title ]]; then
    http_get "$BASE/rest/api/content" "$BODY" -G -H 'Accept: application/json' \
      --data-urlencode "spaceKey=$SPACE" --data-urlencode "title=$TITLE" --data-urlencode "expand=$EXPAND"
    check_answer "page \"$TITLE\" in space $SPACE"
  else
    http_get "$BASE/rest/api/content/$ID?expand=$EXPAND" "$BODY" -H 'Accept: application/json'
    check_answer "page $ID"
  fi
fi

jq -e . "$BODY" >/dev/null 2>&1 || die 4 "the answer will not parse as JSON"

# A title lookup answers with a list; the page is its first entry.
jq 'if type == "object" and has("results") then (.results[0] // null) else . end' "$BODY" > "$TMP/one.json" \
  || die 4 "the answer will not parse as JSON"
if [[ "$(jq -r 'type' "$TMP/one.json")" != object ]]; then
  die 3 "no page titled \"$TITLE\" in space $SPACE" "open the link in the browser; a renamed page keeps its id, so pass the …/pages/<id>/ link"
fi
mv "$TMP/one.json" "$BODY"

ID="$(jq -r '.id // ""' "$BODY")"
[[ "$ID" =~ ^[0-9]+$ ]] || die 4 "the answer carries no page id — that was not a page"
PTITLE="$(jq -r '.title // ""' "$BODY")"
PSPACE="$(jq -r '.space.key // ""' "$BODY")"
PSPACE_NAME="$(jq -r '.space.name // ""' "$BODY")"
PVERSION="$(jq -r '.version.number // "" | tostring' "$BODY")"
PWHEN="$(jq -r '.version.when // "" | .[0:10]' "$BODY")"
PBY="$(jq -r '.version.by.displayName // ""' "$BODY")"
PPATH="$(jq -r '[.ancestors[]?.title] | join(" › ")' "$BODY")"
LINK_BASE="$(jq -r '._links.base // ""' "$BODY")"
LINK_UI="$(jq -r '._links.webui // ""' "$BODY")"
[[ -n "$BASE" ]] || BASE="${LINK_BASE%/}"
if [[ -n "$LINK_BASE" && -n "$LINK_UI" ]]; then
  PURL="${LINK_BASE%/}$LINK_UI"
elif [[ -n "$BASE" ]]; then
  PURL="$BASE/pages/viewpage.action?pageId=$ID"
else
  PURL=""
fi
ORIGIN="$(printf '%s' "$BASE" | sed -n 's#^\([a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]*\).*#\1#p')"

jq -r '.body.export_view.value // .body.view.value // ""' "$BODY" > "$TMP/page.html"
if ! LC_ALL=C grep -q '[^[:space:]]' "$TMP/page.html"; then
  if [[ "$(jq -r '.body.export_view // .body.view // "missing" | type' "$BODY")" == string ]]; then
    die 4 "the answer carries no page body" "the instance did not expand body.export_view"
  fi
  note "The page is empty."
fi

# ── HTML to Markdown ──────────────────────────────────────────────
# What the export view loses about the page's macros comes from the storage
# format: a PlantUML macro's source (the view has only its image) takes the
# image's place, and an expand macro without a title of its own loses
# Confluence's default text.
STORE="$TMP/store"; mkdir -p "$STORE"
COUNTS="$(jq -r '.body.storage.value // ""' "$BODY" | LC_ALL=C awk -v dir="$STORE" -f "$SCRIPT_DIR/storage-macros.awk")"
N_PUML="${COUNTS%% *}"; N_EXP="${COUNTS##* }"
[[ "$N_PUML" =~ ^[0-9]+$ ]] || N_PUML=0
[[ "$N_EXP" =~ ^[0-9]+$ ]] || N_EXP=0
: > "$TMP/dl.tsv"; : > "$TMP/notes.txt"
LC_ALL=C awk -v origin="$ORIGIN" -v dl="$TMP/dl.tsv" -v notes="$TMP/notes.txt" \
  -v store="$STORE" -v npuml="$N_PUML" -v nexp="$N_EXP" \
  -f "$SCRIPT_DIR/html-to-md.awk" < "$TMP/page.html" > "$TMP/body.md" 2> "$TMP/convert.err"
rc=$?
if (( rc != 0 )) || [[ -s "$TMP/convert.err" ]]; then
  die 4 "the page did not convert (exit $rc): $(tr '\n' ' ' < "$TMP/convert.err")"
fi
if LC_ALL=C grep -q '[^[:space:]]' "$TMP/page.html" && ! LC_ALL=C grep -q '[^[:space:]]' "$TMP/body.md"; then
  die 4 "the page holds HTML but converted to nothing"
fi
while IFS= read -r line; do [[ -n "$line" ]] && note "$line"; done < "$TMP/notes.txt"

# Every macro the conversion has no form for, by name. Their rendered HTML is
# carried over as text where it has any; what a script draws, or what is not
# rendered for export at all, is not in the file. Known: what becomes Markdown
# (code, noformat, the panels, expand, plantuml), what renders as plain content
# (status, jira, excerpt, details, layout sections), navigation (toc, anchor).
OTHER="$(LC_ALL=C sort -u "$STORE/macros" 2>/dev/null \
  | LC_ALL=C grep -vxE 'code|noformat|info|tip|note|warning|panel|expand|plantuml.*|toc|toc-zone|anchor|status|jira|excerpt|details|section|column' \
  | paste -sd ',' - | sed 's/,/, /g')"
[[ -n "$OTHER" ]] && note "The page holds macros the file carries at most as their rendered text: $OTHER. Open the page to see what they show."

# ── The file ──────────────────────────────────────────────────────
MD="$TMP/page.md"
{
  printf '# %s\n\n' "${PTITLE:-Page $ID}"
  [[ -n "$PURL" ]] && printf '%s\n' "$PURL"
  meta=""
  if [[ -n "$PSPACE" ]]; then
    meta="Space: $PSPACE"
    [[ -n "$PSPACE_NAME" && "$PSPACE_NAME" != "$PSPACE" ]] && meta="Space: $PSPACE_NAME ($PSPACE)"
  fi
  [[ -n "$PPATH" ]] && meta="${meta:+$meta · }Path: $PPATH"
  if [[ -n "$PVERSION" ]]; then
    v="Version: $PVERSION"
    [[ -n "$PWHEN" ]] && v="$v, $PWHEN"
    [[ -n "$PBY" ]] && v="$v, $PBY"
    meta="${meta:+$meta · }$v"
  fi
  [[ -n "$meta" ]] && printf '%s\n' "$meta"
  printf '\n'
  cat "$TMP/body.md"
} > "$MD"

# No trailing whitespace, never two blank lines in a row — except inside a
# fenced block, whose text is the page's own.
LC_ALL=C awk '
  { sub(/\r$/, "") }
  {
    probe = $0; sub(/^[ >]*/, "", probe)
    if (probe ~ /^```/) { fence = !fence; sub(/[[:space:]]+$/, ""); blank = 0; print; next }
    if (fence) { print; next }
    sub(/[[:space:]]+$/, "")
  }
  /^$/ { if (blank) next; blank = 1; print; next }
  { blank = 0; print }
' "$MD" > "$TMP/page.tidy" && mv "$TMP/page.tidy" "$MD"
# …and no blank line at the end.
LC_ALL=C awk '{ L[NR] = $0 } END { n = NR; while (n > 0 && L[n] == "") n--; for (i = 1; i <= n; i++) print L[i] }' \
  "$MD" > "$TMP/page.tidy" && mv "$TMP/page.tidy" "$MD"

[[ -n "$OUT" ]] || OUT="${TMPDIR:-/tmp}/confluence-fetch/$ID/page.md"
OUT="${OUT%/}"
OUT_DIR="$(dirname "$OUT")"
[[ -d "$OUT_DIR" ]] || mkdir -p "$OUT_DIR" || die 1 "cannot create $OUT_DIR"
cat "$MD" > "$OUT" || die 1 "cannot write $OUT"

# ── Attachments ───────────────────────────────────────────────────
# Only what the page itself shows or links, each once, from the same instance
# the page came from. A download that fails leaves its link in the file and
# is named under NOTES:.
ATT=(); N_ATT=0
ATT_DIR="$OUT_DIR/attachments"
N_DL="$(LC_ALL=C grep -c . "$TMP/dl.tsv" 2>/dev/null)" || true
N_DL="${N_DL:-0}"
if (( N_DL > 0 )); then
  if [[ -n "$FROM_FILE" ]]; then
    note "$N_DL attachment(s) were not downloaded: --from-file makes no request. The links were kept."
  elif (( NO_ATT )); then
    note "$N_DL attachment(s) were not downloaded (--no-attachments). The links were kept."
  else
    while IFS=$'\t' read -r url name; do
      [[ -n "$url" && -n "$name" ]] || continue
      if [[ "$(host_of "$url")" != "$(host_of "$BASE")" ]]; then
        note "\`$name\` was not downloaded: it is on another host. The link was kept."
        continue
      fi
      [[ -d "$ATT_DIR" ]] || mkdir -p "$ATT_DIR" || { note "\`$name\` was not downloaded: $ATT_DIR could not be created."; continue; }
      code="$(curl -sS -o "$TMP/att.bin" -w '%{http_code}' \
        -H "Authorization: Bearer $CONFLUENCE_TOKEN" "$url" 2>"$TMP/curl.err")" || code=""
      if [[ "$code" != 200 ]]; then
        note "\`$name\` was not downloaded: the request answered ${code:-nothing}. The link was kept."
        continue
      fi
      if ! cat "$TMP/att.bin" > "$ATT_DIR/$name"; then
        note "\`$name\` was downloaded but could not be written to $ATT_DIR."
        continue
      fi
      ATT+=("$ATT_DIR/$name"); N_ATT=$(( N_ATT + 1 ))
    done < "$TMP/dl.tsv"
  fi
fi

# ── The report ────────────────────────────────────────────────────
LINES="$(wc -l < "$OUT" | tr -d ' ')"
printf 'CONFLUENCE=ok\nID=%s\nTITLE=%s\nSPACE=%s\nVERSION=%s\nURL=%s\nOUT=%s\nLINES=%s\n' \
  "$ID" "$PTITLE" "$PSPACE" "$PVERSION" "$PURL" "$OUT" "$LINES"
printf '\nATTACHMENTS:\n'
(( N_ATT > 0 )) && printf '%s\n' "${ATT[@]}"
printf '\nNOTES:\n'
(( N_NOTE > 0 )) && printf '%s\n' "${NOTES[@]}"
exit 0
