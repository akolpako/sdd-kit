#!/usr/bin/env bash
# Searches a Confluence Data Center instance and lists the pages it finds.
#
# Usage: confluence-search.sh <text> [--space <KEY|link>]... [--type page|blogpost|all]
#                             [--limit <n>] [--start <n>] [--tokens <file>]...
#        confluence-search.sh --cql '<CQL>' [--limit <n>] [--start <n>] [--tokens <file>]...
#
# Prints KEY=value lines, then a RESULTS: block. Every failure prints ERROR=
# and hint: lines on stderr. Exit codes:
#   0 — the search ran (it may have found nothing: TOTAL=0)
#   1 — the environment is wrong: no curl or jq, no token, no instance URL
#   2 — usage: no query, a wrong option
#   3 — Confluence refused: token rejected, a CQL it would not take, SSO redirect
#   4 — the answer was unusable: not JSON

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: confluence-search.sh <text> [options]
       confluence-search.sh --cql '<CQL>' [options]

  <text>              words to look for, as in the search box of Confluence;
                      a phrase in double quotes is looked for as it is
  --space <KEY|link>  only in this space; may be given more than once. A link
                      (…/spaces/<KEY>/…, …/display/<KEY>/…) names the instance too
  --type <t>          page (the default), blogpost, or all
  --title             look in titles only
  --cql '<CQL>'       the query as CQL, taken as it is, instead of <text>,
                      --space, --type and --title
  --limit <n>         how many results to show, 1 to 50 (default 10)
  --start <n>         skip the first n — for the next page of results
  --tokens <file>     a file of KEY=value lines to read the config from; may be
                      given more than once, a later file winning
  --from-file <json>  read the REST answer from a file instead of the network

Config: CONFLUENCE_URL and CONFLUENCE_TOKEN (a personal access token), read from the
--tokens files; the environment fills in what no file set.
EOF
}

die() {
  local code="$1" msg="$2" hint="${3:-}"
  printf 'ERROR=%s\n' "$msg" >&2
  [[ -n "$hint" ]] && printf 'hint: %s\n' "$hint" >&2
  exit "$code"
}

# ── Arguments ─────────────────────────────────────────────────────
TOKEN_FILES=(); N_TF=0
SPACES=(); N_SP=0
TEXT=""; CQL=""; TYPE=page; TITLE_ONLY=0; LIMIT=10; START=0; FROM_FILE=""
while (( $# > 0 )); do
  case "$1" in
    --tokens)    TOKEN_FILES+=("${2:-}"); N_TF=$(( N_TF + 1 )); shift ;;
    --space)     SPACES+=("${2:-}"); N_SP=$(( N_SP + 1 )); shift ;;
    --type)      TYPE="${2:-}"; shift ;;
    --title)     TITLE_ONLY=1 ;;
    --cql)       CQL="${2:-}"; shift ;;
    --limit)     LIMIT="${2:-}"; shift ;;
    --start)     START="${2:-}"; shift ;;
    --from-file) FROM_FILE="${2:-}"; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          die 2 "unknown option: $1" "confluence-search.sh --help" ;;
    *)
      [[ -z "$TEXT" ]] || die 2 "one query per call; got a second argument: $1" "put a phrase in quotes: '\"a phrase\"'"
      TEXT="$1" ;;
  esac
  shift
done

[[ -n "$TEXT" || -n "$CQL" ]] || die 2 "no query" "confluence-search.sh <text> — see --help"
if [[ -n "$CQL" ]]; then
  [[ -z "$TEXT" ]] || die 2 "--cql takes the place of <text>; got both" "put the text into the CQL: siteSearch ~ \"…\""
  (( N_SP == 0 && TITLE_ONLY == 0 )) && [[ "$TYPE" == page ]] \
    || die 2 "--cql is taken as it is: --space, --type and --title do not go with it" "put them into the CQL: space = KEY and type = page"
fi
case "$TYPE" in page|blogpost|all) ;; *) die 2 "--type is page, blogpost or all, not: $TYPE" ;; esac
[[ "$LIMIT" =~ ^[0-9]+$ ]] && (( LIMIT >= 1 && LIMIT <= 50 )) || die 2 "--limit is a number from 1 to 50, not: $LIMIT"
[[ "$START" =~ ^[0-9]+$ ]] || die 2 "--start is a number, not: $START"

# ── The config ────────────────────────────────────────────────────
# As confluence-fetch.sh reads it: the --tokens files in order, a later one
# winning, the environment filling in what no file set. A file is read, never
# sourced, and only these two keys are taken from it.
URL_CFG=""; TOKEN_CFG=""
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

