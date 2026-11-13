#!/usr/bin/env bash
# The tests of confluence-publish.sh, the confluence skill's way to write.
#
# It runs on its own — `tests/confluence/publish.sh [--update]` — and from
# `tests/run.sh`, which folds the verdict on the last line into its own count.
#
# Nothing here reaches the network: curl is replaced on PATH by ../lib/fake-curl.sh,
# which answers from a table each case writes, logs every request with its
# method, and keeps every body sent. So what is checked is the script's side
# of the wire — what it sends where, in which order, and that nothing is sent
# without --yes — not that a real Confluence answers the way the fixtures say.
#
# --update rewrites the goldens from this run. Read the diff before keeping it.
#
# Exit codes: 0 — every check passed; 2 — a check failed.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$SCRIPT_DIR/../.."
CP="$ENGINE/.sdd/skills/confluence/scripts/confluence-publish.sh"
FIX="$SCRIPT_DIR/fixtures"
API="$FIX/api"
GOLDEN="$SCRIPT_DIR/golden"
UPDATE=0
[[ "${1:-}" == --update ]] && UPDATE=1

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sdd-conf-pub.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd)" || exit 1
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export TMPDIR="$TMP/tmp"
mkdir -p "$HOME" "$TMPDIR" "$TMP/bin" "$TMP/bodies" || exit 1
ln -s "$SCRIPT_DIR/../lib/fake-curl.sh" "$TMP/bin/curl" || exit 1
export PATH="$TMP/bin:$PATH"
export FAKE_CURL_TABLE="$TMP/table.tsv"
export FAKE_CURL_LOG="$TMP/curl.log"
export FAKE_CURL_BODIES="$TMP/bodies"
unset CONFLUENCE_URL CONFLUENCE_TOKEN

PASSED=0
FAILED=0
check() {
  local label="$1" ok="$2" why="${3:-}"
  if (( ok == 0 )); then PASSED=$(( PASSED + 1 ))
  else FAILED=$(( FAILED + 1 )); printf '  FAILED   confluence-publish %s — %s\n' "$label" "$why"; fi
}

cp_() {
  OUT="$("$CP" "$@" --tokens "$TMP/tokens.env" 2>"$TMP/err.txt")"; RC=$?
  ERR="$(cat "$TMP/err.txt")"
}

table() { printf '%s\n' "$@" | tr '|' '\t' > "$FAKE_CURL_TABLE"; : > "$FAKE_CURL_LOG"; rm -f "$TMP/bodies/"*; }
tokens() { printf '%s\n' "$@" > "$TMP/tokens.env"; }
has() { printf '%s\n' "$1" | grep -qF -- "$2"; }
methods() { cut -f3 "$FAKE_CURL_LOG" | tr '\n' ' ' | sed 's/ $//'; }
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

printf 'confluence-publish\n'

DOC="$TMP/doc"
cp -R "$FIX/publish" "$DOC" || exit 1
STORY="$DOC/story.md"
PAGE=https://confluence.example.com/spaces/PAY/pages/123456/Payments+design

# ── Conversion ────────────────────────────────────────────────────
tokens ""
cp_ create --convert-only "$STORY"
check "convert: exit 0, no request" "$RC" "exit=$RC, err: $ERR"
CONVERTED="$TMPDIR/confluence-publish/converted/body.xml"
# One element per line in the golden, so a diff points at the place.
cp "$CONVERTED" "$TMP/story.xml"
sed 's/></>\n</g' "$CONVERTED" > "$TMP/body.lines"
golden "convert: storage format" "$GOLDEN/publish.xml" "$TMP/body.lines"
has "$OUT" "TITLE=Send order confirmations by email" && has "$OUT" "$DOC/attachments/flow diagram.png" && has "$OUT" "$DOC/attachments/spec.pdf"
check "convert: title and uploads reported" $? "out: $OUT"
if command -v xmllint >/dev/null 2>&1; then
  { printf '<r xmlns:ac="urn:ac" xmlns:ri="urn:ri">'; cat "$CONVERTED"; printf '</r>'; } | xmllint --noout - 2>"$TMP/xml.err"
  check "convert: well-formed XML" $? "$(cat "$TMP/xml.err")"
fi

mkdir -p "$TMP/fetched/attachments" && cp "$SCRIPT_DIR/golden/page.md" "$TMP/fetched/page.md" \
  && : > "$TMP/fetched/attachments/flow diagram.png" && : > "$TMP/fetched/attachments/spec.pdf"
