#!/usr/bin/env bash
# Publishes to Jira Server / Data Center: creates an issue, replaces an
# issue's description, or attaches files — the description written as
# Markdown and converted to wiki markup, the local images and files it shows
# or links uploaded as attachments.
#
# Usage: jira-publish.sh create --project <KEY|link> --type <name> [--summary <text>]
#                               [--parent <issue>] [--label <label>]... [<file.md>]
#        jira-publish.sh update <issue> [<file.md>] [--summary <text>] [--base-updated <ts>]
#        jira-publish.sh attach <issue> <file>...
#        common: [--tokens <file>]... [--yes] [--convert-only]
#
# Without --yes nothing is sent: the run reads what it needs, checks it, and
# prints what --yes would do. Prints KEY=value lines, then ATTACHMENTS: and
# NOTES: blocks. Every failure prints ERROR= and hint: lines on stderr.
# Exit codes:
#   0 — published, or the dry run found nothing in the way
#   1 — the environment is wrong: no curl or jq, no token, no instance URL
#   2 — usage: a wrong argument, a missing file, a reference that cannot be uploaded
#   3 — Jira refused: HTTP error, SSO redirect, not found, no permission, invalid field
#   4 — the answer was unusable: not JSON, or the Markdown did not convert
#   5 — conflict: the issue changed since --base-updated
#   6 — partly published: something was written before a later step failed;
#       the report on stdout says what was
# Nothing is written to Jira unless --yes is given.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'EOF'
Usage: jira-publish.sh <action> [arguments] [options]

  create --project <KEY|link> --type <name> [<file.md>]
         [--summary <text>] [--parent <issue>] [--label <label>]...
                     a new issue; the summary defaults to the file's # title
  update <issue> [<file.md>] [--summary <text>] [--base-updated <ts>]
                     replaces the description with the file, and/or the summary
  attach <issue> <file>...
                     uploads the files as attachments

  <issue>            an issue link as the browser shows it, or a key (needs JIRA_URL)
  <file.md>          the description as Markdown; local images and files it shows
                     or links, by a path relative to the file, are uploaded

  --yes              publish; without it nothing is sent and the run prints what
                     it would do
  --base-updated <ts> update: the UPDATED= value the dry run printed; the update is
                     refused if the issue changed since. Required with --yes when
                     the description or the summary changes
  --tokens <file>    a file of KEY=value lines to read the config from; may be
                     given more than once, a later file winning
  --convert-only     convert <file.md> and stop: no config, no request

A dry run of update also writes DIFF=: the description as it is now, read
as Markdown, against the file. Each @name is looked up; a name no Jira user
has is published as text, not as a mention.

Config: JIRA_URL and JIRA_TOKEN (a personal access token), read from the
--tokens files; the environment fills in what no file set.
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
  "") die 2 "no action" "jira-publish.sh create|update|attach … — see --help" ;;
  *)  die 2 "unknown action: $ACTION" "jira-publish.sh create|update|attach … — see --help" ;;
esac

TOKEN_FILES=(); N_TF=0
POS=(); N_POS=0
LABELS=(); N_LABEL=0
PROJECT_ARG=""; TYPE_ARG=""; SUMMARY_ARG=""; HAVE_SUMMARY=0; PARENT_ARG=""
BASE_UPDATED=""; YES=0; CONVERT_ONLY=0
need_val() { [[ $# -ge 2 && -n "$2" ]] || die 2 "$1 needs a value" "jira-publish.sh --help"; }
while (( $# > 0 )); do
  case "$1" in
    --tokens)       need_val "$@"; TOKEN_FILES+=("$2"); N_TF=$(( N_TF + 1 )); shift ;;
    --project)      need_val "$@"; PROJECT_ARG="$2"; shift ;;
    --type)         need_val "$@"; TYPE_ARG="$2"; shift ;;
    --summary)      need_val "$@"; SUMMARY_ARG="$2"; HAVE_SUMMARY=1; shift ;;
    --parent)       need_val "$@"; PARENT_ARG="$2"; shift ;;
    --label)        need_val "$@"; LABELS+=("$2"); N_LABEL=$(( N_LABEL + 1 )); shift ;;
    --base-updated) need_val "$@"; BASE_UPDATED="$2"; shift ;;
    --yes)          YES=1 ;;
    --convert-only) CONVERT_ONLY=1 ;;
    -h|--help)      usage; exit 0 ;;
    -*)             die 2 "unknown option: $1" "jira-publish.sh --help" ;;
    *)              POS+=("$1"); N_POS=$(( N_POS + 1 )) ;;
  esac
  shift
