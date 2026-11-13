#!/usr/bin/env bash
# Publishes to Confluence Data Center: creates a page, replaces a page's body,
# or attaches files — the body written as Markdown and converted to the
# storage format, the local images and files it shows or links uploaded as
# the page's attachments.
#
# Usage: confluence-publish.sh create (--space <KEY|link> | --parent <page>)... [--title <text>] <file.md>
#        confluence-publish.sh update <page> [<file.md>] [--title <text>] [--base-version <n>] [--message <text>]
#        confluence-publish.sh attach <page> <file>...
#        common: [--tokens <file>]... [--yes] [--convert-only]
#
# Without --yes nothing is sent: the run reads what it needs, checks it, and
# prints what --yes would do. Prints KEY=value lines, then ATTACHMENTS: and
# NOTES: blocks. Every failure prints ERROR= and hint: lines on stderr.
# Exit codes:
#   0 — published, or the dry run found nothing in the way
#   1 — the environment is wrong: no curl or jq, no token, no instance URL
#   2 — usage: a wrong argument, a missing file, a reference that cannot be uploaded
#   3 — Confluence refused: HTTP error, SSO redirect, not found, no permission
#   4 — the answer was unusable: not JSON, or the Markdown did not convert
#   5 — conflict: the page changed since --base-version, or the title is taken
#   6 — partly published: something was written before a later step failed;
#       the report on stdout says what was
# Nothing is written to Confluence unless --yes is given.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'EOF'
Usage: confluence-publish.sh <action> [arguments] [options]

  create --space <KEY|link> [--parent <page>] [--title <text>] <file.md>
  create --parent <page> [--title <text>] <file.md>
                     a new page, in the space or under the parent; the title
                     defaults to the file's # title
  update <page> [<file.md>] [--title <text>] [--base-version <n>] [--message <text>]
                     replaces the page's body with the file, and/or its title
  attach <page> <file>...
                     uploads the files as the page's attachments

  <page>             a page link as the browser shows it, or a page id (needs
                     CONFLUENCE_URL)
  <file.md>          the body as Markdown; local images and files it shows or
                     links, by a path relative to the file, are uploaded

  --yes              publish; without it nothing is sent and the run prints what
                     it would do
  --base-version <n> update: the version the edit is based on — VERSION= of the
                     fetch or of the dry run; the update is refused if the page
                     moved on since. Required with --yes
  --message <text>   update: the version comment
  --tokens <file>    a file of KEY=value lines to read the config from; may be
                     given more than once, a later file winning
  --convert-only     convert <file.md> and stop: no config, no request

A dry run of update also writes DIFF=: the page as it is now, read as
Markdown, against the file. It warns when the file was read at an older
version than the page is at (FILE_VERSION=), and when a table loses its
merged cells or changes shape.

Config: CONFLUENCE_URL and CONFLUENCE_TOKEN (a personal access token), read from
the --tokens files; the environment fills in what no file set.
EOF
}

die() {
  local code="$1" msg="$2" hint="${3:-}"
  printf 'ERROR=%s\n' "$msg" >&2
  [[ -n "$hint" ]] && printf 'hint: %s\n' "$hint" >&2
  if (( ${WROTE:-0} )); then
    report partial
    exit 6
  fi
  exit "$code"
}

# ── Arguments ─────────────────────────────────────────────────────
ACTION="${1:-}"
case "$ACTION" in
  create|update|attach) shift ;;
  -h|--help|help) usage; exit 0 ;;
  "") die 2 "no action" "confluence-publish.sh create|update|attach … — see --help" ;;
  *)  die 2 "unknown action: $ACTION" "confluence-publish.sh create|update|attach … — see --help" ;;
esac

TOKEN_FILES=(); N_TF=0
POS=(); N_POS=0
SPACE_ARG=""; PARENT_ARG=""; TITLE_ARG=""; HAVE_TITLE=0; MESSAGE=""
BASE_VERSION=""; YES=0; CONVERT_ONLY=0
need_val() { [[ $# -ge 2 && -n "$2" ]] || die 2 "$1 needs a value" "confluence-publish.sh --help"; }
while (( $# > 0 )); do
  case "$1" in
    --tokens)       need_val "$@"; TOKEN_FILES+=("$2"); N_TF=$(( N_TF + 1 )); shift ;;
    --space)        need_val "$@"; SPACE_ARG="$2"; shift ;;
    --parent)       need_val "$@"; PARENT_ARG="$2"; shift ;;
    --title)        need_val "$@"; TITLE_ARG="$2"; HAVE_TITLE=1; shift ;;
    --message)      need_val "$@"; MESSAGE="$2"; shift ;;
    --base-version) need_val "$@"; BASE_VERSION="$2"; shift ;;
    --yes)          YES=1 ;;
    --convert-only) CONVERT_ONLY=1 ;;
    -h|--help)      usage; exit 0 ;;
    -*)             die 2 "unknown option: $1" "confluence-publish.sh --help" ;;
    *)              POS+=("$1"); N_POS=$(( N_POS + 1 )) ;;
  esac
  shift
done

