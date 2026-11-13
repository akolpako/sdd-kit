#!/usr/bin/env bash
# The tests of jira-publish.sh, the jira skill's way to write.
#
# It runs on its own — `tests/jira/publish.sh [--update]` — and from
# `tests/run.sh`, which folds the verdict on the last line into its own count.
#
# Nothing here reaches the network: curl is replaced on PATH by ../lib/fake-curl.sh,
# which answers from a table each case writes, logs every request with its
# method, and keeps every body sent. So what is checked is the script's side
# of the wire — what it sends where, in which order, and that nothing is sent
# without --yes — not that a real Jira answers the way the fixtures say.
#
# --update rewrites the goldens from this run. Read the diff before keeping it.
#
# Exit codes: 0 — every check passed; 2 — a check failed.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$SCRIPT_DIR/../.."
JP="$ENGINE/.sdd/skills/jira/scripts/jira-publish.sh"
FIX="$SCRIPT_DIR/fixtures"
API="$FIX/api"
GOLDEN="$SCRIPT_DIR/golden"
UPDATE=0
[[ "${1:-}" == --update ]] && UPDATE=1

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sdd-jira-pub.XXXXXX")" || exit 1
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
unset JIRA_URL JIRA_TOKEN

PASSED=0
FAILED=0
check() {
  local label="$1" ok="$2" why="${3:-}"
  if (( ok == 0 )); then PASSED=$(( PASSED + 1 ))
  else FAILED=$(( FAILED + 1 )); printf '  FAILED   jira-publish %s — %s\n' "$label" "$why"; fi
}

