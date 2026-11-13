#!/usr/bin/env bash
# A stand-in for curl, put first on PATH by run.sh. It answers from the table in
# $FAKE_CURL_TABLE: one line per rule, tab-separated —
#   <substring of the URL>  <http code>  <content type>  <redirect url or ->  <body file or ->  [<method>]
# the first rule whose substring the URL contains, and whose method — when the
# rule names one — is the request's, wins; no rule is a 404.
# Every call is appended to $FAKE_CURL_LOG as
#   "<url>\t<authorization header>\t<method>\t<-F parts, joined by ' && '>"
# and when $FAKE_CURL_BODIES names a directory, the file a --data-binary @file
# sent is copied there as <call number>.body, the call number being the line
# of the log.

out=""; fmt=""; url=""; auth=""; get=0; data=(); method=""; body_in=""; forms=""
while (( $# > 0 )); do
  case "$1" in
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -X) method="$2"; shift ;;
    -H) [[ "$2" == Authorization:* ]] && auth="$2"; shift ;;
    -F) forms="${forms:+$forms && }$2"; shift ;;
    --data-binary) body_in="${2#@}"; shift ;;
    -G) get=1 ;;
    --data-urlencode) data+=("$2"); shift ;;
    -s|-S|-sS) ;;
    *) url="$1" ;;
  esac
  shift
done
if [[ -z "$method" ]]; then
  if [[ -n "$forms" || -n "$body_in" ]]; then method=POST; else method=GET; fi
fi
if (( get )) && (( ${#data[@]} > 0 )); then
  q=""
  for d in "${data[@]}"; do q="${q:+$q&}$d"; done
  url="$url?$q"
fi
printf '%s\t%s\t%s\t%s\n' "$url" "$auth" "$method" "$forms" >> "$FAKE_CURL_LOG"
if [[ -n "${FAKE_CURL_BODIES:-}" && -n "$body_in" ]]; then
  n="$(wc -l < "$FAKE_CURL_LOG" | tr -d ' ')"
  cp "$body_in" "$FAKE_CURL_BODIES/$n.body"
fi

code=404; ctype="text/html"; redir=""; body=""
while IFS=$'\t' read -r sub c t r b m; do
  [[ -z "$sub" || "$sub" == \#* ]] && continue
  [[ -n "${m:-}" && "$m" != "$method" ]] && continue
  if [[ "$url" == *"$sub"* ]]; then
    code="$c"; ctype="$t"; [[ "$r" != - ]] && redir="$r"; [[ "$b" != - ]] && body="$b"
    break
  fi
done < "$FAKE_CURL_TABLE"

if [[ -n "$out" ]]; then
  if [[ -n "$body" ]]; then cat "$body" > "$out"; else : > "$out"; fi
fi
if [[ "$fmt" == *content_type* ]]; then
  printf '%s\n%s\n%s\n' "$code" "$ctype" "$redir"
elif [[ -n "$fmt" ]]; then
  printf '%s' "$code"
fi
exit 0