only_for() {
  local opt="$1" val="$2"; shift 2
  [[ -z "$val" ]] && return 0
  local a; for a in "$@"; do [[ "$ACTION" == "$a" ]] && return 0; done
  die 2 "$opt does not apply to $ACTION" "confluence-publish.sh --help"
}
only_for --space "$SPACE_ARG" create
only_for --parent "$PARENT_ARG" create
(( HAVE_TITLE )) && only_for --title x create update
only_for --message "$MESSAGE" update
only_for --base-version "$BASE_VERSION" update
(( HAVE_TITLE )) && [[ -z "$(printf '%s' "$TITLE_ARG" | tr -d '[:space:]')" ]] && die 2 "--title is empty"
[[ -z "$BASE_VERSION" || "$BASE_VERSION" =~ ^[0-9]+$ ]] || die 2 "--base-version takes a version number: $BASE_VERSION"

TARGET=""; MD_FILE=""; FILES=(); N_FILES=0
case "$ACTION" in
  create)
    (( N_POS == 1 )) || die 2 "create takes the page's Markdown file, and one only" "confluence-publish.sh create --space <KEY> <file.md>"
    MD_FILE="${POS[0]}"
    ;;
  update)
    (( N_POS >= 1 )) || die 2 "no page" "confluence-publish.sh update <page> <file.md>"
    (( N_POS <= 2 )) || die 2 "update takes a page and one Markdown file; got: ${POS[*]}"
    TARGET="${POS[0]}"
    (( N_POS == 2 )) && MD_FILE="${POS[1]}"
    [[ -n "$MD_FILE" ]] || (( HAVE_TITLE )) || (( CONVERT_ONLY )) \
      || die 2 "nothing to update: no Markdown file and no --title" "confluence-publish.sh update <page> <file.md>"
    ;;
  attach)
    (( N_POS >= 2 )) || die 2 "attach needs a page and at least one file" "confluence-publish.sh attach <page> <file>..."
    TARGET="${POS[0]}"
    FILES=("${POS[@]:1}"); N_FILES=$(( N_POS - 1 ))
    (( CONVERT_ONLY )) && die 2 "--convert-only needs a Markdown file to convert; attach has none"
    ;;
esac
if (( CONVERT_ONLY )); then
  [[ -n "$MD_FILE" ]] || die 2 "--convert-only needs a Markdown file"
elif [[ "$ACTION" == update ]] && (( YES )) && [[ -z "$BASE_VERSION" ]]; then
  die 2 "update --yes needs --base-version" \
    "pass the VERSION= of the fetch the edit is based on, or of the dry run when the page was not read first"
fi
if [[ -n "$MD_FILE" ]]; then
  [[ -f "$MD_FILE" && -r "$MD_FILE" ]] || die 2 "cannot read $MD_FILE"
fi

# ── The config ────────────────────────────────────────────────────
# As in confluence-fetch.sh: the files named with --tokens, a later one
# winning, read and never sourced; the environment fills in what no file set.
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

TOKARGS=()
TF_LIST=""
for (( i = 0; i < N_TF; i++ )); do
  conf_load "${TOKEN_FILES[$i]}"
  TOKARGS+=(--tokens "${TOKEN_FILES[$i]}")
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

command -v jq >/dev/null 2>&1 || die 1 "missing: jq" "install jq (macOS: brew install jq)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/confluence-publish.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

NOTES=(); N_NOTE=0
note() { NOTES+=("$1"); N_NOTE=$(( N_NOTE + 1 )); }
note_first() { NOTES=("$1" ${NOTES[@]+"${NOTES[@]}"}); N_NOTE=$(( N_NOTE + 1 )); }