done

only_for() {
  local opt="$1" val="$2"; shift 2
  [[ -z "$val" ]] && return 0
  local a; for a in "$@"; do [[ "$ACTION" == "$a" ]] && return 0; done
  die 2 "$opt does not apply to $ACTION" "jira-publish.sh --help"
}
only_for --project "$PROJECT_ARG" create
only_for --type "$TYPE_ARG" create
only_for --parent "$PARENT_ARG" create
(( N_LABEL > 0 )) && only_for --label x create
(( HAVE_SUMMARY )) && only_for --summary x create update
only_for --base-updated "$BASE_UPDATED" update
(( HAVE_SUMMARY )) && [[ -z "$(printf '%s' "$SUMMARY_ARG" | tr -d '[:space:]')" ]] && die 2 "--summary is empty"

TARGET=""; MD_FILE=""; FILES=(); N_FILES=0
case "$ACTION" in
  create)
    (( N_POS <= 1 )) || die 2 "create takes one Markdown file; got: ${POS[*]}"
    (( N_POS == 1 )) && MD_FILE="${POS[0]}"
    ;;
  update)
    (( N_POS >= 1 )) || die 2 "no issue" "jira-publish.sh update <issue> [<file.md>] [--summary <text>]"
    (( N_POS <= 2 )) || die 2 "update takes an issue and one Markdown file; got: ${POS[*]}"
    TARGET="${POS[0]}"
    (( N_POS == 2 )) && MD_FILE="${POS[1]}"
    [[ -n "$MD_FILE" ]] || (( HAVE_SUMMARY )) || (( CONVERT_ONLY )) \
      || die 2 "nothing to update: no Markdown file and no --summary" "jira-publish.sh update <issue> <file.md>"
    ;;
  attach)
    (( N_POS >= 2 )) || die 2 "attach needs an issue and at least one file" "jira-publish.sh attach <issue> <file>..."
    TARGET="${POS[0]}"
    FILES=("${POS[@]:1}"); N_FILES=$(( N_POS - 1 ))
    (( CONVERT_ONLY )) && die 2 "--convert-only needs a Markdown file to convert; attach has none"
    ;;
esac
if (( CONVERT_ONLY )); then
  [[ -n "$MD_FILE" ]] || die 2 "--convert-only needs a Markdown file"
elif [[ "$ACTION" == update ]] && (( YES )) && [[ -z "$BASE_UPDATED" ]]; then
  die 2 "update --yes needs --base-updated" "run without --yes first and pass the UPDATED= value it prints"
fi
if [[ -n "$MD_FILE" ]]; then
  [[ -f "$MD_FILE" && -r "$MD_FILE" ]] || die 2 "cannot read $MD_FILE"
fi

# ── The config ────────────────────────────────────────────────────
# As in jira-fetch.sh: the files named with --tokens, a later one winning,
# read and never sourced; the environment fills in what no file set.
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
      if (key !~ /^JIRA_(URL|TOKEN)$/) next
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
      JIRA_URL)   URL_CFG="$val" ;;
      JIRA_TOKEN) TOKEN_CFG="$val" ;;
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
JIRA_URL="${URL_CFG:-${JIRA_URL:-}}"
JIRA_TOKEN="${TOKEN_CFG:-${JIRA_TOKEN:-}}"
JIRA_URL="${JIRA_URL%/}"

put_hint() {
  if (( N_TF > 0 )); then printf 'put %s in %s' "$1" "$TF_LIST"
  else printf 'put %s in a tokens file and pass it with --tokens <file> (none was passed), or set it in the environment' "$1"; fi
}
check_where() {
  if (( N_TF > 0 )); then printf '%s' "$TF_LIST"; else printf 'the environment'; fi
}

command -v jq >/dev/null 2>&1 || die 1 "missing: jq" "install jq (macOS: brew install jq)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/jira-publish.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

NOTES=(); N_NOTE=0
note() { NOTES+=("$1"); N_NOTE=$(( N_NOTE + 1 )); }
note_first() { NOTES=("$1" ${NOTES[@]+"${NOTES[@]}"}); N_NOTE=$(( N_NOTE + 1 )); }

