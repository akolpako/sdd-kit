#!/usr/bin/env bash
# The tests of confluence-fetch.sh, the confluence skill's way to read.
#
# It runs on its own — `tests/confluence/run.sh [--update]` — and from
# `tests/run.sh`, which folds the verdict on the last line into its own count.
#
# Nothing here reaches the network: curl is replaced on PATH by ../lib/fake-curl.sh,
# which answers from a table each case writes and logs every request it got.
# So what is checked is the script's side of the wire — which URL it asks for,
# that the token goes along and nowhere else, what each answer turns into —
# not that a real Confluence answers the way the fixtures say it does.
#
# Every call but the ones about the config itself passes --tokens with the
# file the case wrote. HOME is a directory of its own, so a run writes nothing
# a person owns.
#
# --update rewrites the goldens from this run. Read the diff before keeping it.
#
# Exit codes: 0 — every check passed; 2 — a check failed.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$SCRIPT_DIR/../.."
CF="$ENGINE/.sdd/skills/confluence/scripts/confluence-fetch.sh"
FIX="$SCRIPT_DIR/fixtures"
GOLDEN="$SCRIPT_DIR/golden"
UPDATE=0
[[ "${1:-}" == --update ]] && UPDATE=1

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sdd-confluence.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd)" || exit 1
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export TMPDIR="$TMP/tmp"
mkdir -p "$HOME/.config/sdd-kit" "$TMPDIR" "$TMP/bin" || exit 1
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
  else FAILED=$(( FAILED + 1 )); printf '  FAILED   confluence-fetch %s — %s\n' "$label" "$why"; fi
}

# Runs the script with the case's tokens file; leaves OUT, ERR and RC.
cf() {
  OUT="$("$CF" --tokens "$TMP/tokens.env" "$@" 2>"$TMP/err.txt")"; RC=$?
  ERR="$(cat "$TMP/err.txt")"
}

table() { printf '%s\n' "$@" | tr '|' '\t' > "$FAKE_CURL_TABLE"; : > "$FAKE_CURL_LOG"; }
tokens() { printf '%s\n' "$@" > "$TMP/tokens.env"; }
has() { printf '%s\n' "$1" | grep -qF -- "$2"; }

golden() {
  local label="$1" want="$2" got="$3"
  if (( UPDATE )); then
    mkdir -p "$(dirname "$want")"; cp "$got" "$want"; check "$label" 0; return
  fi
  if [[ ! -f "$want" ]]; then check "$label" 1 "no golden $want — run with --update"; return; fi
  if diff -u "$want" "$got" > "$TMP/diff.txt"; then check "$label" 0
  else check "$label" 1 "differs from the golden:"; sed 's/^/      /' "$TMP/diff.txt"; fi
}

printf 'confluence-fetch\n'

# ── Conversion, against goldens ───────────────────────────────────
tokens ""
cf https://confluence.example.com/spaces/PAY/pages/123456/Payments+design \
  --from-file "$FIX/page.json" --out "$TMP/g1/page.md"
check "page: exit 0" "$RC" "exit=$RC, err: $ERR"
golden "page: markdown" "$GOLDEN/page.md" "$TMP/g1/page.md"
printf '%s\n' "$OUT" | sed "s#$TMP#<TMP>#g" > "$TMP/g1/report.txt"
golden "page: report" "$GOLDEN/page.report.txt" "$TMP/g1/report.txt"

cf 9 --from-file "$FIX/edge.json" --out "$TMP/g2/page.md"
check "edge: exit 0" "$RC" "exit=$RC, err: $ERR"
golden "edge: markdown" "$GOLDEN/edge.md" "$TMP/g2/page.md"

# The export view has only a PlantUML macro's image; its source comes from
# the storage format, in page order. The fourth image is a macro that draws an
# attachment, the fifth has no macro at all: both keep the image.
cf 77 --from-file "$FIX/plantuml.json" --out "$TMP/g3/page.md"
check "plantuml: exit 0" "$RC" "exit=$RC, err: $ERR"
golden "plantuml: markdown" "$GOLDEN/plantuml.md" "$TMP/g3/page.md"
has "$OUT" "A PlantUML macro draws an attachment"
check "plantuml: notes the macro without a source" $? "got: $OUT"
has "$OUT" "A PlantUML diagram's source was not found"
check "plantuml: notes the image without a macro" $? "got: $OUT"

