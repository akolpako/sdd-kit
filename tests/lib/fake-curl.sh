#!/usr/bin/env bash
# A stand-in for curl, put first on PATH by run.sh. It answers from the table in
# $FAKE_CURL_TABLE: one line per rule, tab-separated —
#   <substring of the URL>  <http code>  <content type>  <redirect url or ->  <body file or ->
# the first rule whose substring the URL contains wins; no rule is a 404.
# Every call is appended to $FAKE_CURL_LOG as "<url>\t<authorization header>".

out=""; fmt=""; url=""; auth=""; get=0; data=()
while (( $# > 0 )); do
  case "$1" in
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -H) [[ "$2" == Authorization:* ]] && auth="$2"; shift ;;
    -G) get=1 ;;
    --data-urlencode) data+=("$2"); shift ;;
    -s|-S|-sS) ;;
    *) url="$1" ;;
  esac
  shift
done
if (( get )) && (( ${#data[@]} > 0 )); then
  q=""
  for d in "${data[@]}"; do q="${q:+$q&}$d"; done
  url="$url?$q"
fi
printf '%s\t%s\n' "$url" "$auth" >> "$FAKE_CURL_LOG"

code=404; ctype="text/html"; redir=""; body=""
while IFS=$'\t' read -r sub c t r b; do
  [[ -z "$sub" || "$sub" == \#* ]] && continue
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