host_of() { printf '%s' "$1" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#[/?#].*$##' -e 's#^[^@]*@##'; }

# ── The Markdown ──────────────────────────────────────────────────
# A leading `# Title` is the title, not part of the description: create takes
# the summary from it, update leaves the summary alone unless --summary says
# otherwise. When the file is what jira-fetch.sh wrote — the title, the issue
# link, the line of type and status — the link and that line go too, so a
# fetched file can be edited and published back as it is.
TITLE=""
FILE_UPDATED=""
WIKI="$TMP/description.wiki"
: > "$WIKI"
UP_PATH=(); UP_NAME=(); N_UP=0
MENTIONS=""

# Prints the Markdown of $1 without its header; the title goes to $2, and
# the last update the header names — when the file was read — to $3.
split_md() {
  LC_ALL=C awk -v tf="$2" -v uf="${3:-/dev/null}" '
    { sub(/\r$/, ""); L[++n] = $0 }
    END {
      i = 1
      while (i <= n && L[i] ~ /^[ \t]*$/) i++
      if (i <= n && L[i] ~ /^ ? ? ?# /) {
        t = L[i]; sub(/^ *# +/, "", t); sub(/[ \t]+#+[ \t]*$/, "", t); sub(/[ \t]+$/, "", t)
        printf "%s", t > tf
        i++
        j = i; while (j <= n && L[j] ~ /^[ \t]*$/) j++
        if (j <= n && L[j] ~ /^https?:\/\/[^ \t]+\/browse\/[A-Z][A-Z0-9_]*-[0-9]+[ \t]*$/) {
          i = j + 1
          if (i <= n && L[i] ~ /^(Type|Status|Priority|Assignee|Updated): /) {
            if (match(L[i], /(^|· )Updated: [^·]+$/)) { u = substr(L[i], RSTART, RLENGTH); sub(/.*Updated: /, "", u); sub(/[ \t]+$/, "", u); printf "%s", u > uf }
            i++
          }
        }
      }
      for (; i <= n; i++) print L[i]
    }
  ' "$1"
}

# $TMP/body.md to $WIKI, the side facts to the refs file $1. $2, when given,
# lists the names that stay text rather than become mentions.
convert_md() {
  : > "$1"
  LC_ALL=C awk -v refs="$1" -v plain="${2:-}" -f "$SCRIPT_DIR/md-to-wiki.awk" \
    < "$TMP/body.md" > "$WIKI" 2> "$TMP/convert.err"
  rc=$?
  if (( rc != 0 )) || [[ -s "$TMP/convert.err" ]]; then
    die 4 "$MD_FILE did not convert (exit $rc): $(tr '\n' ' ' < "$TMP/convert.err")"
  fi
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
  split_md "$MD_FILE" "$TMP/title.txt" "$TMP/fupdated.txt" > "$TMP/body.md" || die 4 "cannot read $MD_FILE"
  [[ -f "$TMP/title.txt" ]] && TITLE="$(cat "$TMP/title.txt")"
  [[ -f "$TMP/fupdated.txt" ]] && FILE_UPDATED="$(cat "$TMP/fupdated.txt")"

  convert_md "$TMP/refs.tsv"
  if LC_ALL=C grep -q '[^[:space:]]' "$TMP/body.md" && ! LC_ALL=C grep -q '[^[:space:]]' "$WIKI"; then
    die 4 "$MD_FILE holds text but converted to nothing"
  fi

  # A local reference is uploaded only from inside the folder of the
  # Markdown file. A description can come from anywhere — a fetched issue, a
  # page somebody else wrote — and a link to ~/.ssh/id_rsa must not turn
  # into an attachment.
  while IFS=$'\t' read -r kind val; do
    case "$kind" in
      note) note "$val" ;;
      mention)
        case " $MENTIONS " in *" $val "*) ;; *) MENTIONS="${MENTIONS:+$MENTIONS }$val" ;; esac ;;
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

# Where the converted markup is kept for whoever wants to look at it. The
# temporary directory is gone when the script ends; this one stays.
preview_dir() {
  local d="${TMPDIR:-/tmp}/jira-publish/$1"
  mkdir -p "$d" 2>/dev/null || die 1 "cannot create $d"
  cat "$WIKI" > "$d/description.wiki" || die 1 "cannot write $d/description.wiki"
  PREVIEW="$d/description.wiki"
}
PREVIEW=""
DIFF=""

# [~a], [~b] — the names as the wiki markup writes them.
mention_list() {
  local r="" m
  for m in "$@"; do r="${r:+$r, }[~$m]"; done
  printf '%s' "$r"
}