cp_ update "$PAGE" "$TMP/fetched/page.md" --convert-only
[[ $RC -eq 0 ]] && has "$OUT" "TITLE=Payments — design" \
  && [[ "$(sed 's/></>\n</g' "$CONVERTED" | head -n 1)" == "<h1>Overview</h1>" ]] \
  && ! grep -q 'Space: Payments' "$CONVERTED"
check "convert: a fetched file loses its header" $? "exit=$RC, out: $OUT, err: $ERR"

printf '\n![x](/etc/passwd)\n' >> "$TMP/abs.md"
cp_ create --convert-only "$TMP/abs.md"
[[ $RC -eq 2 ]] && has "$ERR" "an absolute path"
check "refs: an absolute path is refused" $? "exit=$RC, err: $ERR"

printf '# D\n\n```mermaid\ngraph TD; A-->B\n```\n\n- item\n\n  ```mermaid\n  flowchart LR\n  ```\n\n```plantuml\nA -> B\n```\n' > "$TMP/diag.md"
cp_ create --convert-only "$TMP/diag.md"
[[ $RC -eq 0 ]] && has "$OUT" '2 ```mermaid blocks are published as code, not drawn' \
  && ! has "$OUT" '```plantuml block' && grep -q 'ac:name="plantuml"' "$CONVERTED"
check "convert: a Mermaid block is noted, PlantUML is not" $? "exit=$RC, out: $OUT"

# ── update ────────────────────────────────────────────────────────
tokens "CONFLUENCE_TOKEN=tok"
GET_PAGE="/rest/api/content/123456?expand=body.storage|200|application/json|-|$API/page.json|GET"
GET_ATT="/rest/api/content/123456/child/attachment?limit|200|application/json|-|$API/attachments.json|GET"
NEW_ATT="/rest/api/content/123456/child/attachment|200|application/json|-|$API/attached.json|POST"
PUT_PAGE="/rest/api/content/123456|200|application/json|-|$API/updated.json|PUT"

table "$GET_PAGE" "$GET_ATT" "$NEW_ATT" "$PUT_PAGE"
cp_ update "$PAGE" "$STORY"
[[ $RC -eq 0 && "$(methods)" == "GET GET" ]] && has "$OUT" "CONFLUENCE=dry-run" && has "$OUT" "VERSION=7" \
  && has "$OUT" "TITLE=Payments — design" && has "$OUT" "SPACE=PAY"
check "update dry run: reads, sends nothing" $? "exit=$RC, out: $OUT, err: $ERR, log: $(log)"
has "$OUT" "macros the Markdown cannot: jira, toc." && has "$OUT" "columns or sections" && has "$OUT" "inline comments"
check "update dry run: what the page loses is named" $? "out: $OUT"
has "$OUT" "the title was left as it is" && has "$OUT" '`flow diagram.png` is attached already, with the same size' \
  && has "$OUT" '`spec.pdf` is attached already, with another size; it is uploaded as its next version'
check "update dry run: title and attachments noted" $? "out: $OUT"
d="$(printf '%s\n' "$OUT" | sed -n 's/^DIFF=//p')"
[[ -f "$d" ]] && [[ "$(sed -n 1p "$d")" == "--- page 123456, version 7, as it is now" ]] && [[ "$(sed -n 2p "$d")" == "+++ $STORY" ]] \
  && grep -qx -- '-Hi' "$d" && grep -qx -- '+## Goals' "$d" && has "$OUT" "Publishing changes the page:" \
  && grep -q 'expand=body.storage,body.export_view,' "$FAKE_CURL_LOG" && ! has "$OUT" "FILE_VERSION="
check "update dry run: DIFF= is the page now against the file" $? "out: $OUT, diff: $(head -20 "$d" 2>/dev/null)"

: > "$FAKE_CURL_LOG"
cp_ update "$PAGE" "$STORY" --yes
[[ $RC -eq 2 && ! -s "$FAKE_CURL_LOG" ]] && has "$ERR" "needs --base-version"
check "update --yes without --base-version: refused before any request" $? "exit=$RC, err: $ERR"

