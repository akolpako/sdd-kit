#!/usr/bin/env bash
# The tests of the jira-fetch skill.
#
# It runs on its own — `tests/jira-fetch/run.sh [--update]` — and from
# `tests/run.sh`, which folds the verdict on the last line into its own count.
#
# Nothing here reaches the network: curl is replaced on PATH by ../lib/fake-curl.sh,
# which answers from a table each case writes and logs every request it got.
# So what is checked is the script's side of the wire — which URL it asks for,
# that the token goes along and nowhere else, what each answer turns into —
# not that a real Jira answers the way the fixtures say it does.
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
JF="$ENGINE/.sdd/skills/jira-fetch/scripts/jira-fetch.sh"
FIX="$SCRIPT_DIR/fixtures"
GOLDEN="$SCRIPT_DIR/golden"
UPDATE=0
[[ "${1:-}" == --update ]] && UPDATE=1

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sdd-jira.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd)" || exit 1
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export TMPDIR="$TMP/tmp"
mkdir -p "$HOME/.config/sdd-kit" "$TMPDIR" "$TMP/bin" || exit 1
ln -s "$SCRIPT_DIR/../lib/fake-curl.sh" "$TMP/bin/curl" || exit 1
export PATH="$TMP/bin:$PATH"
export FAKE_CURL_TABLE="$TMP/table.tsv"
export FAKE_CURL_LOG="$TMP/curl.log"
unset JIRA_URL JIRA_TOKEN

PASSED=0
FAILED=0
check() {
  local label="$1" ok="$2" why="${3:-}"
  if (( ok == 0 )); then PASSED=$(( PASSED + 1 ))
  else FAILED=$(( FAILED + 1 )); printf '  FAILED   jira-fetch %s — %s\n' "$label" "$why"; fi
}