# ── The report ────────────────────────────────────────────────────
KEY=""; BASE=""; URL=""; SUMMARY=""; CUR_UPDATED=""; PKEY=""; ITYPE=""; PARENT_KEY=""
DONE_UP=(); N_DONE=0
WROTE=0
report() {
  local state="$1" k
  WROTE=0
  printf 'JIRA=%s\nACTION=%s\n' "$state" "$ACTION"
  [[ "$ACTION" == create ]] && printf 'PROJECT=%s\nTYPE=%s\n' "$PKEY" "$ITYPE"
  [[ -n "$PARENT_KEY" ]] && printf 'PARENT=%s\n' "$PARENT_KEY"
  printf 'KEY=%s\nSUMMARY=%s\nURL=%s\n' "$KEY" "$SUMMARY" "$URL"
  [[ "$state" == dry-run && "$ACTION" != create ]] && printf 'UPDATED=%s\n' "$CUR_UPDATED"
  [[ "$state" == dry-run && "$ACTION" == update && -n "$FILE_UPDATED" ]] && printf 'FILE_UPDATED=%s\n' "$FILE_UPDATED"
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
  [[ -n "$MENTIONS" ]] && note "The description mentions $(mention_list $MENTIONS); Jira notifies them. Not checked: --convert-only makes no request."
  preview_dir converted
  printf 'JIRA=converted\nACTION=%s\nTITLE=%s\nPREVIEW=%s\n' "$ACTION" "$TITLE" "$PREVIEW"
  printf '\nATTACHMENTS:\n'
  for (( k = 0; k < N_UP; k++ )); do printf '%s\n' "${UP_PATH[$k]}"; done
  printf '\nNOTES:\n'
  (( N_NOTE > 0 )) && printf '%s\n' "${NOTES[@]}"
  exit 0
fi

# ── The tools ─────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || die 1 "missing: curl"
[[ -n "$JIRA_TOKEN" ]] || die 1 "no JIRA_TOKEN" \
  "create a personal access token in Jira (profile → Personal Access Tokens) and $(put_hint 'JIRA_TOKEN=<token>')"

# ── Requests ──────────────────────────────────────────────────────
# One request with the token. No -L: a redirect is reported, never followed,
# so the token cannot reach a host other than the one the link names. Sets
# CODE, CTYPE and REDIR.
http() {
  local method="$1" url="$2" out="$3" meta; shift 3
  meta="$(curl -sS -X "$method" -o "$out" \
    -w '%{http_code}\n%{content_type}\n%{redirect_url}\n' \
    -H "Authorization: Bearer $JIRA_TOKEN" \
    -H 'Accept: application/json' \
    "$@" "$url" 2>"$TMP/curl.err")" \
    || die 3 "curl failed: $(head -n 1 "$TMP/curl.err" 2>/dev/null)" "check the VPN and that $BASE opens in the browser"
  CODE="$(printf '%s\n' "$meta" | sed -n 1p)"
  CTYPE="$(printf '%s\n' "$meta" | sed -n 2p)"
  REDIR="$(printf '%s\n' "$meta" | sed -n 3p)"
}

# What Jira said about a refusal, in its own words.
server_says() {
  jq -r '([.errorMessages[]?] + [(.errors // {}) | to_entries[]? | "\(.key): \(.value)"] + [.message // empty])
         | map(select(. != "")) | join("; ")' "$1" 2>/dev/null | head -c 600
}

# Accepts the codes given, refuses anything else in words a person can act on.
expect() {
  local what="$1" out="$2" c said; shift 2
  for c in "$@"; do [[ "$CODE" == "$c" ]] && return 0; done
  said="$(server_says "$out")"
  case "$CODE" in
    3??)
      if [[ -n "$REDIR" && "$(host_of "$REDIR")" != "$(host_of "$BASE")" ]]; then
        die 3 "Jira answered with a redirect to $(host_of "$REDIR"): the instance is behind SSO and the token never reached it" \
          "check that the VPN is up"
      fi
      die 3 "Jira answered $CODE with a redirect to $REDIR" "check JIRA_URL or the link: the instance may live under another path" ;;
    400) die 3 "Jira refused to $what (400)${said:+: $said}" "fix what Jira names and run again" ;;
    401) die 3 "Jira answered 401 — the token was rejected" \
           "check JIRA_TOKEN in $(check_where); a token that expired or was revoked has to be created again" ;;
    403) die 3 "Jira answered 403 — the token's owner may not $what${said:+: $said}" "check the permission in the browser with the same account" ;;
    404) die 3 "Jira answered 404 to $what — not found, or no permission to see it${said:+: $said}" "open the link in the browser to check it" ;;
    *)   die 3 "Jira answered $CODE to $what${said:+: $said}" ;;
  esac
}