host_of() { printf '%s' "$1" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#[/?#].*$##' -e 's#^[^@]*@##'; }

# ── The Markdown ──────────────────────────────────────────────────
# A leading `# Title` is the page title, not part of the body: create takes
# the title from it, update leaves the title alone unless --title says
# otherwise. When the file is what confluence-fetch.sh wrote — the title, the
# page link, the line of space, path and version — the link and that line go
# too, so a fetched file can be edited and published back as it is.
TITLE=""
FILE_VERSION=""
XML="$TMP/body.xml"
: > "$XML"
UP_PATH=(); UP_NAME=(); N_UP=0

# Prints the Markdown of $1 without its header; the title goes to $2, and
# the version the header names — the one the file was read at — to $3.
split_md() {
  LC_ALL=C awk -v tf="$2" -v vf="$3" '
    { sub(/\r$/, ""); L[++n] = $0 }
    END {
      i = 1
      while (i <= n && L[i] ~ /^[ \t]*$/) i++
      if (i <= n && L[i] ~ /^ ? ? ?# /) {
        t = L[i]; sub(/^ *# +/, "", t); sub(/[ \t]+#+[ \t]*$/, "", t); sub(/[ \t]+$/, "", t)
        printf "%s", t > tf
        i++
        j = i; while (j <= n && L[j] ~ /^[ \t]*$/) j++
        if (j <= n && L[j] ~ /^https?:\/\/[^ \t]+[ \t]*$/ \
            && (L[j + 1] ~ /^(Space|Path|Version): / || L[j] ~ /\/(spaces|pages|display|x)\//)) {
          i = j + 1
          if (i <= n && L[i] ~ /^(Space|Path|Version): /) {
            if (match(L[i], /(^|· )Version: [0-9]+/)) { v = substr(L[i], RSTART, RLENGTH); sub(/.*: /, "", v); printf "%s", v > vf }
            i++
          }
        }
      }
      for (; i <= n; i++) print L[i]
    }
  ' "$1"
}

add_upload() {
  local full="$1" name="$2" k
  case "$name" in
    *'"'*|*'\'*|*$'\n'*) die 2 "cannot upload a file whose name holds a quote, a backslash or a line break: $name" "rename the file" ;;
  esac
  case "$full" in
    *'"'*|*'\'*) die 2 "cannot upload from a path that holds a quote or a backslash: $full" "move or rename the file" ;;
  esac
  for (( k = 0; k < N_UP; k++ )); do
    if [[ "${UP_NAME[$k]}" == "$name" ]]; then
      [[ "${UP_PATH[$k]}" -ef "$full" ]] && return 0
      die 2 "two different files would both be attached as $name: ${UP_PATH[$k]} and $full" "rename one of them"
    fi
  done
  UP_PATH+=("$full"); UP_NAME+=("$name"); N_UP=$(( N_UP + 1 ))
}

if [[ -n "$MD_FILE" ]]; then
  MD_DIR="$(cd "$(dirname "$MD_FILE")" && pwd)"
  split_md "$MD_FILE" "$TMP/title.txt" "$TMP/fversion.txt" > "$TMP/body.md" || die 4 "cannot read $MD_FILE"
  [[ -f "$TMP/title.txt" ]] && TITLE="$(cat "$TMP/title.txt")"
  [[ -f "$TMP/fversion.txt" ]] && FILE_VERSION="$(cat "$TMP/fversion.txt")"

  : > "$TMP/refs.tsv"
  LC_ALL=C awk -v refs="$TMP/refs.tsv" -f "$SCRIPT_DIR/md-to-storage.awk" \
    < "$TMP/body.md" > "$XML" 2> "$TMP/convert.err"
  rc=$?
  if (( rc != 0 )) || [[ -s "$TMP/convert.err" ]]; then
    die 4 "$MD_FILE did not convert (exit $rc): $(tr '\n' ' ' < "$TMP/convert.err")"
  fi
  if LC_ALL=C grep -q '[^[:space:]]' "$TMP/body.md" && ! LC_ALL=C grep -q '[^[:space:]]' "$XML"; then
    die 4 "$MD_FILE holds text but converted to nothing"
  fi
  # Confluence refuses a body that is not well-formed, and says little about
  # where. When xmllint is at hand the body is checked here first.
  if command -v xmllint >/dev/null 2>&1; then
    { printf '<r xmlns:ac="urn:ac" xmlns:ri="urn:ri">'; cat "$XML"; printf '</r>'; } > "$TMP/check.xml"
    xmllint --noout "$TMP/check.xml" 2> "$TMP/xmllint.err" \
      || die 4 "$MD_FILE converted to a body that is not well-formed XML: $(head -n 1 "$TMP/xmllint.err")"
  fi

  # A local reference is uploaded only from inside the folder of the
  # Markdown file. A body can come from anywhere — a fetched page, a file
  # somebody else wrote — and a link to ~/.ssh/id_rsa must not turn into an
  # attachment.
  while IFS=$'\t' read -r kind val; do
    case "$kind" in
      note) note "$val" ;;
      image|file)
        what="links"; [[ "$kind" == image ]] && what="shows"
        if [[ "$val" == /* || "$val" == "~"* ]]; then
          die 2 "$MD_FILE $what $val, an absolute path; only files beside it are uploaded" \
            "copy the file next to $MD_FILE and refer to it by a relative path, or make the link a full URL"
        fi
        case "/$val/" in
          */../*) die 2 "$MD_FILE $what $val, which is outside its folder; only files beside it are uploaded" \
                    "copy the file next to $MD_FILE and refer to it by a relative path, or make the link a full URL" ;;
        esac
        [[ -f "$MD_DIR/$val" ]] || die 2 "$MD_FILE $what $val, which does not exist (relative to $MD_DIR)" \
          "fix the path, make the link a full URL, or remove it"
        add_upload "$MD_DIR/$val" "${val##*/}"
        ;;
    esac
  done < "$TMP/refs.tsv"
fi

for (( k = 0; k < N_FILES; k++ )); do
  f="${FILES[$k]}"
  [[ -f "$f" && -r "$f" ]] || die 2 "cannot read $f"
  add_upload "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" "$(basename "$f")"
done

# Where the converted body is kept for whoever wants to look at it. The
# temporary directory is gone when the script ends; this one stays.
PREVIEW=""
DIFF=""
preview_dir() {
  local d="${TMPDIR:-/tmp}/confluence-publish/$1"
  mkdir -p "$d" 2>/dev/null || die 1 "cannot create $d"
  cat "$XML" > "$d/body.xml" || die 1 "cannot write $d/body.xml"
  PREVIEW="$d/body.xml"
}

# ── The report ────────────────────────────────────────────────────
ID=""; BASE=""; URL=""; PTITLE=""; SKEY=""; VERSION=""; PARENT_ID=""; PARENT_TITLE=""
DONE_UP=(); N_DONE=0
WROTE=0
report() {
  local state="$1" k
  WROTE=0
  printf 'CONFLUENCE=%s\nACTION=%s\nID=%s\nTITLE=%s\nSPACE=%s\n' "$state" "$ACTION" "$ID" "$PTITLE" "$SKEY"
  [[ -n "$PARENT_ID" ]] && printf 'PARENT=%s\n' "$PARENT_ID${PARENT_TITLE:+ ($PARENT_TITLE)}"
  printf 'VERSION=%s\n' "$VERSION"
  [[ "$state" == dry-run && "$ACTION" == update && -n "$FILE_VERSION" ]] && printf 'FILE_VERSION=%s\n' "$FILE_VERSION"
  printf 'URL=%s\n' "$URL"
  [[ -n "$PREVIEW" ]] && printf 'PREVIEW=%s\n' "$PREVIEW"
  [[ -n "$DIFF" ]] && printf 'DIFF=%s\n' "$DIFF"
  printf '\nATTACHMENTS:\n'
  if [[ "$state" == published || "$state" == partial ]]; then
    (( N_DONE > 0 )) && printf '%s\n' "${DONE_UP[@]}"
  else
    for (( k = 0; k < N_UP; k++ )); do printf '%s\n' "${UP_PATH[$k]}"; done
  fi
  printf '\nNOTES:\n'
  (( N_NOTE > 0 )) && printf '%s\n' "${NOTES[@]}"
  return 0
}

if (( CONVERT_ONLY )); then
  preview_dir converted
  printf 'CONFLUENCE=converted\nACTION=%s\nTITLE=%s\nPREVIEW=%s\n' "$ACTION" "$TITLE" "$PREVIEW"
  printf '\nATTACHMENTS:\n'
  for (( k = 0; k < N_UP; k++ )); do printf '%s\n' "${UP_PATH[$k]}"; done
  printf '\nNOTES:\n'
  (( N_NOTE > 0 )) && printf '%s\n' "${NOTES[@]}"
  exit 0
fi

# ── The tools ─────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || die 1 "missing: curl"
[[ -n "$CONFLUENCE_TOKEN" ]] || die 1 "no CONFLUENCE_TOKEN" \
  "create a personal access token in Confluence (profile → Settings → Personal Access Tokens) and $(put_hint 'CONFLUENCE_TOKEN=<token>')"

# ── Requests ──────────────────────────────────────────────────────
# One request with the token. No -L: a redirect is reported, never followed,
# so the token cannot reach a host other than the one the link names. Sets
# CODE, CTYPE and REDIR.
http() {
  local method="$1" url="$2" out="$3" meta; shift 3
  meta="$(curl -sS -X "$method" -o "$out" \
    -w '%{http_code}\n%{content_type}\n%{redirect_url}\n' \
    -H "Authorization: Bearer $CONFLUENCE_TOKEN" \
    -H 'Accept: application/json' \
    "$@" "$url" 2>"$TMP/curl.err")" \
    || die 3 "curl failed: $(head -n 1 "$TMP/curl.err" 2>/dev/null)" "check the VPN and that $BASE opens in the browser"
  CODE="$(printf '%s\n' "$meta" | sed -n 1p)"
  CTYPE="$(printf '%s\n' "$meta" | sed -n 2p)"
  REDIR="$(printf '%s\n' "$meta" | sed -n 3p)"
}

server_says() {
  jq -r '[.message // empty, (.data.errors[]?.message.translation // empty)] | map(select(. != "")) | join("; ")' "$1" 2>/dev/null | head -c 600
}

expect() {
  local what="$1" out="$2" c said; shift 2
  for c in "$@"; do [[ "$CODE" == "$c" ]] && return 0; done
  said="$(server_says "$out")"
  case "$CODE" in
    3??)
      if [[ -n "$REDIR" && "$(host_of "$REDIR")" != "$(host_of "$BASE")" ]]; then
        die 3 "Confluence answered with a redirect to $(host_of "$REDIR"): the instance is behind SSO and the token never reached it" \
          "check that the VPN is up"
      fi
      die 3 "Confluence answered $CODE with a redirect to $REDIR" "check CONFLUENCE_URL or the link: the instance may live under another path" ;;
    400) die 3 "Confluence refused to $what (400)${said:+: $said}" "fix what Confluence names and run again" ;;
    401) die 3 "Confluence answered 401 — the token was rejected" \
           "check CONFLUENCE_TOKEN in $(check_where); a token that expired or was revoked has to be created again" ;;
    403) die 3 "Confluence answered 403 — the token's owner may not $what${said:+: $said}" "check the permission in the browser with the same account" ;;
    404) die 3 "Confluence answered 404 to $what — not found, or no permission to see it${said:+: $said}" "open the link in the browser to check it" ;;
    409) die 5 "Confluence answered 409 to $what — the page changed meanwhile${said:+: $said}" "read the page again, carry the edit over, and publish again" ;;
    *)   die 3 "Confluence answered $CODE to $what${said:+: $said}" ;;
  esac
}