# An expand macro without a title of its own shows Confluence's default text,
# which is no part of the page; one with a title keeps it. A macro the file has
# no form for is named under NOTES:, and so is an image a plugin draws.
cf 78 --from-file "$FIX/macros.json" --out "$TMP/g4/page.md"
check "macros: exit 0" "$RC" "exit=$RC, err: $ERR"
golden "macros: markdown" "$GOLDEN/macros.md" "$TMP/g4/page.md"
has "$OUT" "macros the file carries at most as their rendered text: anchor, drawio, roadmap-planner."
check "macros: names the macros it has no form for" $? "got: $OUT"
has "$OUT" "An image drawn by a macro (/rest/drawio/…)"
check "macros: names an image a plugin draws" $? "got: $OUT"
! grep -q 'Click here' "$TMP/g4/page.md" && grep -qx '\*\*Details & more\*\*' "$TMP/g4/page.md"
check "macros: expand title kept, default text dropped" $? "$(cat "$TMP/g4/page.md")"
# Without the storage format, only the English default text is known.
jq 'del(.body.storage)' "$FIX/macros.json" > "$TMP/nostore.json"
cf 78 --from-file "$TMP/nostore.json" --out "$TMP/g5/page.md"
! grep -q 'Click here' "$TMP/g5/page.md" && grep -qx '\*\*Details & more\*\*' "$TMP/g5/page.md"
check "macros: no storage — default text still dropped" $? "$(cat "$TMP/g5/page.md")"
! has "$OUT" "macros the file carries"
check "macros: no storage — no macro list" $? "got: $OUT"

# ── Links ─────────────────────────────────────────────────────────
parse() {
  local label="$1" want="$2" link="$3" got
  cf "$link" --parse-only
  got="$(printf "%s" "$OUT" | tr "\n" " ")"; got="${got% }"
  [[ $RC -eq 0 && "$got" == "$want" ]]
  check "link: $label" $? "exit=$RC, got: $got"
}
parse "spaces/pages"   "KIND=id BASE=https://c.example.com ID=123" "https://c.example.com/spaces/PAY/pages/123/Some+Title"
parse "no title"       "KIND=id BASE=https://c.example.com ID=123" "https://c.example.com/spaces/PAY/pages/123"
parse "context path"   "KIND=id BASE=https://c.example.com/wiki ID=123" "https://c.example.com/wiki/spaces/PAY/pages/123/T"
parse "query, anchor"  "KIND=id BASE=https://c.example.com ID=123" "https://c.example.com/spaces/PAY/pages/123/T?focusedCommentId=5#comment-5"
parse "viewpage"       "KIND=id BASE=https://c.example.com ID=456" "https://c.example.com/pages/viewpage.action?spaceKey=PAY&pageId=456"
parse "display"        "KIND=title BASE=https://c.example.com SPACE=PAY TITLE=My Page: П" "https://c.example.com/display/PAY/My+Page%3A+%D0%9F"
parse "tiny"           "KIND=tiny BASE=https://c.example.com TINY=a4OcE" "https://c.example.com/x/a4OcE"

for bad in https://c.example.com/spaces/PAY/overview https://c.example.com/display/PAY not-a-link https://c.example.com/spaces/PAY/pages/abc; do
  cf "$bad" --parse-only
  [[ $RC -eq 2 ]] && has "$ERR" "ERROR=not a link"
  check "link: rejects $bad" $? "exit=$RC, err: $ERR"
done

# ── Config ────────────────────────────────────────────────────────
# Run without the helper: each case names its own files.
raw() { OUT="$("$CF" "$@" 2>"$TMP/err.txt")"; RC=$?; ERR="$(cat "$TMP/err.txt")"; }

tokens '# comment' 'export CONFLUENCE_URL="https://home.example.com/"' "CONFLUENCE_TOKEN='t1'" 'JIRA_URL=https://jira' 'OTHER=x'
raw 42 --parse-only --tokens "$TMP/tokens.env"
has "$OUT" "BASE=https://home.example.com"
check "config: tokens file, quotes, export, trailing slash" $? "got: $OUT"