need_json() {
  case "$CTYPE" in
    application/json*) ;;
    *) die 4 "the answer from $BASE is ${CTYPE:-untyped}, not JSON — that was not the Jira REST API" \
         "check that JIRA_URL or the link points at Jira, with its context path" ;;
  esac
  jq -e . "$1" >/dev/null 2>&1 || die 4 "the answer will not parse as JSON"
}

# An issue link or key, through jira-fetch.sh, which owns what an issue link
# looks like. Sets PK and PB.
parse_issue() {
  local out rc
  out="$(bash "$SCRIPT_DIR/jira-fetch.sh" "$1" --parse-only ${TOKARGS[@]+"${TOKARGS[@]}"})"; rc=$?
  (( rc == 0 )) || exit "$rc"
  PK="$(printf '%s\n' "$out" | sed -n 's/^KEY=//p')"
  PB="$(printf '%s\n' "$out" | sed -n 's/^BASE=//p')"
}

# ── Existing attachments ──────────────────────────────────────────
# A file whose name and size match an attachment already on the issue is the
# same file — typically one jira-fetch.sh downloaded — and is not uploaded a
# second time. Anything else is uploaded; under a name that is taken, Jira
# keeps both and the description shows the newest.
sift_uploads() {
  local json="$1" k name have size
  local keep_p=() keep_n=() n=0
  for (( k = 0; k < N_UP; k++ )); do
    name="${UP_NAME[$k]}"
    have="$(jq -r --arg n "$name" '[.fields.attachment[]? | select(.filename == $n) | .size] | last // empty' "$json")"
    size="$(wc -c < "${UP_PATH[$k]}" | tr -d ' ')"
    if [[ -n "$have" && "$have" == "$size" ]]; then
      note "\`$name\` is attached already, with the same size; it is not uploaded again."
      continue
    fi
    [[ -n "$have" ]] && note "\`$name\` is attached already, with another size; a new copy is uploaded and the description shows the newest."
    keep_p+=("${UP_PATH[$k]}"); keep_n+=("$name"); n=$(( n + 1 ))
  done
  UP_PATH=(${keep_p[@]+"${keep_p[@]}"}); UP_NAME=(${keep_n[@]+"${keep_n[@]}"}); N_UP=$n
}

# The media type goes with the file: curl knows only a handful of
# extensions, and an image sent as application/octet-stream is shown as a
# file to download rather than as a picture.
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
  local k
  for (( k = 0; k < N_UP; k++ )); do
    http POST "$BASE/rest/api/2/issue/$KEY/attachments" "$TMP/att.json" \
      -H 'X-Atlassian-Token: no-check' \
      -F "file=@\"${UP_PATH[$k]}\";filename=\"${UP_NAME[$k]}\";type=$(mime_of "${UP_NAME[$k]}")"
    expect "attach ${UP_NAME[$k]} to $KEY" "$TMP/att.json" 200
    WROTE=1
    DONE_UP+=("${UP_PATH[$k]}"); N_DONE=$(( N_DONE + 1 ))
  done
}

# The wiki macros the current description holds that Markdown has no form
# for: replacing the description replaces them with what the file says.
lost_macros() {
  local list="" m
  for m in $(jq -r '.fields.description // ""' "$1" | LC_ALL=C grep -o '{[a-z][a-z]*[:}]' \
      | LC_ALL=C sed 's/^{//; s/[:}]$//' | LC_ALL=C grep -vxE 'code|noformat|quote|info|tip|note|warning' | sort -u); do
    list="${list:+$list, }{$m}"
  done
  [[ -n "$list" ]] && note "The current description uses $list, which Markdown cannot hold; publishing replaces them with the file's text."
  return 0
}

# Every @name is looked up before it goes out as a mention. A name no Jira
# user has — an annotation such as @Version, a handle mistyped — stays text,
# and the file is converted again to say so: only a user Jira knows is
# mentioned, and so notified.
check_mentions() {
  local m dn code known="" plain="" unsure=""
  [[ -n "$MENTIONS" ]] || return 0
  : > "$TMP/plain.txt"
  for m in $MENTIONS; do
    http GET "$BASE/rest/api/2/user" "$TMP/user.json" -G --data-urlencode "username=$m"
    if [[ "$CODE" == 200 ]] && jq -e 'type == "object" and (has("name") or has("key"))' "$TMP/user.json" >/dev/null 2>&1; then
      dn="$(jq -r '(.displayName // "") + (if .active == false then ", inactive" else "" end)' "$TMP/user.json")"
      known="${known:+$known, }[~$m]${dn:+ ($dn)}"
    elif [[ "$CODE" == 404 ]]; then
      printf '%s\n' "$m" >> "$TMP/plain.txt"
      plain="${plain:+$plain, }@$m"
    else
      code="$CODE"; unsure="${unsure:+$unsure, }[~$m]"
    fi
  done
  if [[ -n "$plain" ]]; then
    convert_md "$TMP/refs.again.tsv" "$TMP/plain.txt"
    note "No Jira user is called $plain: published as text, not as a mention. In the file, \\@name or \`@name\` says so."
  fi
  [[ -n "$known" ]] && note "The description mentions $known; Jira notifies them."
  [[ -n "$unsure" ]] && note "The description mentions $unsure; Jira notifies them. The user lookup answered $code, so the name was not checked."
  return 0
}