need_json() {
  case "$CTYPE" in
    application/json*) ;;
    *) die 4 "the answer from $BASE is ${CTYPE:-untyped}, not JSON — that was not the Confluence REST API" \
         "check that CONFLUENCE_URL or the link points at Confluence, with its context path" ;;
  esac
  jq -e . "$1" >/dev/null 2>&1 || die 4 "the answer will not parse as JSON"
}

# A page link or id, through confluence-fetch.sh, which owns what a page link
# looks like. A link that names its page by title or by a tiny code is read
# once through the fetch to learn the id. Sets RID and RB.
resolve_page() {
  local arg="$1" out rc kind
  out="$(bash "$SCRIPT_DIR/confluence-fetch.sh" "$arg" --parse-only ${TOKARGS[@]+"${TOKARGS[@]}"})"; rc=$?
  (( rc == 0 )) || exit "$rc"
  kind="$(printf '%s\n' "$out" | sed -n 's/^KIND=//p')"
  RB="$(printf '%s\n' "$out" | sed -n 's/^BASE=//p')"; RB="${RB%/}"
  RID="$(printf '%s\n' "$out" | sed -n 's/^ID=//p')"
  [[ -n "$RB" ]] || die 1 "no CONFLUENCE_URL — a bare page id needs the instance" \
    "$(put_hint 'CONFLUENCE_URL=<base url>'), or pass the page link instead of the id"
  if [[ "$kind" != id ]]; then
    out="$(bash "$SCRIPT_DIR/confluence-fetch.sh" "$arg" --no-attachments --out "$TMP/resolve/page.md" ${TOKARGS[@]+"${TOKARGS[@]}"})"; rc=$?
    (( rc == 0 )) || exit "$rc"
    RID="$(printf '%s\n' "$out" | sed -n 's/^ID=//p')"
  fi
  [[ "$RID" =~ ^[0-9]+$ ]] || die 4 "could not learn the page id of $arg"
}