printf 'CONFLUENCE_URL=https://proj.example.com\nSDD_BUILD_ROOT=mvn verify\n' > "$TMP/proj.env"
raw 42 --parse-only --tokens "$TMP/tokens.env" --tokens "$TMP/proj.env"
has "$OUT" "BASE=https://proj.example.com"
check "config: a later file wins" $? "got: $OUT"

OUT="$(CONFLUENCE_URL=https://env.example.com "$CF" 42 --parse-only --tokens "$TMP/tokens.env" 2>&1)"
has "$OUT" "BASE=https://home.example.com"
check "config: a file over the environment" $? "got: $OUT"

printf 'CONFLUENCE_TOKEN=t2\n' > "$TMP/token-only.env"
OUT="$(CONFLUENCE_URL=https://env.example.com "$CF" 42 --parse-only --tokens "$TMP/token-only.env" 2>&1)"
has "$OUT" "BASE=https://env.example.com"
check "config: the environment fills in what no file set" $? "got: $OUT"

raw 42 --parse-only --tokens "$TMP/nowhere.env"
[[ $RC -eq 1 ]] && has "$ERR" "cannot read the tokens file: $TMP/nowhere.env"
check "config: a missing tokens file is an error" $? "exit=$RC, err: $ERR"

# No file is looked for: a token in the SDD kit's file is not read unless passed.
printf 'CONFLUENCE_TOKEN=home\nCONFLUENCE_URL=https://home.example.com\n' > "$HOME/.config/sdd-kit/tokens.env"
mkdir -p "$TMP/proj/.sdd" && cp "$HOME/.config/sdd-kit/tokens.env" "$TMP/proj/.sdd/sdd.conf"
table "/|200|application/json|-|-"
OUT="$(cd "$TMP/proj" && "$CF" https://confluence.example.com/spaces/PAY/pages/1/T --out "$TMP/c1/out.md" 2>&1)"; RC=$?
[[ $RC -eq 1 && ! -s "$FAKE_CURL_LOG" ]] && has "$OUT" "no CONFLUENCE_TOKEN" && has "$OUT" "--tokens <file> (none was passed)"
check "config: no file is read unless passed" $? "exit=$RC, out: $OUT"
rm -f "$HOME/.config/sdd-kit/tokens.env"

# ── Requests ──────────────────────────────────────────────────────
PAGE=https://confluence.example.com/spaces/PAY/pages/123456/Payments+design

tokens "CONFLUENCE_TOKEN=tok"
table "/rest/api/content/123456|200|application/json;charset=UTF-8|-|$FIX/page.json" \
      "/download/attachments/123456/|200|image/png|-|$FIX/att.bin"
cf "$PAGE" --out "$TMP/r1/page.md"
check "fetch: exit 0" "$RC" "exit=$RC, err: $ERR"
grep -q 'rest/api/content/123456?expand=body.export_view,body.storage,version,space,ancestors' "$FAKE_CURL_LOG"
check "fetch: asks for the rendered body" $? "log: $(cat "$FAKE_CURL_LOG")"
[[ "$(cut -f2 "$FAKE_CURL_LOG" | sort -u)" == "Authorization: Bearer tok" ]]
check "fetch: every request carries the token" $? "log: $(cat "$FAKE_CURL_LOG")"
! grep -qv '^https://confluence.example.com/' "$FAKE_CURL_LOG"
check "fetch: nothing goes to another host" $? "log: $(cat "$FAKE_CURL_LOG")"
[[ -f "$TMP/r1/attachments/flow diagram.png" && -f "$TMP/r1/attachments/spec.pdf" ]] \
  && has "$OUT" "$TMP/r1/attachments/spec.pdf"
check "fetch: attachments downloaded and listed" $? "out: $OUT"
grep -v '^NOTES' "$TMP/r1/page.md" | diff -q - "$GOLDEN/page.md" >/dev/null
check "fetch: same Markdown as from a file" $? "$(diff "$GOLDEN/page.md" "$TMP/r1/page.md" | head -5)"

table "/rest/api/content/123456|200|application/json|-|$FIX/page.json"
cf "$PAGE" --out "$TMP/r2/page.md" --no-attachments
! grep -q download "$FAKE_CURL_LOG" && has "$OUT" "--no-attachments"
check "fetch: --no-attachments downloads nothing" $? "log: $(cat "$FAKE_CURL_LOG")"