# Runs the script with the case's tokens file; leaves OUT, ERR and RC.
jf() {
  OUT="$("$JF" --tokens "$TMP/tokens.env" "$@" 2>"$TMP/err.txt")"; RC=$?
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

printf 'jira-fetch\n'

# ── Conversion, against goldens ───────────────────────────────────
tokens ""
jf https://jira.example.com/browse/ABC-123 --from-file "$FIX/issue.json" --out "$TMP/g1/issue.md"
check "issue: exit 0" "$RC" "exit=$RC, err: $ERR"
golden "issue: markdown" "$GOLDEN/issue.md" "$TMP/g1/issue.md"
printf '%s\n' "$OUT" | sed "s#$TMP#<TMP>#g" > "$TMP/g1/report.txt"
golden "issue: report" "$GOLDEN/issue.report.txt" "$TMP/g1/report.txt"

jf https://jira.example.com/browse/ABC-7 --from-file "$FIX/edge.json" --out "$TMP/g2/issue.md"
check "edge: exit 0" "$RC" "exit=$RC, err: $ERR"
golden "edge: markdown" "$GOLDEN/edge.md" "$TMP/g2/issue.md"

# A bare key read from a file finds its instance in `self`.
jf ABC-123 --from-file "$FIX/issue.json" --out "$TMP/g3/issue.md"
[[ $RC -eq 0 ]] && has "$OUT" "URL=https://jira.example.com/browse/ABC-123"
check "bare key: instance from self" $? "exit=$RC, out: $OUT, err: $ERR"

jf ABC-9 --from-file "$FIX/empty.json" --out "$TMP/g4/issue.md"
[[ $RC -eq 1 && ! -e "$TMP/g4/issue.md" ]] && has "$ERR" "no JIRA_URL"
check "bare key: no self, no JIRA_URL" $? "exit=$RC, err: $ERR"

jf https://jira.example.com/browse/ABC-9 --from-file "$FIX/empty.json" --out "$TMP/g5/issue.md"
[[ $RC -eq 0 ]] && has "$OUT" "The issue has an empty description." && has "$OUT" "no summary" \
  && [[ "$(cat "$TMP/g5/issue.md")" == "# ABC-9"$'\n\n'"https://jira.example.com/browse/ABC-9" ]]
check "empty: title and link only" $? "exit=$RC, out: $OUT, file: $(cat "$TMP/g5/issue.md" 2>/dev/null)"

jf https://jira.example.com/browse/ABC-9 --from-file "$FIX/not-issue.json" --out "$TMP/g6/issue.md"
[[ $RC -eq 4 && ! -e "$TMP/g6/issue.md" ]] && has "$ERR" "not an issue"
check "not an issue: refused" $? "exit=$RC, err: $ERR"

jf https://jira.example.com/browse/ABC-123 --from-file "$FIX/issue.json"
[[ $RC -eq 0 && -f "$TMPDIR/jira-fetch/ABC-123/issue.md" ]] && has "$OUT" "OUT=$TMPDIR/jira-fetch/ABC-123/issue.md"
check "default --out under TMPDIR" $? "exit=$RC, out: $OUT"

# ── Arguments ─────────────────────────────────────────────────────
parse() {
  local label="$1" want="$2" arg="$3" got
  jf "$arg" --parse-only
  got="$(printf "%s" "$OUT" | tr "\n" " ")"; got="${got% }"
  [[ $RC -eq 0 && "$got" == "$want" ]]
  check "arg: $label" $? "exit=$RC, got: $got"
}
parse "browse"        "KEY=ABC-1 BASE=https://j.example.com" "https://j.example.com/browse/ABC-1"
parse "context path"  "KEY=ABC-1 BASE=https://j.example.com/jira" "https://j.example.com/jira/browse/ABC-1"
parse "query, anchor" "KEY=ABC-1 BASE=https://j.example.com" "https://j.example.com/browse/ABC-1?focusedCommentId=5#comment-5"
parse "projects"      "KEY=AB_C-12 BASE=https://j.example.com" "https://j.example.com/projects/AB_C/issues/AB_C-12?filter=all"
parse "board"         "KEY=ABC-3 BASE=https://j.example.com" "https://j.example.com/secure/RapidBoard.jspa?rapidView=7&selectedIssue=ABC-3"
parse "bare key"      "KEY=ABC-1 BASE=" "ABC-1"

for bad in Cart abc-1 https://j.example.com/browse/ https://j.example.com/browse/abc-1 https://j.example.com/projects/ABC; do
  jf "$bad" --parse-only
  [[ $RC -eq 2 ]] && has "$ERR" "ERROR=not an issue key" && has "$ERR" "hint:"
  check "arg: rejects $bad" $? "exit=$RC, err: $ERR"
done

# ── Config ────────────────────────────────────────────────────────
# Run without the helper: each case names its own files.
raw() { OUT="$("$JF" "$@" 2>"$TMP/err.txt")"; RC=$?; ERR="$(cat "$TMP/err.txt")"; }

tokens '# comment' 'export JIRA_URL="https://home.example.com/"' "JIRA_TOKEN='t1'" 'CONFLUENCE_URL=https://c' 'OTHER=x'
raw ABC-1 --parse-only --tokens "$TMP/tokens.env"
has "$OUT" "BASE=https://home.example.com"
check "config: tokens file, quotes, export, trailing slash" $? "got: $OUT"

printf 'JIRA_URL=https://proj.example.com\nSDD_BUILD_ROOT=mvn verify\n' > "$TMP/proj.env"
raw ABC-1 --parse-only --tokens "$TMP/tokens.env" --tokens "$TMP/proj.env"
has "$OUT" "BASE=https://proj.example.com"
check "config: a later file wins" $? "got: $OUT"

OUT="$(JIRA_URL=https://env.example.com "$JF" ABC-1 --parse-only --tokens "$TMP/tokens.env" 2>&1)"
has "$OUT" "BASE=https://home.example.com"
check "config: a file over the environment" $? "got: $OUT"

printf 'JIRA_TOKEN=t2\n' > "$TMP/token-only.env"
OUT="$(JIRA_URL=https://env.example.com "$JF" ABC-1 --parse-only --tokens "$TMP/token-only.env" 2>&1)"
has "$OUT" "BASE=https://env.example.com"
check "config: the environment fills in what no file set" $? "got: $OUT"

raw ABC-1 --parse-only --tokens "$TMP/nowhere.env"
[[ $RC -eq 1 ]] && has "$ERR" "cannot read the tokens file: $TMP/nowhere.env"
check "config: a missing tokens file is an error" $? "exit=$RC, err: $ERR"

# No file is looked for: a token in the SDD kit's file is not read unless passed.
printf 'JIRA_TOKEN=home\nJIRA_URL=https://home.example.com\n' > "$HOME/.config/sdd-kit/tokens.env"
mkdir -p "$TMP/proj/.sdd" && cp "$HOME/.config/sdd-kit/tokens.env" "$TMP/proj/.sdd/sdd.conf"
table "/|200|application/json|-|-"
OUT="$(cd "$TMP/proj" && "$JF" https://jira.example.com/browse/ABC-1 --out "$TMP/c1/out.md" 2>&1)"; RC=$?
[[ $RC -eq 1 && ! -s "$FAKE_CURL_LOG" ]] && has "$OUT" "no JIRA_TOKEN" && has "$OUT" "--tokens <file> (none was passed)"
check "config: no file is read unless passed" $? "exit=$RC, out: $OUT"
rm -f "$HOME/.config/sdd-kit/tokens.env"

# ── Requests ──────────────────────────────────────────────────────
ISSUE=https://jira.example.com/browse/ABC-123

tokens "JIRA_TOKEN=tok"
table "/rest/api/2/issue/ABC-123|200|application/json;charset=UTF-8|-|$FIX/issue.json" \
      "/secure/attachment/1/|200|image/png|-|$FIX/att.bin" \
      "/secure/attachment/3/|200|application/pdf|-|$FIX/att.bin"
jf "$ISSUE" --out "$TMP/r1/issue.md"
check "fetch: exit 0" "$RC" "exit=$RC, err: $ERR"
grep -q 'rest/api/2/issue/ABC-123?fields=summary,description,attachment,' "$FAKE_CURL_LOG"
check "fetch: asks for the fields" $? "log: $(cat "$FAKE_CURL_LOG")"
[[ "$(cut -f2 "$FAKE_CURL_LOG" | sort -u)" == "Authorization: Bearer tok" ]]
check "fetch: every request carries the token" $? "log: $(cat "$FAKE_CURL_LOG")"
! grep -qv '^https://jira.example.com/' "$FAKE_CURL_LOG"
check "fetch: nothing goes to another host" $? "log: $(cat "$FAKE_CURL_LOG")"
grep -q '/secure/attachment/3/spec.pdf' "$FAKE_CURL_LOG" && ! grep -q '/secure/attachment/2/' "$FAKE_CURL_LOG"
check "fetch: a re-uploaded name takes the newest file" $? "log: $(cat "$FAKE_CURL_LOG")"
! grep -q 'unused.txt' "$FAKE_CURL_LOG"
check "fetch: an unreferenced attachment is left in Jira" $? "log: $(cat "$FAKE_CURL_LOG")"
[[ -f "$TMP/r1/attachments/flow diagram.png" && -f "$TMP/r1/attachments/spec.pdf" ]] \
  && has "$OUT" "$TMP/r1/attachments/spec.pdf" && has "$OUT" "$TMP/r1/attachments/flow diagram.png"
check "fetch: attachments downloaded and listed" $? "out: $OUT"
has "$OUT" '`contract v1.docx` was not downloaded: it is on another host'
check "fetch: an attachment on another host is not downloaded" $? "out: $OUT"
[[ ! -e "$TMP/escape.png" ]] && has "$OUT" '`../../escape.png` was not downloaded: an attachment name may not be a path'
check "fetch: an attachment name is never a path" $? "out: $OUT"
has "$OUT" '`missing.png` is referenced by the description but is not attached'
check "fetch: a missing attachment is noted" $? "out: $OUT"
diff -q "$TMP/r1/issue.md" "$GOLDEN/issue.md" >/dev/null
check "fetch: same Markdown as from a file" $? "$(diff "$GOLDEN/issue.md" "$TMP/r1/issue.md" | head -5)"

table "/rest/api/2/issue/ABC-123|200|application/json|-|$FIX/issue.json"
jf "$ISSUE" --out "$TMP/r2/issue.md" --no-attachments
! grep -q attachment/ "$FAKE_CURL_LOG" && has "$OUT" "--no-attachments"
check "fetch: --no-attachments downloads nothing" $? "log: $(cat "$FAKE_CURL_LOG")"

jf "$ISSUE" --out "$TMP/r3/issue.md"
[[ $RC -eq 0 ]] && has "$OUT" '`spec.pdf` was not downloaded: the request answered 404' && grep -qF '(attachments/spec.pdf)' "$TMP/r3/issue.md"
check "fetch: a failed download keeps the link and is noted" $? "exit=$RC, out: $OUT"

tokens "JIRA_TOKEN=tok" "JIRA_URL=https://jira.example.com"
table "/rest/api/2/issue/ABC-123|200|application/json|-|$FIX/issue.json"
jf ABC-123 --out "$TMP/r4/issue.md" --no-attachments
[[ $RC -eq 0 ]] && grep -q '^https://jira.example.com/rest/api/2/issue/ABC-123?' "$FAKE_CURL_LOG"
check "fetch: bare key against JIRA_URL" $? "exit=$RC, err: $ERR"

table "/rest/api/2/issue/ABC-123|401|application/json|-|-"
jf "$ISSUE" --out "$TMP/r5/issue.md"
[[ $RC -eq 3 && ! -e "$TMP/r5/issue.md" ]] && has "$ERR" "token was rejected" && has "$ERR" "hint:"
check "fetch: 401 names the token, writes nothing" $? "exit=$RC, err: $ERR"

table "/rest/api/2/issue/ABC-123|403|application/json|-|-"
jf "$ISSUE" --out "$TMP/r6/issue.md"
[[ $RC -eq 3 ]] && has "$ERR" "403"
check "fetch: 403" $? "exit=$RC, err: $ERR"

table "/rest/api/2/issue/ABC-123|302|text/html|https://sso.example.net/login|-"
jf "$ISSUE" --out "$TMP/r7/issue.md"
[[ $RC -eq 3 ]] && has "$ERR" "behind SSO" && has "$ERR" "VPN" && ! grep -q sso.example.net "$FAKE_CURL_LOG"
check "fetch: SSO redirect names the VPN, is not followed" $? "exit=$RC, err: $ERR"

table "/rest/api/2/issue/ABC-123|200|text/html|-|$FIX/login.html"
jf "$ISSUE" --out "$TMP/r8/issue.md"
[[ $RC -eq 4 && ! -e "$TMP/r8/issue.md" ]] && has "$ERR" "not JSON"
check "fetch: an HTML answer is refused" $? "exit=$RC, err: $ERR"

table "/rest/api/2/issue/|404|application/json|-|-"
jf "$ISSUE" --out "$TMP/r9/issue.md"
[[ $RC -eq 3 ]] && has "$ERR" "404"
check "fetch: 404" $? "exit=$RC, err: $ERR"

tokens ""
table "/|200|application/json|-|$FIX/issue.json"
jf "$ISSUE" --out "$TMP/r10/issue.md"
[[ $RC -eq 1 && ! -s "$FAKE_CURL_LOG" ]] && has "$ERR" "no JIRA_TOKEN" && has "$ERR" "hint:"
check "fetch: no token, no request" $? "exit=$RC, err: $ERR"

tokens "JIRA_TOKEN=tok"
jf ABC-123 --out "$TMP/r11/issue.md"
[[ $RC -eq 1 && ! -s "$FAKE_CURL_LOG" ]] && has "$ERR" "no JIRA_URL"
check "fetch: bare key needs JIRA_URL" $? "exit=$RC, err: $ERR"

jf
[[ $RC -eq 2 ]]
check "usage: no argument" $? "exit=$RC"

jf ABC-1 ABC-2
[[ $RC -eq 2 ]] && has "$ERR" "one issue per call"
check "usage: one issue per call" $? "exit=$RC, err: $ERR"

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
(( FAILED > 0 )) && exit 2
exit 0