put_hint() {
  if (( N_TF > 0 )); then printf 'put %s in %s' "$1" "$TF_LIST"
  else printf 'put %s in a tokens file and pass it with --tokens <file> (none was passed), or set it in the environment' "$1"; fi
}
check_where() {
  if (( N_TF > 0 )); then printf '%s' "$TF_LIST"; else printf 'the environment'; fi
}

# ── The query ─────────────────────────────────────────────────────
# A space is a key or a link into it; a link names the instance as well.
BASE=""
KEYS=()
for (( i = 0; i < N_SP; i++ )); do
  s="${SPACES[$i]}"; s="${s%%#*}"; key=""
  if [[ "$s" == http://* || "$s" == https://* ]]; then
    if [[ "$s" == */spaces/* ]]; then b="${s%%/spaces/*}"; key="${s#*/spaces/}"
    elif [[ "$s" == */display/* ]]; then b="${s%%/display/*}"; key="${s#*/display/}"
    elif [[ "$s" =~ [?\&]spaceKey=([^\&]+) ]]; then b="${s%%/pages/*}"; b="${b%%/spaces/*}"; key="${BASH_REMATCH[1]}"
    else die 2 "not a link into a space: $s" "pass the space key, or a link …/spaces/<KEY>/…"; fi
    key="${key%%[/?]*}"
    b="${b%/}"
    [[ -z "$BASE" || "$BASE" == "$b" ]] || die 2 "the spaces are on two instances: $BASE and $b"
    BASE="$b"
  else
    key="$s"
  fi
  [[ "$key" =~ ^~?[A-Za-z0-9_.-]+$ ]] || die 2 "not a space key: ${SPACES[$i]}"
  KEYS+=("$key")
done
[[ -n "$BASE" ]] || BASE="$CONFLUENCE_URL"

# A CQL string in double quotes: a backslash and a quote are escaped.
cql_str() { local v="$1"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '"%s"' "$v"; }

if [[ -z "$CQL" ]]; then
  if (( TITLE_ONLY )); then CQL="title ~ $(cql_str "$TEXT")"
  else CQL="siteSearch ~ $(cql_str "$TEXT")"; fi
  if (( N_SP == 1 )); then CQL="$CQL and space = $(cql_str "${KEYS[0]}")"
  elif (( N_SP > 1 )); then
    list=""; for k in "${KEYS[@]}"; do list="${list:+$list, }$(cql_str "$k")"; done
    CQL="$CQL and space in ($list)"
  fi
  case "$TYPE" in
    page)     CQL="$CQL and type = page" ;;
    blogpost) CQL="$CQL and type = blogpost" ;;
    all)      CQL="$CQL and type in (page, blogpost)" ;;
  esac
fi

# ── The tools ─────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || die 1 "missing: jq" "install jq (macOS: brew install jq)"
if [[ -z "$FROM_FILE" ]]; then
  command -v curl >/dev/null 2>&1 || die 1 "missing: curl"
  [[ -n "$CONFLUENCE_TOKEN" ]] || die 1 "no CONFLUENCE_TOKEN" \
    "create a personal access token in Confluence (profile → Settings → Personal Access Tokens) and $(put_hint 'CONFLUENCE_TOKEN=<token>')"
  [[ -n "$BASE" ]] || die 1 "no CONFLUENCE_URL — a search needs the instance" \
    "$(put_hint 'CONFLUENCE_URL=<base url>'), or pass --space as a link into the space"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/confluence-search.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
ANSWER="$TMP/search.json"

host_of() { printf '%s' "$1" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#[/?#].*$##' -e 's#^[^@]*@##'; }

# ── The request ───────────────────────────────────────────────────
# One GET with the token, no -L: a redirect is reported, never followed, so
# the token cannot reach another host.
if [[ -n "$FROM_FILE" ]]; then
  [[ -r "$FROM_FILE" ]] || die 2 "cannot read $FROM_FILE"
  cat "$FROM_FILE" > "$ANSWER" || die 2 "cannot read $FROM_FILE"
else
  meta="$(curl -sS -o "$ANSWER" -w '%{http_code}\n%{content_type}\n%{redirect_url}\n' \
    -H "Authorization: Bearer $CONFLUENCE_TOKEN" -H 'Accept: application/json' \
    -G "$BASE/rest/api/search" \
    --data-urlencode "cql=$CQL" --data-urlencode "limit=$LIMIT" --data-urlencode "start=$START" \
    2>"$TMP/curl.err")" \
    || die 3 "curl failed: $(head -n 1 "$TMP/curl.err" 2>/dev/null)" "check the VPN and that $BASE opens in the browser"
  CODE="$(printf '%s\n' "$meta" | sed -n 1p)"
  CTYPE="$(printf '%s\n' "$meta" | sed -n 2p)"
  REDIR="$(printf '%s\n' "$meta" | sed -n 3p)"
  # What Confluence says is wrong with a query it refused.
  why() { jq -r '.message // .data.errors[0].message.translation // empty' "$ANSWER" 2>/dev/null | head -n 1; }
  case "$CODE" in
    200) ;;
    3??)
      if [[ -n "$REDIR" && "$(host_of "$REDIR")" != "$(host_of "$BASE")" ]]; then
        die 3 "Confluence answered with a redirect to $(host_of "$REDIR"): the instance is behind SSO and the token never reached it" "check that the VPN is up"
      fi
      die 3 "Confluence answered $CODE with a redirect to $REDIR" "check CONFLUENCE_URL, with its context path" ;;
    400) die 3 "Confluence would not take the query: $(why)" "CQL=$CQL" ;;
    401) die 3 "Confluence answered 401 — the token was rejected" \
           "check CONFLUENCE_TOKEN in $(check_where); a token that expired or was revoked has to be created again" ;;
    403) die 3 "Confluence answered 403 — the token's owner may not search" "search in the browser with the same account" ;;
    404) die 3 "Confluence answered 404 — no search API on $BASE" "check that CONFLUENCE_URL points at Confluence Data Center, with its context path" ;;
    *)   die 3 "Confluence answered $CODE: $(why)" ;;
  esac
  case "$CTYPE" in
    application/json*) ;;
    *) die 4 "the answer from $BASE is ${CTYPE:-untyped}, not JSON — that was not the Confluence REST API" \
         "check that CONFLUENCE_URL points at Confluence, with its context path" ;;
  esac