cf "$PAGE" --out "$TMP/r3/page.md"
[[ $RC -eq 0 ]] && has "$OUT" '`spec.pdf` was not downloaded: the request answered 404' && grep -qF '(attachments/spec.pdf)' "$TMP/r3/page.md"
check "fetch: a failed download keeps the link and is noted" $? "exit=$RC, out: $OUT"

table "/rest/api/content?|200|application/json|-|$FIX/search.json"
cf "https://confluence.example.com/display/PAY/Payments+design" --out "$TMP/r4/page.md" --no-attachments
[[ $RC -eq 0 ]] && has "$OUT" "ID=123456" && grep -q 'spaceKey=PAY&title=Payments design' "$FAKE_CURL_LOG"
check "fetch: /display/ link found by title" $? "exit=$RC, err: $ERR, log: $(cat "$FAKE_CURL_LOG")"

table "/rest/api/content?|200|application/json|-|$FIX/search-empty.json"
cf "https://confluence.example.com/display/PAY/Gone" --out "$TMP/r5/page.md"
[[ $RC -eq 3 && ! -e "$TMP/r5/page.md" ]] && has "$ERR" 'no page titled "Gone" in space PAY'
check "fetch: unknown title" $? "exit=$RC, err: $ERR"

table "/x/a4OcE|302|text/html|$PAGE|-" "/rest/api/content/123456|200|application/json|-|$FIX/page.json"
cf "https://confluence.example.com/x/a4OcE" --out "$TMP/r6/page.md" --no-attachments
[[ $RC -eq 0 ]] && has "$OUT" "ID=123456"
check "fetch: tiny link resolved by its redirect" $? "exit=$RC, err: $ERR"

table "/x/a4OcE|302|text/html|https://evil.example.net/spaces/PAY/pages/1|-"
cf "https://confluence.example.com/x/a4OcE" --out "$TMP/r7/page.md"
[[ $RC -eq 3 ]] && ! grep -q evil "$FAKE_CURL_LOG"
check "fetch: tiny link to another host is not followed" $? "exit=$RC, log: $(cat "$FAKE_CURL_LOG")"

table "/rest/api/content/123456|401|application/json|-|-"
cf "$PAGE" --out "$TMP/r8/page.md"
[[ $RC -eq 3 && ! -e "$TMP/r8/page.md" ]] && has "$ERR" "token was rejected"
check "fetch: 401 names the token, writes nothing" $? "exit=$RC, err: $ERR"

table "/rest/api/content/123456|302|text/html|https://sso.example.net/login|-"
cf "$PAGE" --out "$TMP/r9/page.md"
[[ $RC -eq 3 ]] && has "$ERR" "behind SSO" && has "$ERR" "VPN"
check "fetch: SSO redirect names the VPN" $? "exit=$RC, err: $ERR"

table "/rest/api/content/123456|200|text/html|-|$FIX/login.html"
cf "$PAGE" --out "$TMP/r10/page.md"
[[ $RC -eq 4 ]] && has "$ERR" "not JSON"
check "fetch: an HTML answer is refused" $? "exit=$RC, err: $ERR"

table "/rest/api/content/|404|application/json|-|-"
cf "$PAGE" --out "$TMP/r11/page.md"
[[ $RC -eq 3 ]] && has "$ERR" "404"
check "fetch: 404" $? "exit=$RC, err: $ERR"

tokens ""
table "/|200|application/json|-|$FIX/page.json"
cf "$PAGE" --out "$TMP/r12/page.md"
[[ $RC -eq 1 && ! -s "$FAKE_CURL_LOG" ]] && has "$ERR" "no CONFLUENCE_TOKEN" && has "$ERR" "hint:"
check "fetch: no token, no request" $? "exit=$RC, err: $ERR"

tokens "CONFLUENCE_TOKEN=tok"
cf 123456 --out "$TMP/r13/page.md"
[[ $RC -eq 1 ]] && has "$ERR" "no CONFLUENCE_URL"
check "fetch: bare id needs CONFLUENCE_URL" $? "exit=$RC, err: $ERR"

cf
[[ $RC -eq 2 ]]
check "usage: no argument" $? "exit=$RC"

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
(( FAILED > 0 )) && exit 2
exit 0