# Runs the script with the case's tokens file; leaves OUT, ERR and RC.
jp() {
  OUT="$("$JP" "$@" --tokens "$TMP/tokens.env" 2>"$TMP/err.txt")"; RC=$?
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

printf 'jira-publish\n'

# A copy of the publish fixture the cases may change.
DOC="$TMP/doc"
cp -R "$FIX/publish" "$DOC" || exit 1
STORY="$DOC/story.md"
ISSUE=https://jira.example.com/browse/ABC-123

# ── Conversion ────────────────────────────────────────────────────
tokens ""
jp create --convert-only "$STORY"
check "convert: exit 0, no request" "$RC" "exit=$RC, err: $ERR"
golden "convert: wiki markup" "$GOLDEN/publish.wiki" "$TMPDIR/jira-publish/converted/description.wiki"
has "$OUT" "TITLE=Send order confirmations by email" && has "$OUT" "$DOC/attachments/flow diagram.png" \
  && has "$OUT" "$DOC/attachments/spec.pdf" && has "$OUT" "mentions [~jdoe]"
check "convert: title, uploads and mentions reported" $? "out: $OUT"
has "$OUT" "Not checked: --convert-only makes no request"
check "convert: a mention is not looked up without a request" $? "out: $OUT"
! grep -q 'A hint from the template' "$TMPDIR/jira-publish/converted/description.wiki"
check "convert: HTML comments dropped" $?

# A file jira-fetch.sh wrote publishes back without its header.
jp update "$ISSUE" "$SCRIPT_DIR/golden/edge.md" --convert-only
[[ $RC -eq 0 ]] && has "$OUT" "TITLE=ABC-7 — Move report generation into its own service" \
  && ! grep -q 'jira.example.com/browse' "$TMPDIR/jira-publish/converted/description.wiki" \
  && [[ "$(head -n 1 "$TMPDIR/jira-publish/converted/description.wiki")" == "h2. Solution design" ]]
check "convert: a fetched file loses its header" $? "exit=$RC, out: $OUT, wiki: $(head -3 "$TMPDIR/jira-publish/converted/description.wiki")"

# ── References that cannot be uploaded ────────────────────────────
ref_case() {
  local label="$1" line="$2" want="$3"
  cp "$STORY" "$TMP/story.bak"
  printf '\n%s\n' "$line" >> "$STORY"
  jp create --convert-only "$STORY"
  [[ $RC -eq 2 ]] && has "$ERR" "$want" && has "$ERR" "hint:"
  check "refs: $label" $? "exit=$RC, err: $ERR"
  cp "$TMP/story.bak" "$STORY"
}
ref_case "an absolute path is refused" "![key](/home/me/.ssh/id_rsa)" "an absolute path"
ref_case "a home path is refused" "[key](~/.ssh/id_rsa)" "an absolute path"
ref_case "a path out of the folder is refused" "![x](attachments/../../secret.png)" "outside its folder"
ref_case "a missing file is refused" "![x](attachments/missing.png)" "does not exist"
mkdir -p "$DOC/other" && printf 'X' > "$DOC/other/spec.pdf"
ref_case "two files of one name are refused" "[again](other/spec.pdf)" "both be attached as spec.pdf"

# ── Arguments ─────────────────────────────────────────────────────
tokens "JIRA_TOKEN=tok"
table "/|200|application/json|-|$API/issue.json"
OUT="$("$JP" 2>"$TMP/err.txt")"; RC=$?; ERR="$(cat "$TMP/err.txt")"
[[ $RC -eq 2 ]] && has "$ERR" "no action"
check "usage: no action" $? "exit=$RC, err: $ERR"
jp delete ABC-1; [[ $RC -eq 2 ]] && has "$ERR" "unknown action"
check "usage: unknown action" $? "exit=$RC, err: $ERR"
jp update "$ISSUE"; [[ $RC -eq 2 ]] && has "$ERR" "nothing to update"
check "usage: update with nothing to update" $? "exit=$RC, err: $ERR"
jp update "$ISSUE" "$STORY" --type Story; [[ $RC -eq 2 ]] && has "$ERR" "--type does not apply to update"
check "usage: a create option on update" $? "exit=$RC, err: $ERR"
jp create --type Story "$STORY"; [[ $RC -eq 2 ]] && has "$ERR" "needs --project"
check "usage: create needs a project" $? "exit=$RC, err: $ERR"
jp update not-a-key "$STORY"; [[ $RC -eq 2 ]] && has "$ERR" "not an issue key"
check "usage: not an issue" $? "exit=$RC, err: $ERR"
[[ ! -s "$FAKE_CURL_LOG" ]]
check "usage: no request was made" $? "log: $(log)"

# ── update ────────────────────────────────────────────────────────
GET_ISSUE="/rest/api/2/issue/ABC-123?|200|application/json|-|$API/issue.json|GET"
ATTACH="/rest/api/2/issue/ABC-123/attachments|200|application/json|-|$API/attached.json|POST"
PUT_ISSUE="/rest/api/2/issue/ABC-123|204|-|-|-|PUT"
UPDATED=2026-11-01T10:00:00.000+0100
USER="/rest/api/2/user?username=jdoe|200|application/json|-|$API/user.json|GET"

table "$GET_ISSUE" "$USER" "$ATTACH" "$PUT_ISSUE"
jp update "$ISSUE" "$STORY"
[[ $RC -eq 0 ]] && has "$OUT" "JIRA=dry-run" && has "$OUT" "UPDATED=$UPDATED" && [[ "$(methods)" == "GET GET" ]]
check "update dry run: reads, sends nothing" $? "exit=$RC, out: $OUT, log: $(log), err: $ERR"
has "$OUT" '`flow diagram.png` is attached already, with the same size' && has "$OUT" '`spec.pdf` is attached already, with another size' \
  && has "$OUT" "$DOC/attachments/spec.pdf" && ! printf '%s\n' "$OUT" | sed -n '/^ATTACHMENTS:/,/^NOTES:/p' | grep -q 'flow diagram'
check "update dry run: the same file is not uploaded twice" $? "out: $OUT"
has "$OUT" "uses {color}, {panel}, which Markdown cannot hold"
check "update dry run: macros the file cannot hold are named" $? "out: $OUT"
p="$(printf '%s\n' "$OUT" | sed -n 's/^PREVIEW=//p')"
[[ -f "$p" ]] && diff -q "$p" "$GOLDEN/publish.wiki" >/dev/null
check "update dry run: the preview is the converted file" $? "preview: $p"
has "$OUT" "mentions [~jdoe] (John Doe); Jira notifies them." && grep -q '^https://jira.example.com/rest/api/2/user?username=jdoe	' "$FAKE_CURL_LOG"
check "update dry run: a mention is looked up and named" $? "out: $OUT, log: $(log)"
d="$(printf '%s\n' "$OUT" | sed -n 's/^DIFF=//p')"
[[ -f "$d" ]] && [[ "$(sed -n 1p "$d")" == "--- ABC-123, as it is now (updated $UPDATED)" ]] && [[ "$(sed -n 2p "$d")" == "+++ $STORY" ]] \
  && grep -qx -- '-red and boxed' "$d" && grep -qx -- '+## Design' "$d" && has "$OUT" "Publishing changes the description:"
check "update dry run: DIFF= is the description now against the file" $? "out: $OUT, diff: $(cat "$d" 2>/dev/null | head -20)"

# A file read from the issue and left as it is changes nothing, and says so.
mkdir -p "$TMP/same"
"$ENGINE/.sdd/skills/jira/scripts/jira-fetch.sh" "$ISSUE" --from-file "$API/issue.json" --out "$TMP/same/issue.md" >/dev/null 2>&1
jp update "$ISSUE" "$TMP/same/issue.md"
[[ $RC -eq 0 ]] && ! has "$OUT" "DIFF=" && has "$OUT" "publishing it changes no text"
check "update dry run: an unedited fetched file has no DIFF=" $? "exit=$RC, out: $OUT, err: $ERR"
has "$OUT" "FILE_UPDATED=2026-11-01 10:00 +0100" && ! has "$OUT" "has been updated since"
check "update dry run: a file read at the current update is not warned about" $? "out: $OUT"

sed -i.bak 's/Updated: 2026-11-01 10:00 +0100/Updated: 2026-11-01 09:58 +0100/' "$TMP/same/issue.md"
jp update "$ISSUE" "$TMP/same/issue.md"
first="$(printf '%s\n' "$OUT" | sed -n '/^NOTES:/{n;p;}')"
[[ $RC -eq 0 ]] && [[ "$first" == "The file was read when the issue was last updated 2026-11-01 09:58 +0100; it has been updated since, 2026-11-01 10:00 +0100."* ]]
check "update dry run: a file read before the last update — warned first" $? "exit=$RC, out: $OUT"
sed -i.bak 's/Updated: 2026-11-01 09:58 +0100/Updated: 2026-11-01/' "$TMP/same/issue.md"
jp update "$ISSUE" "$TMP/same/issue.md"
[[ $RC -eq 0 ]] && ! has "$OUT" "has been updated since"
sed -i.bak 's/Updated: 2026-11-01/Updated: 2026-10-31/' "$TMP/same/issue.md"
jp update "$ISSUE" "$TMP/same/issue.md"
[[ $RC -eq 0 ]] && has "$OUT" "last updated 2026-10-31; it has been updated since"
check "update dry run: an older file's date-only header is compared by the day" $? "exit=$RC, out: $OUT"

# @name that is no user stays text; \@ and a literal @ read from Jira stay text.
printf '# T\n\nUse **@Version** and \\@Override, ask @jdoe.\n' > "$TMP/at.md"
: > "$FAKE_CURL_LOG"
jp update "$ISSUE" "$TMP/at.md"
p="$(printf '%s\n' "$OUT" | sed -n 's/^PREVIEW=//p')"
[[ $RC -eq 0 ]] && [[ "$(cat "$p")" == 'Use *@Version* and @Override, ask [~jdoe].' ]] \
  && has "$OUT" "No Jira user is called @Version: published as text" && has "$OUT" "mentions [~jdoe] (John Doe)" \
  && [[ "$(grep -c 'user?username=' "$FAKE_CURL_LOG")" == 2 ]]
check "update dry run: a name no user has is published as text" $? "exit=$RC, out: $OUT, wiki: $(cat "$p" 2>/dev/null), log: $(log)"
printf '{"key":"ABC-123","fields":{"summary":"T","description":"Use @Version and *@Override*, ask [~jdoe]; mail me@x.com, {{@Keep}}."}}' > "$TMP/at.json"
"$ENGINE/.sdd/skills/jira/scripts/jira-fetch.sh" "$ISSUE" --from-file "$TMP/at.json" --out "$TMP/at/issue.md" >/dev/null 2>&1
grep -qxF 'Use \@Version and **\@Override**, ask @jdoe; mail me@x.com, `@Keep`.' "$TMP/at/issue.md"
check "fetch: a literal @ is written \\@, a mention @name" $? "$(cat "$TMP/at/issue.md")"
jp update "$ISSUE" "$TMP/at/issue.md" --convert-only
[[ "$(cat "$TMPDIR/jira-publish/converted/description.wiki")" == 'Use @Version and *@Override*, ask [~jdoe]; mail me@x.com, {{@Keep}}.' ]]
check "round trip: fetched and published back, only the mention is one" $? "wiki: $(cat "$TMPDIR/jira-publish/converted/description.wiki")"

: > "$FAKE_CURL_LOG"
jp update "$ISSUE" "$STORY" --yes
[[ $RC -eq 2 && ! -s "$FAKE_CURL_LOG" ]] && has "$ERR" "needs --base-updated"
check "update --yes without --base-updated: refused before any request" $? "exit=$RC, err: $ERR, log: $(log)"

: > "$FAKE_CURL_LOG"
jp update "$ISSUE" "$STORY" --yes --base-updated 2026-10-01T00:00:00.000+0100
[[ $RC -eq 5 && "$(methods)" == GET ]] && has "$ERR" "changed since" && has "$ERR" "hint:"
check "update --yes on a changed issue: conflict, nothing sent" $? "exit=$RC, err: $ERR, log: $(log)"

: > "$FAKE_CURL_LOG"
jp update "$ISSUE" "$STORY" --yes --base-updated "$UPDATED"
[[ $RC -eq 0 && "$(methods)" == "GET GET POST PUT" ]] && has "$OUT" "JIRA=published" && ! has "$OUT" "DIFF="
check "update --yes: attachments first, then the description" $? "exit=$RC, out: $OUT, err: $ERR, log: $(log)"
grep -q 'filename="spec.pdf";type=application/pdf' "$FAKE_CURL_LOG" && ! grep -q 'flow diagram' "$FAKE_CURL_LOG"
check "update --yes: uploads what changed, with its type" $? "log: $(log)"
[[ "$(jq -r '.fields.description' "$TMP/bodies/4.body")" == "$(cat "$GOLDEN/publish.wiki")" ]] \
  && [[ "$(jq -r '.fields | keys | join(",")' "$TMP/bodies/4.body")" == description ]]
check "update --yes: sends the description and nothing else" $? "body: $(cat "$TMP/bodies/4.body" 2>/dev/null | head -c 300)"
[[ "$(cut -f2 "$FAKE_CURL_LOG" | sort -u)" == "Authorization: Bearer tok" ]] && ! grep -qv '^https://jira.example.com/' "$FAKE_CURL_LOG"
check "update --yes: the token goes with every request, to the issue's host only" $? "log: $(log)"

: > "$FAKE_CURL_LOG"
jp update "$ISSUE" --summary "New summary" --yes --base-updated "$UPDATED"
[[ $RC -eq 0 && "$(methods)" == "GET PUT" ]] && [[ "$(jq -c '.fields' "$TMP/bodies/2.body")" == '{"summary":"New summary"}' ]]
check "update --summary alone: the summary and nothing else" $? "exit=$RC, err: $ERR, log: $(log)"

table "$GET_ISSUE" "$USER" "/rest/api/2/issue/ABC-123/attachments|500|application/json|-|-|POST" "$PUT_ISSUE"
jp update "$ISSUE" "$STORY" --yes --base-updated "$UPDATED"
[[ $RC -eq 3 && "$(methods)" == "GET GET POST" ]] && has "$ERR" "500"
check "update --yes: a failed upload stops before the description" $? "exit=$RC, err: $ERR, log: $(log)"

table "$GET_ISSUE" "$USER" "$ATTACH" "/rest/api/2/issue/ABC-123|400|application/json|-|$API/error400.json|PUT"
jp update "$ISSUE" "$STORY" --yes --base-updated "$UPDATED"
[[ $RC -eq 6 ]] && has "$OUT" "JIRA=partial" && has "$OUT" "$DOC/attachments/spec.pdf" && has "$ERR" "cannot be set"
check "update --yes: a refusal after an upload is partial, and says what was done" $? "exit=$RC, out: $OUT, err: $ERR"

table "/rest/api/2/issue/ABC-123|401|application/json|-|-"
jp update "$ISSUE" "$STORY"
[[ $RC -eq 3 ]] && has "$ERR" "token was rejected"
check "update: 401 names the token" $? "exit=$RC, err: $ERR"

table "/rest/api/2/issue/ABC-123|302|text/html|https://sso.example.net/login|-"
jp update "$ISSUE" "$STORY"
[[ $RC -eq 3 ]] && has "$ERR" "behind SSO" && ! grep -q sso.example.net "$FAKE_CURL_LOG"
check "update: SSO redirect is reported, not followed" $? "exit=$RC, err: $ERR"

tokens ""
table "/|200|application/json|-|$API/issue.json"
jp update "$ISSUE" "$STORY"
[[ $RC -eq 1 && ! -s "$FAKE_CURL_LOG" ]] && has "$ERR" "no JIRA_TOKEN"
check "update: no token, no request" $? "exit=$RC, err: $ERR"

tokens "JIRA_TOKEN=tok"
jp update ABC-123 "$STORY"
[[ $RC -eq 1 && ! -s "$FAKE_CURL_LOG" ]] && has "$ERR" "no JIRA_URL"
check "update: a bare key needs JIRA_URL" $? "exit=$RC, err: $ERR"

# ── create ────────────────────────────────────────────────────────
tokens "JIRA_TOKEN=tok" "JIRA_URL=https://jira.example.com"
GET_PROJECT="/rest/api/2/project/ABC|200|application/json|-|$API/project.json|GET"
POST_ISSUE="/rest/api/2/issue|201|application/json|-|$API/created.json|POST"
ATTACH_NEW="/rest/api/2/issue/ABC-124/attachments|200|application/json|-|$API/attached.json|POST"

USER="/rest/api/2/user?username=jdoe|200|application/json|-|$API/user.json|GET"
table "$GET_PROJECT" "$USER" "$ATTACH_NEW" "$POST_ISSUE"
jp create --project ABC --type story "$STORY"
[[ $RC -eq 0 && "$(methods)" == "GET GET" ]] && has "$OUT" "JIRA=dry-run" && has "$OUT" "TYPE=Story" \
  && has "$OUT" "SUMMARY=Send order confirmations by email" && has "$OUT" "$DOC/attachments/flow diagram.png"
check "create dry run: checks the project and type, sends nothing" $? "exit=$RC, out: $OUT, err: $ERR, log: $(log)"

jp create --project ABC --type Epic "$STORY"
[[ $RC -eq 2 ]] && has "$ERR" 'no issue type "Epic"' && has "$ERR" "Story, Bug, Sub-task"
check "create: an unknown type names the project's types" $? "exit=$RC, err: $ERR"

jp create --project ABC --type Sub-task "$STORY"
[[ $RC -eq 2 ]] && has "$ERR" "needs --parent"
check "create: a sub-task needs a parent" $? "exit=$RC, err: $ERR"

: > "$FAKE_CURL_LOG"
jp create --project https://jira.example.com/projects/ABC/summary --type Story --label email --label sdd "$STORY" --yes
[[ $RC -eq 0 && "$(methods)" == "GET GET POST POST POST" ]] && has "$OUT" "JIRA=published" && has "$OUT" "KEY=ABC-124" \
  && has "$OUT" "URL=https://jira.example.com/browse/ABC-124"
check "create --yes: the issue, then its attachments" $? "exit=$RC, out: $OUT, err: $ERR, log: $(log)"
[[ "$(jq -c '.fields | {project, issuetype, summary, labels}' "$TMP/bodies/3.body")" == \
   '{"project":{"key":"ABC"},"issuetype":{"name":"Story"},"summary":"Send order confirmations by email","labels":["email","sdd"]}' ]] \
  && [[ "$(jq -r '.fields.description' "$TMP/bodies/3.body")" == "$(cat "$GOLDEN/publish.wiki")" ]]
check "create --yes: the fields sent" $? "body: $(cat "$TMP/bodies/3.body" 2>/dev/null | head -c 400)"
[[ "$(grep -c '/rest/api/2/issue/ABC-124/attachments' "$FAKE_CURL_LOG")" == 2 ]]
check "create --yes: both files uploaded to the new issue" $? "log: $(log)"

table "$GET_PROJECT" "/rest/api/2/issue/ABC-1?|200|application/json|-|$API/parent.json|GET" "$POST_ISSUE" "$ATTACH_NEW"
jp create --project ABC --type Sub-task --parent https://jira.example.com/browse/ABC-1 --summary "A sub-task" --yes
[[ $RC -eq 0 && "$(methods)" == "GET GET POST" ]] && has "$OUT" "PARENT=ABC-1" \
  && [[ "$(jq -c '.fields | {parent, summary, d: has("description")}' "$TMP/bodies/3.body")" == '{"parent":{"key":"ABC-1"},"summary":"A sub-task","d":false}' ]]
check "create --yes: a sub-task under its parent, no file" $? "exit=$RC, out: $OUT, err: $ERR, body: $(cat "$TMP/bodies/3.body" 2>/dev/null)"

table "$GET_PROJECT" "$USER" "/rest/api/2/issue|400|application/json|-|$API/error400.json|POST"
jp create --project ABC --type Story --label x "$STORY" --yes
[[ $RC -eq 3 ]] && has "$ERR" "labels: Field 'labels' cannot be set" && ! has "$OUT" "JIRA=partial"
check "create --yes: a refusal quotes Jira and writes nothing" $? "exit=$RC, out: $OUT, err: $ERR"

table "$GET_PROJECT" "$USER" "$POST_ISSUE" "/rest/api/2/issue/ABC-124/attachments|403|application/json|-|-|POST"
jp create --project ABC --type Story "$STORY" --yes
[[ $RC -eq 6 ]] && has "$OUT" "JIRA=partial" && has "$OUT" "KEY=ABC-124" && has "$OUT" "URL=https://jira.example.com/browse/ABC-124"
check "create --yes: an upload refused after the create is partial and names the issue" $? "exit=$RC, out: $OUT, err: $ERR"

# ── attach ────────────────────────────────────────────────────────
printf 'LOG' > "$TMP/run.log"
table "$GET_ISSUE" "$ATTACH"
jp attach "$ISSUE" "$TMP/run.log" "$DOC/attachments/flow diagram.png"
[[ $RC -eq 0 && "$(methods)" == GET ]] && has "$OUT" "$TMP/run.log" && has "$OUT" '`flow diagram.png` is attached already'
check "attach dry run: lists what would go, skips what is there" $? "exit=$RC, out: $OUT, err: $ERR"
: > "$FAKE_CURL_LOG"
jp attach "$ISSUE" "$TMP/run.log" --yes
[[ $RC -eq 0 && "$(methods)" == "GET POST" ]] && grep -q 'filename="run.log";type=text/plain' "$FAKE_CURL_LOG"
check "attach --yes: uploads, with no base needed" $? "exit=$RC, out: $OUT, err: $ERR, log: $(log)"
jp attach "$ISSUE" "$TMP/nowhere.txt"
[[ $RC -eq 2 ]] && has "$ERR" "cannot read"
check "attach: a missing file" $? "exit=$RC, err: $ERR"

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
(( FAILED > 0 )) && exit 2
exit 0