page_url() {
  local b w
  b="$(jq -r '._links.base // ""' "$1")"; w="$(jq -r '._links.webui // ""' "$1")"
  if [[ -n "$b" && -n "$w" ]]; then printf '%s%s' "${b%/}" "$w"
  else printf '%s/pages/viewpage.action?pageId=%s' "$BASE" "$(jq -r '.id' "$1")"; fi
}

# Another page of that title in the space, other than the one being updated.
title_taken() {
  local title="$1" self="${2:-}"
  http GET "$BASE/rest/api/content" "$TMP/same.json" -G --data-urlencode "spaceKey=$SKEY" \
    --data-urlencode "title=$title" --data-urlencode "type=page"
  expect "look up the title \"$title\" in space $SKEY" "$TMP/same.json" 200
  need_json "$TMP/same.json"
  TAKEN_ID="$(jq -r --arg self "$self" '[.results[]? | select(.id != $self) | .id] | first // empty' "$TMP/same.json")"
  [[ -n "$TAKEN_ID" ]]
}

# ── Existing attachments ──────────────────────────────────────────
# A file whose name and size match an attachment already on the page is the
# same file — typically one confluence-fetch.sh downloaded — and is not
# uploaded again. A file under a name that is taken becomes the attachment's
# next version; a new name, a new attachment.
UP_ATT=()
sift_uploads() {
  local json="$1" k name have size att
  local keep_p=() keep_n=() keep_a=() n=0
  for (( k = 0; k < N_UP; k++ )); do
    name="${UP_NAME[$k]}"
    att="$(jq -r --arg n "$name" '[.results[]? | select(.title == $n) | .id] | first // empty' "$json")"
    have="$(jq -r --arg n "$name" '[.results[]? | select(.title == $n) | .extensions.fileSize] | first // empty' "$json")"
    size="$(wc -c < "${UP_PATH[$k]}" | tr -d ' ')"
    if [[ -n "$att" && "$have" == "$size" ]]; then
      note "\`$name\` is attached already, with the same size; it is not uploaded again."
      continue
    fi
    [[ -n "$att" ]] && note "\`$name\` is attached already, with another size; it is uploaded as its next version."
    keep_p+=("${UP_PATH[$k]}"); keep_n+=("$name"); keep_a+=("${att:--}"); n=$(( n + 1 ))
  done
  UP_PATH=(${keep_p[@]+"${keep_p[@]}"}); UP_NAME=(${keep_n[@]+"${keep_n[@]}"}); UP_ATT=(${keep_a[@]+"${keep_a[@]}"}); N_UP=$n
}

# The media type goes with the file: curl knows only a handful of
# extensions, and an image sent as application/octet-stream is not shown as
# a picture.
mime_of() {
  local ext t
  ext="$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')"
  case "$ext" in
    png) t=image/png ;; jpg|jpeg) t=image/jpeg ;; gif) t=image/gif ;; svg) t=image/svg+xml ;;
    webp) t=image/webp ;; bmp) t=image/bmp ;; pdf) t=application/pdf ;;
    txt|log) t=text/plain ;; md) t=text/markdown ;; csv) t=text/csv ;; html|htm) t=text/html ;;
    json) t=application/json ;; xml) t=application/xml ;; zip) t=application/zip ;;
    docx) t=application/vnd.openxmlformats-officedocument.wordprocessingml.document ;;
    xlsx) t=application/vnd.openxmlformats-officedocument.spreadsheetml.sheet ;;
    pptx) t=application/vnd.openxmlformats-officedocument.presentationml.presentation ;;
    *) t=application/octet-stream ;;
  esac
  printf '%s' "$t"
}

upload_all() {
  local k url
  for (( k = 0; k < N_UP; k++ )); do
    url="$BASE/rest/api/content/$ID/child/attachment"
    [[ "${UP_ATT[$k]:--}" != - ]] && url="$url/${UP_ATT[$k]}/data"
    http POST "$url" "$TMP/att.json" \
      -H 'X-Atlassian-Token: no-check' \
      -F "file=@\"${UP_PATH[$k]}\";filename=\"${UP_NAME[$k]}\";type=$(mime_of "${UP_NAME[$k]}")" \
      -F 'minorEdit=true'
    expect "attach ${UP_NAME[$k]} to page $ID" "$TMP/att.json" 200
    WROTE=1
    DONE_UP+=("${UP_PATH[$k]}"); N_DONE=$(( N_DONE + 1 ))
  done
}