: > "$FAKE_CURL_LOG"
cp_ update "$PAGE" "$STORY" --yes --base-version 6
[[ $RC -eq 5 && "$(methods)" == GET ]] && has "$ERR" "moved on since version 6" && has "$ERR" "John Doe"
check "update --yes on a newer page: conflict, nothing sent" $? "exit=$RC, err: $ERR, log: $(log)"

table "$GET_PAGE" "$GET_ATT" "/child/attachment/att2/data|200|application/json|-|$API/attached.json|POST" "$NEW_ATT" "$PUT_PAGE"
cp_ update "$PAGE" "$STORY" --yes --base-version 7 --message "From the spec"
[[ $RC -eq 0 && "$(methods)" == "GET GET POST PUT" ]] && has "$OUT" "CONFLUENCE=published" && has "$OUT" "VERSION=8"
check "update --yes: attachments first, then the body" $? "exit=$RC, out: $OUT, err: $ERR, log: $(log)"
grep -q '/child/attachment/att2/data' "$FAKE_CURL_LOG" && grep -q 'filename="spec.pdf";type=application/pdf' "$FAKE_CURL_LOG" \
  && grep -q 'minorEdit=true' "$FAKE_CURL_LOG"
check "update --yes: a changed attachment goes up as its next version" $? "log: $(log)"
B="$TMP/bodies/4.body"
[[ "$(jq -c '{id, type, title, space, version}' "$B")" == '{"id":"123456","type":"page","title":"Payments — design","space":{"key":"PAY"},"version":{"number":8,"message":"From the spec"}}' ]] \
  && [[ "$(jq -r '.body.storage.value' "$B")" == "$(cat "$TMP/story.xml")" ]] \
  && [[ "$(jq -r '.body.storage.representation' "$B")" == storage ]]
check "update --yes: the body sent, at the next version" $? "body: $(head -c 400 "$B" 2>/dev/null)"
[[ "$(cut -f2 "$FAKE_CURL_LOG" | sort -u)" == "Authorization: Bearer tok" ]] && ! grep -qv '^https://confluence.example.com/' "$FAKE_CURL_LOG"
check "update --yes: the token goes with every request, to the page's host only" $? "log: $(log)"

table "$GET_PAGE" "$GET_ATT" "/rest/api/content/123456/child/attachment|200|application/json|-|$API/attached.json|POST" \
      "/child/attachment/att2/data|200|application/json|-|$API/attached.json|POST" \
      "/rest/api/content/123456|409|application/json|-|$API/conflict.json|PUT"
cp_ update "$PAGE" "$STORY" --yes --base-version 7
[[ $RC -eq 6 ]] && has "$OUT" "CONFLUENCE=partial" && has "$ERR" "409" && has "$ERR" "Current version is: 8"
check "update --yes: a 409 after an upload is partial" $? "exit=$RC, out: $OUT, err: $ERR"

table "$GET_PAGE" "$GET_ATT" "/rest/api/content?|200|application/json|-|$API/none.json|GET" "$PUT_PAGE"
cp_ update "$PAGE" --title "Payments — new design" --yes --base-version 7
[[ $RC -eq 0 && "$(methods)" == "GET GET GET PUT" ]] \
  && [[ "$(jq -r '.title' "$TMP/bodies/4.body")" == "Payments — new design" ]] \
  && [[ "$(jq -r '.body.storage.value' "$TMP/bodies/4.body")" == "$(jq -r '.body.storage.value' "$API/page.json")" ]]
check "update --title alone: the body is kept as it is" $? "exit=$RC, out: $OUT, err: $ERR, log: $(log)"

table "$GET_PAGE" "/rest/api/content?|200|application/json|-|$API/taken.json|GET"
cp_ update "$PAGE" --title "Send order confirmations by email"
[[ $RC -eq 5 ]] && has "$ERR" "already has another page titled"
check "update --title: a title taken by another page is a conflict" $? "exit=$RC, err: $ERR"

table "/rest/api/content/123456|401|application/json|-|-"
cp_ update "$PAGE" "$STORY"
[[ $RC -eq 3 ]] && has "$ERR" "token was rejected"
check "update: 401 names the token" $? "exit=$RC, err: $ERR"

# A /display/ link names the page by title; the fetch script learns the id.
table "/rest/api/content?spaceKey=PAY&title=Payments design|200|application/json|-|$FIX/search.json|GET" \
      "/rest/api/content/123456?expand=body.storage|200|application/json|-|$API/page.json|GET" "$GET_ATT"
