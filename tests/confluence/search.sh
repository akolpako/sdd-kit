#!/usr/bin/env bash
# The tests of confluence-search.sh, the confluence skill's way to search.
#
# It runs on its own — `tests/confluence/search.sh [--update]` — and from
# `tests/run.sh`, which folds the verdict on the last line into its own count.
#
# Nothing here reaches the network: curl is replaced on PATH by ../lib/fake-curl.sh,
# which answers from a table each case writes and logs every request it got.
# What is checked is the script's side of the wire — the CQL it builds, where
# it sends it, that the token goes along — and what each answer turns into.
#
# --update rewrites the goldens from this run. Read the diff before keeping it.
#
# Exit codes: 0 — every check passed; 2 — a check failed.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$SCRIPT_DIR/../.."
CS="$ENGINE/.sdd/skills/confluence/scripts/confluence-search.sh"
API="$SCRIPT_DIR/fixtures/api"
GOLDEN="$SCRIPT_DIR/golden"
UPDATE=0
[[ "${1:-}" == --update ]] && UPDATE=1

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sdd-conf-search.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd)" || exit 1
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export TMPDIR="$TMP/tmp"
mkdir -p "$HOME" "$TMPDIR" "$TMP/bin" || exit 1
ln -s "$SCRIPT_DIR/../lib/fake-curl.sh" "$TMP/bin/curl" || exit 1
export PATH="$TMP/bin:$PATH"
export FAKE_CURL_TABLE="$TMP/table.tsv"
export FAKE_CURL_LOG="$TMP/curl.log"
unset CONFLUENCE_URL CONFLUENCE_TOKEN

PASSED=0
FAILED=0
check() {
  local label="$1" ok="$2" why="${3:-}"
  if (( ok == 0 )); then PASSED=$(( PASSED + 1 ))
  else FAILED=$(( FAILED + 1 )); printf '  FAILED   confluence-search %s — %s\n' "$label" "$why"; fi
}

cs() {
  OUT="$("$CS" "$@" --tokens "$TMP/tokens.env" 2>"$TMP/err.txt")"; RC=$?
  ERR="$(cat "$TMP/err.txt")"
}

table() { printf '%s\n' "$@" | tr '|' '\t' > "$FAKE_CURL_TABLE"; : > "$FAKE_CURL_LOG"; }
tokens() { printf '%s\n' "$@" > "$TMP/tokens.env"; }
has() { printf '%s\n' "$1" | grep -qF -- "$2"; }
asked() { grep -qF -- "$1" "$FAKE_CURL_LOG"; }
log() { cat "$FAKE_CURL_LOG"; }

golden() {
  local label="$1" want="$2" got="$3"
  if (( UPDATE )); then
    mkdir -p "$(dirname "$want")"; cp "$got" "$want"; check "$label" 0; return
  fi
  if [[ ! -f "$want" ]]; then check "$label" 1 "no golden $want — run with --update"; return; fi
  if diff -u "$want" "$got" > "$TMP/diff.txt"; then check "$label" 0
  else check "$label" 1 "differs from the golden:"; sed 's/^/      /' "$TMP/diff.txt"; fi
}

printf 'confluence-search\n'

BASE=https://confluence.example.com
tokens "CONFLUENCE_URL=$BASE" 'CONFLUENCE_TOKEN=tok'

# ── A search ──────────────────────────────────────────────────────
table "/rest/api/search|200|application/json|-|$API/search-results.json"
cs 'order email' --limit 2
check "search: exit 0" "$RC" "exit=$RC, err: $ERR"
asked "$BASE/rest/api/search?cql=siteSearch ~ \"order email\" and type = page&limit=2&start=0	Authorization: Bearer tok	GET"
check "search: one GET with the CQL and the token" $? "log: $(log)"
[[ "$(wc -l < "$FAKE_CURL_LOG" | tr -d ' ')" == 1 ]]
check "search: nothing else is asked" $? "log: $(log)"
printf '%s\n' "$OUT" > "$TMP/report.txt"
golden "search: report" "$GOLDEN/search.report.txt" "$TMP/report.txt"

# ── The CQL ───────────────────────────────────────────────────────
cs 'say "hi" \ there' --title --type all
asked 'cql=title ~ "say \"hi\" \\ there" and type in (page, blogpost)&'
check "cql: quotes and backslashes escaped, title, all types" $? "log: $(log)"

cs 'x' --space PAY --space '~jdoe' --type blogpost --start 20
asked 'cql=siteSearch ~ "x" and space in ("PAY", "~jdoe") and type = blogpost&limit=10&start=20'
check "cql: several spaces, blog posts, start" $? "log: $(log)"

cs --cql 'label = "adr" order by lastmodified desc'
asked 'cql=label = "adr" order by lastmodified desc&'
check "cql: --cql is taken as it is" $? "log: $(log)"

