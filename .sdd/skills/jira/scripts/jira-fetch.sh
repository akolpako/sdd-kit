#!/usr/bin/env bash
# Reads one Jira Server / Data Center issue into a Markdown file, with the
# attachments its description shows or links downloaded beside it.
#
# Usage: jira-fetch.sh <issue-url-or-key> [--out <file>] [--tokens <file>]...
#                      [--no-attachments] [--from-file <json>] [--parse-only]
#
# Prints KEY=value lines, then ATTACHMENTS: and NOTES: blocks. Every failure
# prints ERROR= and hint: lines on stderr. Exit codes:
#   0 — the file was written
#   1 — the environment is wrong: no curl or jq, no token, no instance URL
#   2 — usage: no argument, or not an issue key or a link to an issue
#   3 — the issue could not be read: HTTP error, SSO redirect, not found
#   4 — the answer was unusable: not JSON, not an issue, or did not convert
# Nothing is written unless the run ends with 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'EOF'
Usage: jira-fetch.sh <issue-url-or-key> [options]

  <issue-url-or-key> any link to an issue, as copied from the browser:
                       https://<base>/browse/<KEY>
                       https://<base>/projects/<PROJECT>/issues/<KEY>
                       https://<base>/secure/RapidBoard.jspa?…&selectedIssue=<KEY>
                     or a bare issue key such as ABC-123 (needs JIRA_URL)

  --out <file>       where the Markdown goes; attachments go to attachments/ beside it
                     (default: $TMPDIR/jira-fetch/<KEY>/issue.md)
  --tokens <file>    a file of KEY=value lines to read the config from; may be
                     given more than once, a later file winning
  --no-attachments   keep the links, download nothing
  --from-file <json> read the REST answer from a file instead of the network
  --parse-only       print what the argument resolves to and stop; no request is made

Config: JIRA_URL and JIRA_TOKEN (a personal access token), read from the
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
    -*)               printf 'ERROR=unknown option: %s\nhint: jira-fetch.sh --help\n' "$1" >&2; exit 2 ;;
    *)
      if [[ -n "$ARG" ]]; then
        printf 'ERROR=one issue per call; got a second argument: %s\n' "$1" >&2; exit 2
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

[[ -n "$ARG" ]] || die 2 "no issue" "jira-fetch.sh <issue-url-or-key> — see --help"

# ── The config ────────────────────────────────────────────────────
# JIRA_URL and JIRA_TOKEN come from the tokens files the caller names with
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

TF_LIST=""
for (( i = 0; i < N_TF; i++ )); do
  conf_load "${TOKEN_FILES[$i]}"
  TF_LIST="${TF_LIST:+$TF_LIST, }${TOKEN_FILES[$i]}"
done
JIRA_URL="${URL_CFG:-${JIRA_URL:-}}"
JIRA_TOKEN="${TOKEN_CFG:-${JIRA_TOKEN:-}}"
JIRA_URL="${JIRA_URL%/}"

# Where a missing or wrong value is to be fixed, for the hint: the files that
# were passed, or how to pass one.
put_hint() {
  if (( N_TF > 0 )); then printf 'put %s in %s' "$1" "$TF_LIST"
  else printf 'put %s in a tokens file and pass it with --tokens <file> (none was passed), or set it in the environment' "$1"; fi
}
check_where() {
  if (( N_TF > 0 )); then printf '%s' "$TF_LIST"; else printf 'the environment'; fi
}

# ── The argument ──────────────────────────────────────────────────
# A link names its own instance: everything left of the part that names the
# issue is the base, so an instance under a context path needs no config.
# Anything the browser appended after the key — a query, a fragment — is not
# part of it.
KEY_RE='^[A-Z][A-Z0-9_]*-[0-9]+$'
KEY=""; BASE=""