fi
jq -e 'type == "object" and (.results | type == "array")' "$ANSWER" >/dev/null 2>&1 \
  || die 4 "the answer is not a Confluence search result"

# ── The report ────────────────────────────────────────────────────
# The highlight marks are dropped, the excerpt put on one line and cut short:
# it is to tell the pages apart, the page itself is read with confluence-fetch.sh.
LINK_BASE="$(jq -r '._links.base // ""' "$ANSWER")"
LINK_BASE="${LINK_BASE%/}"; [[ -n "$LINK_BASE" ]] || LINK_BASE="$BASE"
TOTAL="$(jq -r '.totalSize // (.results | length)' "$ANSWER")"
SHOWN="$(jq -r '.results | length' "$ANSWER")"
printf 'CONFLUENCE=ok\nCQL=%s\nTOTAL=%s\nSHOWN=%s\n' "$CQL" "$TOTAL" "$SHOWN"
if (( START + SHOWN < TOTAL )); then printf 'NEXT=--start %s\n' "$(( START + SHOWN ))"; fi
printf '\nRESULTS:\n'
jq -r --arg base "$LINK_BASE" --argjson start "$START" '
  def clean: gsub("@@@(end)?hl@@@"; "") | gsub("[\\s ]+"; " ") | sub("^ "; "") | sub(" $"; "")
    | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&quot;"; "\"") | gsub("&#39;"; "'\''") | gsub("&amp;"; "&");
  def short: if length > 240 then .[0:240] | sub(" [^ ]*$"; "") + " …" else . end;
  def space: (.resultGlobalContainer.displayUrl // .url // "") | capture("/(spaces|display)/(?<k>[^/?]+)").k // "";
  .results | to_entries[] | .key as $i | .value |
  ((.content.title // .title // "") | clean) as $title |
  ((.content._links.webui // .url // "") as $u | if $u == "" then "" elif ($u | test("^https?://")) then $u else $base + $u end) as $url |
  ([ (if .content.id then "ID=\(.content.id)" else empty end),
     (space | if . != "" then "SPACE=\(.)" else empty end),
     (if (.content.type // "") != "" and .content.type != "page" then "TYPE=\(.content.type)" else empty end),
     (if .lastModified then "MODIFIED=\(.lastModified[0:10])" else empty end)
   ] | join(" ")) as $meta |
  "\($start + $i + 1). \($title)",
  (if $meta != "" then "   \($meta)" else empty end),
  (if $url != "" then "   \($url)" else empty end),
  ((.excerpt // "") | clean | short | if . != "" then "   \(.)" else empty end),
  ""
' "$ANSWER" | sed '${/^$/d;}'
exit 0
