#!/usr/bin/env bash
# The import of a Jira issue into a feature's raw.md.
#
# Reading the issue is the jira skill's: the request, the config keys,
# the wiki-markup conversion and the attachments all live in its script, and
# this one runs it with --out pointed at raw.md. What is left here is what only
# the flow cares about — the two sections it reads by name, appended with the
# hint text of .sdd/templates/raw.md. Nothing about the issue's meaning is
# decided here. /sdd-next-story calls it after gate.sh has agreed the feature
# may be created.
#
# Usage: jira-import.sh <issue-url-or-key> --out <path> [--root <dir>] [--from-file <json>]
#
# Prints the skill's report — KEY=value lines, then ATTACHMENTS: and NOTES:
# blocks — with this script's own notes added at the end of NOTES:. Exit codes
# are the skill's: 0 — the file was written; 1 — the environment is wrong (no
# curl, no jq, no token, no JIRA_URL for a bare key, no skill, no library);
# 2 — usage; 3 — the issue could not be read (HTTP error, SSO redirect, not
# found); 4 — the answer was unusable. On any exit but 0, --out is untouched.

set -uo pipefail
[[ -r "$(dirname "$0")/lib/log.sh" ]] && . "$(dirname "$0")/lib/log.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -r "$SCRIPT_DIR/lib/format.sh" ]]; then
  printf 'ERROR=missing: %s/lib/format.sh\n' "$SCRIPT_DIR" >&2
  exit 1
fi
# `md_uncomment` is what finds a heading in .sdd/templates/raw.md and in the
# issue's own text, the same reader everywhere under _docs/.
. "$SCRIPT_DIR/lib/format.sh"

# ── Arguments ─────────────────────────────────────────────────────
ROOT_DIR="."
OUT=""
FROM_FILE=""
ARGS=()
while (( $# > 0 )); do
  case "$1" in
    --root)      ROOT_DIR="${2:-}"; shift ;;
    --out)       OUT="${2:-}"; shift ;;
    --from-file) FROM_FILE="${2:-}"; shift ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
set -- ${ARGS[@]+"${ARGS[@]}"}

[[ -d "$ROOT_DIR" ]] || { printf 'ERROR=not a directory: %s\n' "$ROOT_DIR" >&2; exit 1; }
cd "$ROOT_DIR" || exit 1

ARG="${1:-}"
[[ -n "$ARG" ]] || { printf 'ERROR=no issue — jira-import.sh <issue-url-or-key> --out <path>\n' >&2; exit 2; }
[[ -n "$OUT" ]] || { printf 'ERROR=no --out — jira-import.sh <issue-url-or-key> --out <path>\n' >&2; exit 2; }

# ── The skill ─────────────────────────────────────────────────────
# Where the installer put it depends on the host: .claude/skills/ or
# .github/skills/ in a project, .sdd/skills/ in the engine's own clone. The
# first one found is the one run.
SKILL_SH=""
for dir in "$SCRIPT_DIR/../skills" "$SCRIPT_DIR/../../.claude/skills" "$SCRIPT_DIR/../../.github/skills"; do
  if [[ -r "$dir/jira/scripts/jira-fetch.sh" ]]; then
    SKILL_SH="$dir/jira/scripts/jira-fetch.sh"
    break
  fi
done
if [[ -z "$SKILL_SH" ]]; then
  printf 'ERROR=missing: the jira skill (jira/scripts/jira-fetch.sh under .claude/skills/ or .github/skills/)\n' >&2
  printf 'hint: re-run the SDD Kit installer for this project\n' >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sdd-jira.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

# The skill looks for no config of its own: it is handed the engine's two
# files, those that exist, in the engine's order — the token file in the home
# directory, then the project's .sdd/sdd.conf, which overrides it. The
# environment fills in only what neither file set.
TOKENS=()
for f in "${HOME:-}/.config/sdd-kit/tokens.env" ".sdd/sdd.conf"; do
  [[ -f "$f" && -r "$f" ]] && TOKENS+=(--tokens "$f")
done

# The skill writes --out only when it ends with 0, so a failure leaves raw.md
# exactly as it was. Its stderr goes straight through: ERROR= and hint: are
# meant for the human.
bash "$SKILL_SH" "$ARG" --out "$OUT" ${TOKENS[@]+"${TOKENS[@]}"} ${FROM_FILE:+--from-file "$FROM_FILE"} > "$TMP/report.txt"
rc=$?
if (( rc != 0 )); then
  # The skill's hint speaks of --tokens, which the human never types here; the
  # files the engine would have passed are what they can fix.
  if (( rc == 1 )) && [[ -z "${TOKENS[*]+x}" ]]; then
    printf 'hint: the import reads JIRA_URL and JIRA_TOKEN from %s and .sdd/sdd.conf; neither exists\n' \
      "${HOME:-~}/.config/sdd-kit/tokens.env" >&2
  fi
  cat "$TMP/report.txt"
  exit "$rc"
fi

NOTES=(); N_NOTE=0
note() { NOTES+=("$1"); N_NOTE=$(( N_NOTE + 1 )); }

# ── The two sections the flow reads by name ───────────────────────
# `## Known constraints` and `## Out of scope` are the only headings anything
# reads by name (.sdd/protocols/architecture-design.md, spec-checklist.md), and
# the human fills them in after the import. Their hint text is copied out of
# .sdd/templates/raw.md rather than repeated here, so it stays one text.
TEMPLATE_RAW="$SCRIPT_DIR/../templates/raw.md"

# The heading and everything under it, up to the next heading of the same level.
section_of() {
  local file="$1" heading="$2"
  awk -v want="$heading" '
    $0 == want { inside = 1; print; next }
    inside && /^## / { inside = 0 }
    inside { print }
  ' "$file"
}

# Whether the issue already brought a heading of that name. A heading written
# inside an HTML comment is not a heading.
has_heading() {
  local file="$1" heading="$2"
  md_uncomment "$file" | LC_ALL=C grep -qxF "$heading"
}

cp "$OUT" "$TMP/raw.md" || { printf 'ERROR=cannot read %s\n' "$OUT" >&2; exit 1; }
for heading in '## Known constraints' '## Out of scope'; do
  if has_heading "$OUT" "$heading"; then
    note "The issue already carries a \`$heading\` heading; it was not appended a second time."
    continue
  fi
  body=""
  [[ -r "$TEMPLATE_RAW" ]] && body="$(section_of "$TEMPLATE_RAW" "$heading")"
  [[ -n "$body" ]] || body="$heading"
  printf '\n%s\n' "$body" >> "$TMP/raw.md"
done

cat "$TMP/raw.md" > "$OUT" || { printf 'ERROR=could not write %s\n' "$OUT" >&2; exit 1; }

# ── The report ────────────────────────────────────────────────────
# LINES= is counted again, the sections included. NOTES: is the skill's last
# block, so this script's notes go after it.
lines="$(wc -l < "$OUT" | tr -d ' ')"
sed "s/^LINES=.*/LINES=$lines/" "$TMP/report.txt"
(( N_NOTE > 0 )) && printf '%s\n' "${NOTES[@]}"
exit 0