# What the page's current body holds that Markdown has no form for: replacing
# the body replaces it with what the file says.
lost_content() {
  local s="$TMP/storage.xml" list="" m
  jq -r '.body.storage.value // ""' "$1" > "$s"
  for m in $(LC_ALL=C grep -oE '<ac:(structured-)?macro [^>]*ac:name="[^"]*"' "$s" | LC_ALL=C sed 's/.*ac:name="//; s/"$//' \
      | LC_ALL=C grep -vxE 'code|info|tip|note|warning|plantuml' | sort -u); do
    list="${list:+$list, }$m"
  done
  [[ -n "$list" ]] && note "The page holds macros the Markdown cannot: $list. Publishing replaces each with what the file says in its place, which is at best its rendered text."
  LC_ALL=C grep -q '<ac:layout' "$s" && note "The page is laid out in columns or sections; publishing puts everything in one column."
  LC_ALL=C grep -q '<ri:user' "$s" && note "The page mentions people; in the file they are plain text, and publishing keeps them as text."
  LC_ALL=C grep -q '<ac:inline-comment-marker' "$s" && note "The page has inline comments; publishing detaches them from the text they were on."
  return 0
}

# The tables of the page as it is now against the tables of the file, each
# matched by its header, or by its place when both have as many tables.
# Named: merged cells the file cannot hold, which publishing splits; a table
# whose rows or columns change; and a page table whose rows are narrower
# than it is, which the file fills up at the end of the row — a fetched file
# carries such a row's cells a column too far left if they were shifted.
table_shapes() {
  LC_ALL=C awk -f "$SCRIPT_DIR/table-shapes.awk" < "$TMP/storage.xml" > "$TMP/shapes.now"
  LC_ALL=C awk -f "$SCRIPT_DIR/table-shapes.awk" < "$XML" > "$TMP/shapes.file"
  LC_ALL=C awk -F '\t' '
    FILENAME == ARGV[1] { n1++; R1[n1] = $1; C1[n1] = $2; M1[n1] = $3; S1[n1] = $4; H1[n1] = $5; next }
    { n2++; R2[n2] = $1; C2[n2] = $2; M2[n2] = $3; BYH[$5] = ($5 in BYH) ? -1 : n2 }
    END {
      for (i = 1; i <= n1; i++) {
        j = (H1[i] != "" && (H1[i] in BYH) && BYH[H1[i]] > 0) ? BYH[H1[i]] : (n1 == n2 ? i : 0)
        name = "Table " i " of the page" (H1[i] != "" ? " (" H1[i] ")" : "")
        if (j && M1[i] == 1 && M2[j] == 0)
          print name " has merged cells, which Markdown cannot hold: publishing splits them, and the cells they covered stay empty."
        if (j && (R1[i] != R2[j] || C1[i] != C2[j]))
          print name " changes shape: " R1[i] " rows by " C1[i] " columns on the page, " R2[j] " by " C2[j] " in the file. Check that the edit meant to."
        if (S1[i] != "-")
          print name " has rows with fewer cells than it is wide (" (index(S1[i], ",") ? "rows " : "row ") S1[i] ", the header being row 1). A file read from the page fills them up at the end of the row: if their cells sit a column too far left, fix the table in the file before publishing."
      }
    }
  ' "$TMP/shapes.now" "$TMP/shapes.file" > "$TMP/shapes.notes"
  while IFS= read -r line; do [[ -n "$line" ]] && note "$line"; done < "$TMP/shapes.notes"
  return 0
}

# No trailing blanks, one blank line at most, none at either end — outside
# fenced blocks, whose text is the page's own. What confluence-fetch.sh does
# to the file it writes, so a file it wrote compares equal.
md_tidy() {
  LC_ALL=C awk '
    { sub(/\r$/, "") }
    {
      probe = $0; sub(/^[ >]*/, "", probe)
      if (probe ~ /^```/) { fence = !fence; sub(/[[:space:]]+$/, "") }
      else if (!fence) sub(/[[:space:]]+$/, "")
      if ($0 == "" && !fence && probe !~ /^```/) { if (n == 0 || L[n] == "") next }
      L[++n] = $0
    }
    END { while (n > 0 && L[n] == "") n--; for (i = 1; i <= n; i++) print L[i] }
  '
}

# What the update changes, as Markdown: the page as it is now, converted as
# confluence-fetch.sh converts it, against the file. A file
# confluence-fetch.sh wrote compares equal until it is edited, so the diff
# is the edit — and whatever someone else changed on the page since.
diff_current() {
  local cur="$TMP/current" out="$1" add del
  mkdir -p "$cur"
  rm -f "$out"
  if ! bash "$SCRIPT_DIR/confluence-fetch.sh" "$ID" --from-file "$TMP/page.json" --out "$cur/page.md" >/dev/null 2>"$cur/err"; then
    note "The page could not be read as Markdown, so there is no DIFF=: $(sed -n 's/^ERROR=//p' "$cur/err" | head -n 1)"
    return 0
  fi
  split_md "$cur/page.md" /dev/null /dev/null | md_tidy > "$cur/now.md"
  md_tidy < "$TMP/body.md" > "$cur/file.md"
  if diff -u "$cur/now.md" "$cur/file.md" > "$cur/raw.diff"; then
    note "The file reads as the page does now: publishing it changes no text."
    return 0
  fi
  LC_ALL=C awk -v a="page $ID, version $VERSION, as it is now" -v b="$MD_FILE" '
    NR == 1 { print "--- " a; next } NR == 2 { print "+++ " b; next } { print }
  ' "$cur/raw.diff" > "$out" || { note "DIFF= could not be written to $out."; return 0; }
  add="$(LC_ALL=C awk 'NR > 2 && /^\+/ { n++ } END { print n + 0 }' "$cur/raw.diff")"
  del="$(LC_ALL=C awk 'NR > 2 && /^-/ { n++ } END { print n + 0 }' "$cur/raw.diff")"
  DIFF="$out"
  note "Publishing changes the page: $add line(s) in, $del out. DIFF= shows them against the page as it is now."
}