cp_ update "https://confluence.example.com/display/PAY/Payments+design" "$STORY"
[[ $RC -eq 0 ]] && has "$OUT" "ID=123456"
check "update: a /display/ link is resolved to the page id" $? "exit=$RC, out: $OUT, err: $ERR, log: $(log)"

# ── update: a file read from the page ─────────────────────────────
# A page with merged cells and a short row, read into a file and published
# back: the table is named, a file read at an older version is warned about,
# and an untouched file changes no text.
GET_MERGED="/rest/api/content/123456?expand=body.storage|200|application/json|-|$API/merged.json|GET"
table "$GET_MERGED" "$GET_ATT"
mkdir -p "$TMP/merged"
F="$("$ENGINE/.sdd/skills/confluence/scripts/confluence-fetch.sh" 123456 --from-file "$API/merged.json" --out "$TMP/merged/page.md" 2>&1)"
has "$F" "A table has merged cells" && has "$F" 'The table "Type | Field | Getter" has a row with fewer cells than the table is wide: row 4, the header being row 1.' \
  && grep -qxF '|  | `CKM` | `getCkm()` |' "$TMP/merged/page.md" && grep -qxF '| Person | `INN` |  |' "$TMP/merged/page.md"
check "fetch: merged cells and a short row are named" $? "out: $F, md: $(cat "$TMP/merged/page.md")"

cp_ update "$PAGE" "$TMP/merged/page.md"
[[ $RC -eq 0 ]] && has "$OUT" "FILE_VERSION=29" && ! has "$OUT" "DIFF=" && has "$OUT" "publishing it changes no text" \
  && ! has "$OUT" "was read at version" \
  && has "$OUT" "Table 1 of the page (Type | Field | Getter) has merged cells, which Markdown cannot hold" \
  && has "$OUT" "has rows with fewer cells than it is wide (row 4, the header being row 1)" && ! has "$OUT" "changes shape"
check "update dry run: an untouched fetched file — no diff, the table's losses named" $? "exit=$RC, out: $OUT, err: $ERR"

sed -i.bak -e 's/Version: 29,/Version: 27,/' -e 's/^Field mapping:$/Field mapping, as agreed:/' "$TMP/merged/page.md"
printf '| Org | `OGRN` | `getOgrn()` |\n' >> "$TMP/merged/page.md"
cp_ update "$PAGE" "$TMP/merged/page.md"
first="$(printf '%s\n' "$OUT" | sed -n '/^NOTES:/{n;p;}')"
d="$(printf '%s\n' "$OUT" | sed -n 's/^DIFF=//p')"
[[ $RC -eq 0 ]] && has "$OUT" "FILE_VERSION=27" \
  && [[ "$first" == "The file was read at version 27; the page is at version 29 now, last changed by Anna Smith, 2026-11-13."* ]] \
  && has "$OUT" "changes shape: 4 rows by 3 columns on the page, 5 by 3 in the file" \
  && [[ -f "$d" ]] && grep -qx -- '-Field mapping:' "$d" && grep -qx -- '+Field mapping, as agreed:' "$d" \
  && grep -qxF -- '+| Org | `OGRN` | `getOgrn()` |' "$d"
check "update dry run: an edited file read at an older version — warned first, diffed" $? "exit=$RC, out: $OUT, err: $ERR, diff: $(cat "$d" 2>/dev/null)"

: > "$FAKE_CURL_LOG"
cp_ update "$PAGE" "$TMP/merged/page.md" --yes --base-version 27
[[ $RC -eq 5 && "$(methods)" == GET ]] && ! grep -q 'export_view' "$FAKE_CURL_LOG"
check "update --yes from an old file: conflict, and no export view read" $? "exit=$RC, err: $ERR, log: $(log)"

# ── create ────────────────────────────────────────────────────────
tokens "CONFLUENCE_TOKEN=tok" "CONFLUENCE_URL=https://confluence.example.com"
GET_SPACE="/rest/api/space/PAY|200|application/json|-|$API/space.json|GET"
NO_TITLE="/rest/api/content?|200|application/json|-|$API/none.json|GET"
POST_PAGE="/rest/api/content|200|application/json|-|$API/created.json|POST"
NEW_PAGE_ATT="/rest/api/content/200/child/attachment|200|application/json|-|$API/attached.json|POST"