# No trailing blanks, one blank line at most, none at either end — outside
# fenced blocks, whose text is the issue's own. What jira-fetch.sh does to
# the file it writes, so a file it wrote compares equal.
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

# What the update changes, as Markdown: the description the issue has now,
# converted as jira-fetch.sh converts it, against the file. A file
# jira-fetch.sh wrote compares equal until it is edited, so the diff is the
# edit — and whatever someone else changed on the issue since it was read.
diff_current() {
  local cur="$TMP/current" out="$1" add del
  mkdir -p "$cur"
  rm -f "$out"
  if ! bash "$SCRIPT_DIR/jira-fetch.sh" "$URL" --from-file "$TMP/issue.json" --out "$cur/issue.md" >/dev/null 2>"$cur/err"; then
    note "The current description could not be read as Markdown, so there is no DIFF=: $(sed -n 's/^ERROR=//p' "$cur/err" | head -n 1)"
    return 0
  fi
  split_md "$cur/issue.md" /dev/null | md_tidy > "$cur/now.md"
  md_tidy < "$TMP/body.md" > "$cur/file.md"
  if diff -u "$cur/now.md" "$cur/file.md" > "$cur/raw.diff"; then
    note "The file's description reads as the issue's does now: publishing it changes no text."
    return 0
  fi
  LC_ALL=C awk -v a="$KEY, as it is now (updated $CUR_UPDATED)" -v b="$MD_FILE" '
    NR == 1 { print "--- " a; next } NR == 2 { print "+++ " b; next } { print }
  ' "$cur/raw.diff" > "$out" || { note "DIFF= could not be written to $out."; return 0; }
  add="$(LC_ALL=C awk 'NR > 2 && /^\+/ { n++ } END { print n + 0 }' "$cur/raw.diff")"
  del="$(LC_ALL=C awk 'NR > 2 && /^-/ { n++ } END { print n + 0 }' "$cur/raw.diff")"
  DIFF="$out"
  note "Publishing changes the description: $add line(s) in, $del out. DIFF= shows them against the description the issue has now."
}