# ── create ────────────────────────────────────────────────────────
if [[ "$ACTION" == create ]]; then
  [[ -n "$SPACE_ARG" || -n "$PARENT_ARG" ]] || die 2 "create needs --space or --parent" \
    "confluence-publish.sh create --space <KEY> <file.md>, or --parent <page link>"

  if [[ -n "$SPACE_ARG" ]]; then
    a="${SPACE_ARG%%#*}"; a="${a%%\?*}"
    if [[ "$a" =~ ^~?[A-Za-z0-9_]+$ ]]; then
      SKEY="$a"; BASE="$CONFLUENCE_URL"
    elif [[ "$a" == http://* || "$a" == https://* ]]; then
      if [[ "$a" == */spaces/* ]]; then BASE="${a%%/spaces/*}"; SKEY="${a#*/spaces/}"
      elif [[ "$a" == */display/* ]]; then BASE="${a%%/display/*}"; SKEY="${a#*/display/}"
      fi
      SKEY="${SKEY%%/*}"
      [[ "$SKEY" =~ ^~?[A-Za-z0-9_]+$ ]] || die 2 "not a space key or a link to a space: $SPACE_ARG" \
        "pass the space key, such as PAY, or the space link (…/spaces/PAY/overview)"
    else
      die 2 "not a space key or a link to a space: $SPACE_ARG" "pass the space key, such as PAY, or the space link (…/spaces/PAY/overview)"
    fi
  fi

  if [[ -n "$PARENT_ARG" ]]; then
    resolve_page "$PARENT_ARG"; PARENT_ID="$RID"
    if [[ -z "$BASE" ]]; then BASE="$RB"
    elif [[ "$(host_of "$RB")" != "$(host_of "$BASE")" ]]; then
      die 2 "the parent is on $(host_of "$RB"), the space on $(host_of "$BASE")" "pass a parent from the same Confluence"
    fi
  fi
  BASE="${BASE%/}"
  [[ -n "$BASE" ]] || die 1 "no CONFLUENCE_URL — a bare space key needs the instance" \
    "$(put_hint 'CONFLUENCE_URL=<base url>'), or pass the space link instead of the key"

  if (( HAVE_TITLE )); then PTITLE="$TITLE_ARG"; else PTITLE="$TITLE"; fi
  [[ -n "$PTITLE" ]] || die 2 "no title: pass --title, or start the file with a # title"

  if [[ -n "$PARENT_ID" ]]; then
    http GET "$BASE/rest/api/content/$PARENT_ID?expand=space" "$TMP/parent.json"
    expect "read the parent page $PARENT_ID" "$TMP/parent.json" 200
    need_json "$TMP/parent.json"
    ps="$(jq -r '.space.key // ""' "$TMP/parent.json")"
    PARENT_TITLE="$(jq -r '.title // ""' "$TMP/parent.json")"
    if [[ -n "$SKEY" && -n "$ps" && "$ps" != "$SKEY" ]]; then
      die 2 "the parent page is in space $ps, not $SKEY" "drop --space, or pick a parent in $SKEY"
    fi
    [[ -n "$SKEY" ]] || SKEY="$ps"
    [[ -n "$SKEY" ]] || die 4 "the parent page answered without its space"
  else
    http GET "$BASE/rest/api/space/$SKEY" "$TMP/space.json"
    expect "read space $SKEY" "$TMP/space.json" 200
    need_json "$TMP/space.json"
    SKEY="$(jq -r --arg k "$SKEY" '.key // $k' "$TMP/space.json")"
  fi

  if title_taken "$PTITLE"; then
    die 5 "space $SKEY already has a page titled \"$PTITLE\" (id $TAKEN_ID)" \
      "update that page instead (confluence-publish.sh update $TAKEN_ID …), or pick another title"
  fi

  preview_dir "$SKEY-new"
  if (( ! YES )); then report dry-run; exit 0; fi

  jq -Rs --arg t "$PTITLE" --arg s "$SKEY" --arg p "$PARENT_ID" '
    { type: "page", title: $t, space: { key: $s },
      body: { storage: { value: ., representation: "storage" } } }
    + (if $p != "" then { ancestors: [ { id: $p } ] } else {} end)' < "$XML" > "$TMP/request.json" \
    || die 4 "could not build the request"
  http POST "$BASE/rest/api/content" "$TMP/created.json" \
    -H 'Content-Type: application/json' --data-binary "@$TMP/request.json"
  expect "create the page \"$PTITLE\" in space $SKEY" "$TMP/created.json" 200
  need_json "$TMP/created.json"
  ID="$(jq -r '.id // ""' "$TMP/created.json")"
  [[ "$ID" =~ ^[0-9]+$ ]] || die 4 "Confluence answered the create without a page id"
  VERSION="$(jq -r '.version.number // 1 | tostring' "$TMP/created.json")"
  URL="$(page_url "$TMP/created.json")"
  WROTE=1
  upload_all
  report published
  exit 0
fi

# ── update, attach ────────────────────────────────────────────────
resolve_page "$TARGET"; ID="$RID"; BASE="$RB"

# The export view only for the diff a dry run of a new body shows.
EXPAND="body.storage,version,space"
[[ "$ACTION" == update && -n "$MD_FILE" ]] && (( ! YES )) && EXPAND="body.storage,body.export_view,version,space"
http GET "$BASE/rest/api/content/$ID?expand=$EXPAND" "$TMP/page.json"
expect "read page $ID" "$TMP/page.json" 200
need_json "$TMP/page.json"
[[ "$(jq -r '.id // ""' "$TMP/page.json")" == "$ID" ]] || die 4 "the answer carries no page $ID — that was not a page"
PTITLE="$(jq -r '.title // ""' "$TMP/page.json")"
SKEY="$(jq -r '.space.key // ""' "$TMP/page.json")"
VERSION="$(jq -r '.version.number // "" | tostring' "$TMP/page.json")"
PTYPE="$(jq -r '.type // "page"' "$TMP/page.json")"
URL="$(page_url "$TMP/page.json")"
[[ "$VERSION" =~ ^[0-9]+$ ]] || die 4 "the answer carries no version of page $ID"

if [[ "$ACTION" == update ]]; then
  if [[ -n "$BASE_VERSION" && "$BASE_VERSION" != "$VERSION" ]]; then
    die 5 "page $ID moved on since version $BASE_VERSION: it is at version $VERSION, by $(jq -r '.version.by.displayName // "someone"' "$TMP/page.json")" \
      "read the page again with confluence-fetch.sh, carry the edit over, and publish again"
  fi
  # The file says which version it was read at. When the page has moved on
  # since, publishing it would take back what changed meanwhile — first
  # thing the user should hear.
  if [[ "$FILE_VERSION" =~ ^[0-9]+$ ]] && (( FILE_VERSION < VERSION )); then
    note_first "The file was read at version $FILE_VERSION; the page is at version $VERSION now, last changed by $(jq -r '.version.by.displayName // "someone"' "$TMP/page.json")$(jq -r '.version.when // "" | if . == "" then "" else ", " + .[0:10] end' "$TMP/page.json"). Publishing the file takes back whatever changed since: read the page again, carry the edit over, and dry-run again."
  fi
  NEW_TITLE="$PTITLE"
  if (( HAVE_TITLE )) && [[ "$TITLE_ARG" != "$PTITLE" ]]; then
    if title_taken "$TITLE_ARG" "$ID"; then
      die 5 "space $SKEY already has another page titled \"$TITLE_ARG\" (id $TAKEN_ID)" "pick another title"
    fi
    note "The title changes from \"$PTITLE\"."
    NEW_TITLE="$TITLE_ARG"
  elif [[ -n "$TITLE" && "$TITLE" != "$PTITLE" ]] && (( ! HAVE_TITLE )); then
    note "The file's title differs from the page's; the title was left as it is. Pass --title to change it."
  fi
  if [[ -n "$MD_FILE" ]]; then
    LC_ALL=C grep -q '[^[:space:]]' "$XML" || die 2 "$MD_FILE holds no body; publishing it would empty the page" \
      "write the page's text into the file"
    lost_content "$TMP/page.json"
    table_shapes
    preview_dir "$ID"
    (( YES )) || diff_current "$(dirname "$PREVIEW")/body.diff"
  else
    jq -r '.body.storage.value // ""' "$TMP/page.json" > "$XML"
  fi
  PTITLE="$NEW_TITLE"
fi

http GET "$BASE/rest/api/content/$ID/child/attachment?limit=200" "$TMP/attachments.json"
expect "list the attachments of page $ID" "$TMP/attachments.json" 200
need_json "$TMP/attachments.json"
sift_uploads "$TMP/attachments.json"

if (( ! YES )); then report dry-run; exit 0; fi

# The files go first, so the body never shows an attachment that is not
# there yet.
upload_all

if [[ "$ACTION" == update ]]; then
  jq -Rs --arg id "$ID" --arg type "$PTYPE" --arg t "$PTITLE" --arg s "$SKEY" \
     --argjson v "$(( VERSION + 1 ))" --arg m "$MESSAGE" '
    { id: $id, type: $type, title: $t, space: { key: $s },
      version: ({ number: $v } + (if $m != "" then { message: $m } else {} end)),
      body: { storage: { value: ., representation: "storage" } } }' < "$XML" > "$TMP/request.json" \
    || die 4 "could not build the request"
  http PUT "$BASE/rest/api/content/$ID" "$TMP/put.json" \
    -H 'Content-Type: application/json' --data-binary "@$TMP/request.json"
  expect "update page $ID" "$TMP/put.json" 200
  WROTE=1
  VERSION="$(jq -r --arg v "$(( VERSION + 1 ))" '.version.number // $v | tostring' "$TMP/put.json" 2>/dev/null)"
  [[ -n "$VERSION" ]] || VERSION="?"
  [[ -n "$(jq -r '._links.webui // ""' "$TMP/put.json" 2>/dev/null)" ]] && URL="$(page_url "$TMP/put.json")"
fi

report published
exit 0