# A link into a space names the instance: no CONFLUENCE_URL is needed.
tokens 'CONFLUENCE_TOKEN=tok'
cs 'x' --space 'https://wiki.example.com/ctx/spaces/OPS/pages/5/Runbook'
[[ $RC -eq 0 ]] && asked 'https://wiki.example.com/ctx/rest/api/search?cql=siteSearch ~ "x" and space = "OPS" and type = page&'
check "cql: a space link names the instance and the key" $? "exit=$RC, err: $ERR, log: $(log)"
cs 'x' --space 'https://wiki.example.com/display/OPS/Runbook'
asked 'https://wiki.example.com/rest/api/search?cql=siteSearch ~ "x" and space = "OPS"'
check "cql: a /display/ link" $? "log: $(log)"
: > "$FAKE_CURL_LOG"; cs 'x'
[[ $RC -eq 1 && ! -s "$FAKE_CURL_LOG" ]] && has "$ERR" "no CONFLUENCE_URL"
check "config: no instance, no request" $? "exit=$RC, err: $ERR"
tokens "CONFLUENCE_URL=$BASE" 'CONFLUENCE_TOKEN=tok'

# ── Usage ─────────────────────────────────────────────────────────
usage_err() {
  local label="$1" want="$2"; shift 2
  : > "$FAKE_CURL_LOG"
  cs "$@"
  [[ $RC -eq 2 && ! -s "$FAKE_CURL_LOG" ]] && has "$ERR" "$want"
  check "usage: $label" $? "exit=$RC, err: $ERR"
}
usage_err "no query"            "ERROR=no query"
usage_err "two queries"         "one query per call"            a b
usage_err "--cql and text"      "--cql takes the place of"      a --cql 'type = page'
usage_err "--cql and --space"   "--cql is taken as it is"       --cql 'type = page' --space PAY
usage_err "limit 0"             "--limit is a number from 1 to 50" a --limit 0
usage_err "limit 51"            "--limit is a number from 1 to 50" a --limit 51
usage_err "bad type"            "--type is page, blogpost or all" a --type comment
usage_err "bad space key"       "not a space key"               a --space 'PAY" or x'
usage_err "a link not to a space" "not a link into a space"     a --space https://c.example.com/browse/X-1
usage_err "spaces on two hosts" "two instances"                 a --space https://a.example.com/spaces/A --space https://b.example.com/spaces/B

# ── Answers ───────────────────────────────────────────────────────
table "/rest/api/search|200|application/json|-|$API/search-none.json"
cs 'nothing'
[[ $RC -eq 0 ]] && has "$OUT" "TOTAL=0" && ! has "$OUT" "NEXT="
check "answer: nothing found is exit 0, TOTAL=0" $? "exit=$RC, out: $OUT"

table "/rest/api/search|400|application/json|-|$API/search-bad.json"
cs --cql 'title ~ "'
[[ $RC -eq 3 ]] && has "$ERR" 'ERROR=Confluence would not take the query: Could not parse cql' && has "$ERR" 'hint: CQL=title ~ "'
check "answer: a CQL it refuses names Confluence's reason" $? "exit=$RC, err: $ERR"

table "/rest/api/search|401|application/json|-|-"
: > "$FAKE_CURL_LOG"; cs 'x'
[[ $RC -eq 3 ]] && has "$ERR" "401"
check "answer: 401" $? "exit=$RC, err: $ERR"

table "/rest/api/search|302|text/html|https://sso.example.org/login|-"
: > "$FAKE_CURL_LOG"; cs 'x'
[[ $RC -eq 3 ]] && has "$ERR" "sso.example.org" && has "$ERR" "VPN"
check "answer: SSO redirect is reported, not followed" $? "exit=$RC, err: $ERR"
[[ "$(wc -l < "$FAKE_CURL_LOG" | tr -d ' ')" == 1 ]]
check "answer: the redirect is not followed" $? "log: $(log)"

table "/rest/api/search|200|text/html|-|$SCRIPT_DIR/fixtures/login.html"
: > "$FAKE_CURL_LOG"; cs 'x'
[[ $RC -eq 4 ]] && has "$ERR" "not JSON"
check "answer: HTML is exit 4" $? "exit=$RC, err: $ERR"

table "/rest/api/search|200|application/json|-|$API/page.json"
: > "$FAKE_CURL_LOG"; cs 'x'
[[ $RC -eq 4 ]] && has "$ERR" "not a Confluence search result"
check "answer: JSON that is no search result is exit 4" $? "exit=$RC, err: $ERR"

# ── No token ──────────────────────────────────────────────────────
tokens "CONFLUENCE_URL=$BASE"
table "/|200|application/json|-|-"
: > "$FAKE_CURL_LOG"; cs 'x'
[[ $RC -eq 1 && ! -s "$FAKE_CURL_LOG" ]] && has "$ERR" "no CONFLUENCE_TOKEN"
check "config: no token, no request" $? "exit=$RC, err: $ERR"

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
(( FAILED == 0 )) || exit 2
exit 0