# ── create ────────────────────────────────────────────────────────
if [[ "$ACTION" == create ]]; then
  [[ -n "$PROJECT_ARG" ]] || die 2 "create needs --project" "jira-publish.sh create --project <KEY> --type <name> <file.md>"
  [[ -n "$TYPE_ARG" ]] || die 2 "create needs --type, such as Story, Task or Bug" "jira-publish.sh create --project <KEY> --type <name> <file.md>"

  a="${PROJECT_ARG%%#*}"; a="${a%%\?*}"
  if [[ "$a" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    PKEY="$a"; BASE="$JIRA_URL"
  elif [[ "$a" == http://* || "$a" == https://* ]]; then
    if [[ "$a" == */projects/* ]]; then BASE="${a%%/projects/*}"; PKEY="${a#*/projects/}"
    elif [[ "$a" == */browse/* ]]; then BASE="${a%%/browse/*}"; PKEY="${a#*/browse/}"
    fi
    PKEY="${PKEY%%/*}"
    [[ "$PKEY" =~ ^[A-Z][A-Z0-9_]*$ ]] || die 2 "not a project key or a link to a project: $PROJECT_ARG" \
      "pass the project key, such as ABC, or the project link (…/projects/ABC)"
  else
    die 2 "not a project key or a link to a project: $PROJECT_ARG" "pass the project key, such as ABC, or the project link (…/projects/ABC)"
  fi

  if [[ -n "$PARENT_ARG" ]]; then
    parse_issue "$PARENT_ARG"; PARENT_KEY="$PK"
    if [[ -z "$BASE" ]]; then BASE="$PB"
    elif [[ -n "$PB" && "$(host_of "$PB")" != "$(host_of "$BASE")" ]]; then
      die 2 "the parent $PARENT_KEY is on $(host_of "$PB"), the project on $(host_of "$BASE")" "pass a parent from the same Jira"
    fi
  fi
  BASE="${BASE%/}"
  [[ -n "$BASE" ]] || die 1 "no JIRA_URL — a bare project key needs the instance" \
    "$(put_hint 'JIRA_URL=<base url>'), or pass the project link instead of the key"

  if (( HAVE_SUMMARY )); then SUMMARY="$SUMMARY_ARG"
  else
    SUMMARY="$TITLE"
    # The title of a file jira-fetch.sh wrote carries the old key in front.
    SUMMARY="$(printf '%s' "$SUMMARY" | LC_ALL=C sed -E 's/^[A-Z][A-Z0-9_]*-[0-9]+ (—|-|:) //')"
  fi
  [[ -n "$SUMMARY" ]] || die 2 "no summary: pass --summary, or start the file with a # title"
  [[ -n "$MD_FILE" ]] || note "No Markdown file: the issue is created without a description."

  http GET "$BASE/rest/api/2/project/$PKEY" "$TMP/project.json"
  expect "read project $PKEY" "$TMP/project.json" 200
  need_json "$TMP/project.json"
  ITYPE="$(jq -r --arg t "$TYPE_ARG" '[.issueTypes[]? | select((.name | ascii_downcase) == ($t | ascii_downcase)) | .name] | first // empty' "$TMP/project.json")"
  if [[ -z "$ITYPE" ]]; then
    die 2 "project $PKEY has no issue type \"$TYPE_ARG\"" \
      "pick one of: $(jq -r '[.issueTypes[]?.name] | join(", ")' "$TMP/project.json")"
  fi
  SUBTASK="$(jq -r --arg t "$ITYPE" '[.issueTypes[]? | select(.name == $t) | .subtask] | first // false' "$TMP/project.json")"
  if [[ "$SUBTASK" == true && -z "$PARENT_KEY" ]]; then
    die 2 "$ITYPE is a sub-task type and needs --parent <issue>"
  fi
  if [[ "$SUBTASK" != true && -n "$PARENT_KEY" ]]; then
    die 2 "--parent makes a sub-task, and $ITYPE is not a sub-task type" \
      "pick one of: $(jq -r '[.issueTypes[]? | select(.subtask == true) | .name] | join(", ")' "$TMP/project.json")"
  fi
  if [[ -n "$PARENT_KEY" ]]; then
    http GET "$BASE/rest/api/2/issue/$PARENT_KEY?fields=project,summary" "$TMP/parent.json"
    expect "read the parent $PARENT_KEY" "$TMP/parent.json" 200
    need_json "$TMP/parent.json"
    pp="$(jq -r '.fields.project.key // ""' "$TMP/parent.json")"
    [[ -z "$pp" || "$pp" == "$PKEY" ]] || die 2 "the parent $PARENT_KEY is in project $pp, not $PKEY" "a sub-task lives in its parent's project"
    PARENT_KEY="$(jq -r --arg k "$PARENT_KEY" '.key // $k' "$TMP/parent.json")"
  fi

  check_mentions
  [[ -n "$MD_FILE" ]] && preview_dir "$PKEY-new"
  if (( ! YES )); then report dry-run; exit 0; fi

  LABELS_TXT=""
  (( N_LABEL > 0 )) && LABELS_TXT="$(printf '%s\n' "${LABELS[@]}")"
  jq -Rs --arg p "$PKEY" --arg t "$ITYPE" --arg s "$SUMMARY" --arg parent "$PARENT_KEY" \
     --arg labels "$LABELS_TXT" --arg hasdesc "${MD_FILE:+1}" '
    { fields: (
        { project: { key: $p }, issuetype: { name: $t }, summary: $s }
        + (if $hasdesc == "1" then { description: . } else {} end)
        + (if $parent != "" then { parent: { key: $parent } } else {} end)
        + (($labels | split("\n") | map(select(. != ""))) as $l | if ($l | length) > 0 then { labels: $l } else {} end)
      ) }' < "$WIKI" > "$TMP/request.json" || die 4 "could not build the request"
  http POST "$BASE/rest/api/2/issue" "$TMP/created.json" \
    -H 'Content-Type: application/json' --data-binary "@$TMP/request.json"
  expect "create an issue in $PKEY" "$TMP/created.json" 201 200
  KEY="$(jq -r '.key // ""' "$TMP/created.json" 2>/dev/null)"
  [[ "$KEY" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]] || die 4 "Jira answered the create without an issue key"
  URL="$BASE/browse/$KEY"
  WROTE=1
  upload_all
  report published
  exit 0
fi

# ── update, attach ────────────────────────────────────────────────
parse_issue "$TARGET"; KEY="$PK"; BASE="${PB%/}"
[[ -n "$BASE" ]] || die 1 "no JIRA_URL — a bare issue key needs the instance" \
  "$(put_hint 'JIRA_URL=<base url>'), or pass the issue link instead of the key"

http GET "$BASE/rest/api/2/issue/$KEY?fields=summary,description,attachment,updated" "$TMP/issue.json"
expect "read $KEY" "$TMP/issue.json" 200
need_json "$TMP/issue.json"
[[ "$(jq -r '.fields | type' "$TMP/issue.json")" == object ]] || die 4 "the answer carries no issue fields — that was not an issue"
K="$(jq -r '.key // ""' "$TMP/issue.json")"
[[ "$K" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]] && KEY="$K"
URL="$BASE/browse/$KEY"
SUMMARY="$(jq -r '.fields.summary // ""' "$TMP/issue.json")"
CUR_UPDATED="$(jq -r '.fields.updated // ""' "$TMP/issue.json")"

if [[ "$ACTION" == update ]]; then
  if [[ -n "$BASE_UPDATED" && "$BASE_UPDATED" != "$CUR_UPDATED" ]]; then
    die 5 "$KEY changed since $BASE_UPDATED: it was updated at $CUR_UPDATED" \
      "read the issue again with jira-fetch.sh, carry the edit over, and publish again"
  fi
  # The file says when the issue was last updated as it was read, to the
  # minute (a file of an older jira-fetch.sh: to the day). When the issue
  # has been updated since, publishing the file would take that back —
  # first thing the user should hear.
  if [[ -n "$FILE_UPDATED" ]]; then
    now="$(jq -r '.fields.updated // "" | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}") then .[0:10] + " " + .[11:16] + ([match("[+-][0-9]{4}$").string | " " + .][0] // "") else .[0:10] end' "$TMP/issue.json")"
    if [[ "$FILE_UPDATED" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then stale=$([[ "$FILE_UPDATED" < "${now:0:10}" ]] && echo 1 || echo 0)
    else stale=$([[ -n "$now" && "$FILE_UPDATED" != "$now" ]] && echo 1 || echo 0); fi
    if (( stale )); then
      note_first "The file was read when the issue was last updated $FILE_UPDATED; it has been updated since, $now. Publishing the file takes back whatever changed: read the issue again, carry the edit over, and dry-run again."
    fi
  fi
  if (( HAVE_SUMMARY )); then
    [[ "$SUMMARY_ARG" != "$SUMMARY" ]] && note "The summary changes from \"$SUMMARY\"."
    SUMMARY="$SUMMARY_ARG"
  elif [[ -n "$TITLE" ]]; then
    t="$(printf '%s' "$TITLE" | LC_ALL=C sed -E 's/^[A-Z][A-Z0-9_]*-[0-9]+ (—|-|:) //')"
    [[ "$t" != "$SUMMARY" ]] && note "The file's title differs from the summary; the summary was left as it is. Pass --summary to change it."
  fi
  if [[ -n "$MD_FILE" ]]; then
    LC_ALL=C grep -q '[^[:space:]]' "$WIKI" || die 2 "$MD_FILE holds no description; publishing it would empty the issue's" \
      "write the description into the file"
    check_mentions
    lost_macros "$TMP/issue.json"
    preview_dir "$KEY"
    (( YES )) || diff_current "$(dirname "$PREVIEW")/description.diff"
  fi
fi

sift_uploads "$TMP/issue.json"

if (( ! YES )); then report dry-run; exit 0; fi

# The files go first, so the description never names an attachment that is
# not there yet.
upload_all

if [[ "$ACTION" == update && ( -n "$MD_FILE" || $HAVE_SUMMARY -eq 1 ) ]]; then
  jq -Rs --arg s "$SUMMARY" --arg hasdesc "${MD_FILE:+1}" --arg hassum "$HAVE_SUMMARY" '
    { fields: (
        (if $hasdesc == "1" then { description: . } else {} end)
        + (if $hassum == "1" then { summary: $s } else {} end)
      ) }' < "$WIKI" > "$TMP/request.json" || die 4 "could not build the request"
  http PUT "$BASE/rest/api/2/issue/$KEY" "$TMP/put.json" \
    -H 'Content-Type: application/json' --data-binary "@$TMP/request.json"
  expect "update $KEY" "$TMP/put.json" 204 200
  WROTE=1
fi

report published
exit 0