table "$GET_SPACE" "$NO_TITLE" "$NEW_PAGE_ATT" "$POST_PAGE"
cp_ create --space PAY "$STORY"
[[ $RC -eq 0 && "$(methods)" == "GET GET" ]] && has "$OUT" "CONFLUENCE=dry-run" && has "$OUT" "TITLE=Send order confirmations by email" \
  && has "$OUT" "$DOC/attachments/flow diagram.png"
check "create dry run: checks the space and the title, sends nothing" $? "exit=$RC, out: $OUT, err: $ERR, log: $(log)"

: > "$FAKE_CURL_LOG"
cp_ create --space https://confluence.example.com/spaces/PAY/overview "$STORY" --yes
[[ $RC -eq 0 && "$(methods)" == "GET GET POST POST POST" ]] && has "$OUT" "ID=200" && has "$OUT" "VERSION=1" \
  && has "$OUT" "URL=https://confluence.example.com/spaces/PAY/pages/200/Send+order"
check "create --yes: the page, then its attachments" $? "exit=$RC, out: $OUT, err: $ERR, log: $(log)"
[[ "$(jq -c '{type, title, space, a: has("ancestors")}' "$TMP/bodies/3.body")" == '{"type":"page","title":"Send order confirmations by email","space":{"key":"PAY"},"a":false}' ]]
check "create --yes: the page sent" $? "body: $(head -c 300 "$TMP/bodies/3.body" 2>/dev/null)"

table "/rest/api/content/555?expand=space|200|application/json|-|$API/parent.json|GET" "$NO_TITLE" "$POST_PAGE" "$NEW_PAGE_ATT"
cp_ create --parent https://confluence.example.com/pages/viewpage.action?pageId=555 --title "Child page" "$STORY" --yes
[[ $RC -eq 0 ]] && has "$OUT" "PARENT=555 (Architecture)" && has "$OUT" "SPACE=PAY" \
  && [[ "$(jq -c '{title, space, ancestors}' "$TMP/bodies/3.body")" == '{"title":"Child page","space":{"key":"PAY"},"ancestors":[{"id":"555"}]}' ]]
check "create --yes under a parent: its space, its id as the ancestor" $? "exit=$RC, out: $OUT, err: $ERR, body: $(cat "$TMP/bodies/3.body" 2>/dev/null | head -c 300)"

table "$GET_SPACE" "/rest/api/content?|200|application/json|-|$API/taken.json|GET"
cp_ create --space PAY "$STORY" --yes
[[ $RC -eq 5 && "$(methods)" == "GET GET" ]] && has "$ERR" 'already has a page titled "Send order confirmations by email" (id 999)'
check "create: a taken title is a conflict, nothing sent" $? "exit=$RC, err: $ERR, log: $(log)"

table "$GET_SPACE" "$NO_TITLE" "/rest/api/content/200/child/attachment|413|application/json|-|-|POST" "$POST_PAGE"
cp_ create --space PAY "$STORY" --yes
[[ $RC -eq 6 ]] && has "$OUT" "CONFLUENCE=partial" && has "$OUT" "ID=200" && has "$OUT" "URL=https://confluence.example.com/"
check "create --yes: an upload refused after the create is partial and names the page" $? "exit=$RC, out: $OUT, err: $ERR"

cp_ create "$STORY"
[[ $RC -eq 2 ]] && has "$ERR" "needs --space or --parent"
check "create: needs a space or a parent" $? "exit=$RC, err: $ERR"

# ── attach ────────────────────────────────────────────────────────
tokens "CONFLUENCE_TOKEN=tok"
printf 'LOG' > "$TMP/run.log"
table "$GET_PAGE" "$GET_ATT" "$NEW_ATT"
cp_ attach "$PAGE" "$TMP/run.log"
[[ $RC -eq 0 && "$(methods)" == "GET GET" ]] && has "$OUT" "$TMP/run.log"
check "attach dry run: lists what would go" $? "exit=$RC, out: $OUT, err: $ERR"
: > "$FAKE_CURL_LOG"
cp_ attach "$PAGE" "$TMP/run.log" --yes
[[ $RC -eq 0 && "$(methods)" == "GET GET POST" ]] && grep -q 'child/attachment	.*filename="run.log";type=text/plain' "$FAKE_CURL_LOG"
check "attach --yes: uploads a new attachment" $? "exit=$RC, out: $OUT, err: $ERR, log: $(log)"

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
(( FAILED > 0 )) && exit 2
exit 0