parse_arg() {
  local a="$1" k
  KEY=""; BASE=""
  if [[ "$a" =~ $KEY_RE ]]; then
    KEY="$a"; BASE="$JIRA_URL"
    return 0
  fi
  [[ "$a" == http://* || "$a" == https://* ]] || return 1
  a="${a%%#*}"
  if [[ "$a" == */browse/* ]]; then
    BASE="${a%%/browse/*}"
    k="${a#*/browse/}"
  elif [[ "$a" =~ /projects/[^/]+/issues/ ]]; then
    BASE="${a%%/projects/*}"
    k="${a#*/projects/*/issues/}"
  elif [[ "$a" =~ [?\&]selectedIssue=([^\&]+) ]]; then
    k="${BASH_REMATCH[1]}"
    if [[ "$a" == */secure/* ]]; then BASE="${a%%/secure/*}"
    elif [[ "$a" == */issues/* ]]; then BASE="${a%%/issues/*}"
    else return 1; fi
  else
    return 1
  fi
  k="${k%%[?/]*}"
  [[ "$k" =~ $KEY_RE ]] || return 1
  KEY="$k"; BASE="${BASE%/}"
  return 0
}

parse_arg "$ARG" || die 2 "not an issue key or a link to an issue: $ARG" \
  "pass the issue link as the browser shows it (…/browse/<KEY>), or the key, such as ABC-123"

if (( PARSE_ONLY )); then
  printf 'KEY=%s\nBASE=%s\n' "$KEY" "$BASE"
  exit 0
fi

# ── The tools ─────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || die 1 "missing: jq" "install jq (macOS: brew install jq)"
if [[ -z "$FROM_FILE" ]]; then
  command -v curl >/dev/null 2>&1 || die 1 "missing: curl"
  [[ -n "$JIRA_TOKEN" ]] || die 1 "no JIRA_TOKEN" \
    "create a personal access token in Jira (profile → Personal Access Tokens) and $(put_hint 'JIRA_TOKEN=<token>')"
  [[ -n "$BASE" ]] || die 1 "no JIRA_URL — a bare issue key needs the instance" \
    "$(put_hint 'JIRA_URL=<base url>'), or pass the issue link instead of the key"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/jira-fetch.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

# A counter, not ${#NOTES[@]}: on bash 3.2 an empty array counts as unset under
# `set -u` and reading its length aborts the script.
NOTES=(); N_NOTE=0
note() { NOTES+=("$1"); N_NOTE=$(( N_NOTE + 1 )); }

host_of() { printf '%s' "$1" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#[/?#].*$##' -e 's#^[^@]*@##'; }

# ── The answer ────────────────────────────────────────────────────
# --from-file is the same path with the network taken out of it: everything
# downstream reads $TMP/issue.json and cannot tell the two apart.
FIELDS="summary,description,attachment,issuetype,status,priority,assignee,updated"
BODY="$TMP/issue.json"

if [[ -n "$FROM_FILE" ]]; then
  [[ -r "$FROM_FILE" ]] || die 2 "cannot read $FROM_FILE"
  cat "$FROM_FILE" > "$BODY" || die 2 "cannot read $FROM_FILE"
else
  # No -L: a redirect is reported, never followed, so the token cannot reach a
  # host other than the one the link names — and the answer would be a login
  # page that parses as neither JSON nor an error.
  META="$(curl -sS -o "$BODY" \
    -w '%{http_code}\n%{content_type}\n%{redirect_url}\n' \
    -H "Authorization: Bearer $JIRA_TOKEN" \
    -H 'Accept: application/json' \
    "$BASE/rest/api/2/issue/$KEY?fields=$FIELDS" 2>"$TMP/curl.err")" \
    || die 3 "curl failed: $(head -n 1 "$TMP/curl.err" 2>/dev/null)" "check the VPN and that $BASE opens in the browser"
  CODE="$(printf '%s\n' "$META" | sed -n 1p)"
  CTYPE="$(printf '%s\n' "$META" | sed -n 2p)"
  REDIR="$(printf '%s\n' "$META" | sed -n 3p)"

  case "$CODE" in
    200) ;;
    3??)
      # The instance sits behind SSO. Off the VPN every request answers with a
      # redirect to the identity provider and the token never reaches Jira.
      if [[ -n "$REDIR" && "$(host_of "$REDIR")" != "$(host_of "$BASE")" ]]; then
        die 3 "Jira answered with a redirect to $(host_of "$REDIR"): the instance is behind SSO and the token never reached it" \
          "check that the VPN is up"
      fi
      die 3 "Jira answered $CODE with a redirect to $REDIR" "check JIRA_URL or the link: the instance may live under another path"
      ;;
    401) die 3 "Jira answered 401 — the token was rejected" \
           "check JIRA_TOKEN in $(check_where); a token that expired or was revoked has to be created again" ;;
    403) die 3 "Jira answered 403 — the token's owner may not read $KEY" "open the issue in the browser with the same account" ;;
    404) die 3 "Jira answered 404 — no issue $KEY on $BASE, or no permission to see it" "open the link in the browser to check it" ;;
    *)   die 3 "Jira answered $CODE for $KEY" ;;
  esac
  case "$CTYPE" in
    application/json*) ;;
    *) die 4 "the answer from $BASE is ${CTYPE:-untyped}, not JSON — that was not the Jira REST API" \
         "check that JIRA_URL or the link points at Jira, with its context path" ;;
  esac
fi

jq -e . "$BODY" >/dev/null 2>&1 || die 4 "the answer will not parse as JSON"
[[ "$(jq -r '.fields | type' "$BODY")" == object ]] || die 4 "the answer carries no issue fields — that was not an issue"

# A key Jira answers with wins over the one asked for: an issue moved to
# another project answers under its new key.
K="$(jq -r '.key // ""' "$BODY")"
[[ "$K" =~ $KEY_RE ]] && KEY="$K"

# A bare key read from a file can still name its instance: `self` is the REST
# URL the answer came from.
if [[ -z "$BASE" ]]; then
  SELF="$(jq -r '.self // ""' "$BODY")"
  [[ "$SELF" == */rest/api/* ]] && BASE="${SELF%%/rest/api/*}"
fi
[[ -n "$BASE" ]] || die 1 "no JIRA_URL — a bare issue key needs the instance" \
  "$(put_hint 'JIRA_URL=<base url>'), or pass the issue link instead of the key"
URL="$BASE/browse/$KEY"

SUMMARY="$(jq -r '.fields.summary // ""' "$BODY")"
ITYPE="$(jq -r '.fields.issuetype.name // ""' "$BODY")"
STATUS="$(jq -r '.fields.status.name // ""' "$BODY")"
PRIORITY="$(jq -r '.fields.priority.name // ""' "$BODY")"
ASSIGNEE="$(jq -r '.fields.assignee.displayName // ""' "$BODY")"
# To the minute, with the zone: jira-publish.sh compares it with the issue's
# when the file is published back, to tell an issue changed since.
UPDATED="$(jq -r '.fields.updated // "" | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}") then .[0:10] + " " + .[11:16] + ([match("[+-][0-9]{4}$").string | " " + .][0] // "") else .[0:10] end' "$BODY")"
jq -r '.fields.description // ""' "$BODY" > "$TMP/description.wiki"

[[ -n "$SUMMARY" ]] || note "The issue has no summary; the title carries the key alone."

# ── Wiki markup to Markdown ───────────────────────────────────────
# The converter is not allowed to fail quietly. awk can answer with an empty
# result and still exit 0, and the file would then be written as though the
# issue carried no description at all — the one failure that looks exactly like
# a legitimate outcome.
: > "$TMP/dl.txt"
LC_ALL=C awk -v dl="$TMP/dl.txt" -f "$SCRIPT_DIR/wiki-to-md.awk" \
  < "$TMP/description.wiki" > "$TMP/description.md" 2> "$TMP/convert.err"
rc=$?
if (( rc != 0 )) || [[ -s "$TMP/convert.err" ]]; then
  die 4 "the description of $KEY did not convert (exit $rc): $(tr '\n' ' ' < "$TMP/convert.err")"
fi
if LC_ALL=C grep -q '[^[:space:]]' "$TMP/description.wiki"; then
  LC_ALL=C grep -q '[^[:space:]]' "$TMP/description.md" \
    || die 4 "the description of $KEY holds text but converted to nothing"
else
  : > "$TMP/description.md"
  note "The issue has an empty description."
fi

# ── The file ──────────────────────────────────────────────────────
MD="$TMP/issue.md"
{
  if [[ -n "$SUMMARY" ]]; then
    printf '# %s — %s\n\n' "$KEY" "$SUMMARY"
  else
    printf '# %s\n\n' "$KEY"
  fi
  printf '%s\n' "$URL"
  meta=""
  [[ -n "$ITYPE" ]]    && meta="${meta:+$meta · }Type: $ITYPE"
  [[ -n "$STATUS" ]]   && meta="${meta:+$meta · }Status: $STATUS"
  [[ -n "$PRIORITY" ]] && meta="${meta:+$meta · }Priority: $PRIORITY"
  [[ -n "$ASSIGNEE" ]] && meta="${meta:+$meta · }Assignee: $ASSIGNEE"
  [[ -n "$UPDATED" ]]  && meta="${meta:+$meta · }Updated: $UPDATED"
  [[ -n "$meta" ]] && printf '%s\n' "$meta"
  if [[ -s "$TMP/description.md" ]]; then
    printf '\n'
    cat "$TMP/description.md"
  fi
} > "$MD"

# No trailing whitespace, never two blank lines in a row — except inside a
# fenced block, whose text is the issue's own — and no blank line at the end.
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
' "$MD" > "$TMP/issue.tidy" && mv "$TMP/issue.tidy" "$MD"
LC_ALL=C awk '{ L[NR] = $0 } END { n = NR; while (n > 0 && L[n] == "") n--; for (i = 1; i <= n; i++) print L[i] }' \
  "$MD" > "$TMP/issue.tidy" && mv "$TMP/issue.tidy" "$MD"

[[ -n "$OUT" ]] || OUT="${TMPDIR:-/tmp}/jira-fetch/$KEY/issue.md"
OUT="${OUT%/}"
OUT_DIR="$(dirname "$OUT")"
[[ -d "$OUT_DIR" ]] || mkdir -p "$OUT_DIR" || die 1 "cannot create $OUT_DIR"
cat "$MD" > "$OUT" || die 1 "cannot write $OUT"

# ── Attachments ───────────────────────────────────────────────────
# Only what the description shows or links. An issue collects attachments over
# its life — screenshots of a bug that was fixed, a spreadsheet somebody
# dropped in a comment — and none of that is part of the text. What is not
# referenced is counted under NOTES: and left in Jira.
#
# This runs after the file is in place: a download that fails leaves the file,
# and its link, exactly as they were written, and NOTES: names it.
ATT=(); N_ATT=0
ATT_DIR="$OUT_DIR/attachments"
# Counted by name: a file re-uploaded under the same name is one attachment.
N_UNREF="$(jq -r --arg refs "$(cat "$TMP/dl.txt")" '
  ($refs | split("\n")) as $r
  | [.fields.attachment[]?.filename // empty] | unique
  | map(select(. as $f | ($r | map(select(. == $f)) | length) == 0)) | length
' "$BODY" 2>/dev/null)" || true
N_UNREF="${N_UNREF:-0}"

while IFS= read -r fn; do
  [[ -n "$fn" ]] || continue
  # A name is a name, never a path: an issue is written by anyone with an
  # account, and `!../../../x.png!` would otherwise write outside --out.
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
    note "\`$fn\` was not downloaded: --from-file makes no request. The link was kept."
    continue
  fi
  if (( NO_ATT )); then
    note "\`$fn\` was not downloaded (--no-attachments). The link was kept."
    continue
  fi
  if [[ "$(host_of "$url")" != "$(host_of "$BASE")" ]]; then
    note "\`$fn\` was not downloaded: it is on another host. The link was kept."
    continue
  fi
  [[ -d "$ATT_DIR" ]] || mkdir -p "$ATT_DIR" || { note "\`$fn\` was not downloaded: $ATT_DIR could not be created."; continue; }
  code="$(curl -sS -o "$TMP/att.bin" -w '%{http_code}' \
    -H "Authorization: Bearer $JIRA_TOKEN" "$url" 2>"$TMP/curl.err")" || code=""
  if [[ "$code" != 200 ]]; then
    note "\`$fn\` was not downloaded: the request answered ${code:-nothing}. The link was kept."
    continue
  fi
  if ! cat "$TMP/att.bin" > "$ATT_DIR/$fn"; then
    note "\`$fn\` was downloaded but could not be written to $ATT_DIR."
    continue
  fi
  ATT+=("$ATT_DIR/$fn"); N_ATT=$(( N_ATT + 1 ))
done < "$TMP/dl.txt"

if (( N_UNREF > 0 )); then
  note "$N_UNREF attachment(s) on the issue are not referenced by the description and were not downloaded."
fi

# ── The report ────────────────────────────────────────────────────
LINES="$(wc -l < "$OUT" | tr -d ' ')"
printf 'JIRA=ok\nKEY=%s\nSUMMARY=%s\nTYPE=%s\nSTATUS=%s\nURL=%s\nOUT=%s\nLINES=%s\n' \
  "$KEY" "$SUMMARY" "$ITYPE" "$STATUS" "$URL" "$OUT" "$LINES"
printf '\nATTACHMENTS:\n'
(( N_ATT > 0 )) && printf '%s\n' "${ATT[@]}"
printf '\nNOTES:\n'
(( N_NOTE > 0 )) && printf '%s\n' "${NOTES[@]}"
exit 0
