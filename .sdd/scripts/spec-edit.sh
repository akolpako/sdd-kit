#!/usr/bin/env bash
# The mechanical writes of the flow: the edits whose format, place and date are
# fixed, so no command describes them in prose and no model retypes them.
#
# The line between this script and the model: the script owns the format, the
# place and the date; the words come from the human, the model or a role, and
# arrive as an argument. What needs a decision about content is not here.
#
# Usage: spec-edit.sh <op> [args ...] [--root <project-root>]
#
#   backup
#       Snapshot every .md under _docs/ into _docs/.backup/<YYYYMMDD-HHMMSS>/,
#       relative paths kept. No list of files to get wrong, and the state of
#       _docs/ is restorable whole. Nothing copied when nothing is there.
#   status <Feature> ready|draft <file ...>
#       Rewrite the `> Status:` line of each named file of the feature. A file
#       without that line is left alone and the op fails: a status is never
#       added where the format did not have one. A file already carrying that
#       status is printed under UNCHANGED: and not rewritten — whoever put the
#       marker there did it before this call.
#   verdict-stale <Feature>
#       Rewrite the one `> Verdict:` line of review.md to
#       `stale — fixes applied <today>`. Nothing else in the file is touched.
#   scaffold init [--mono]
#       Copy the project templates into _docs/, and say what each of them now
#       is. A file that already holds content is skipped, never discarded; a
#       file that is still the template it was copied from is listed under
#       UNTOUCHED: and left where it stands — the copy has been made and what
#       it is waiting for is somebody to write into it.
#       The architecture baseline has two shapes and a project holds one of
#       them: a folder of sections under _docs/architecture/ with a generated
#       index, which is what this writes by default, or a single
#       _docs/architecture.md, which --mono writes and which an existing one
#       keeps. MODE= says which shape the run left behind.
#   arch-index
#       Rebuild _docs/architecture.index.md from what is in
#       _docs/architecture/ right now: one row per section file, its topic
#       taken from the file's `# ` heading. The file is written whole, so a
#       section a project deleted or added is in the index without anyone
#       editing it. A project holding a single _docs/architecture.md has no
#       folder to index and this op does not apply to it.
#   scaffold feature <Feature>
#       The feature folder and raw.md from the template, the title carrying the
#       feature name. An existing raw.md with content in it is never
#       overwritten.
#   scaffold spec <Feature> <file ...>
#       The spec files this run writes — new-requirements.md, design.md, tasks.md —
#       from their templates, the title carrying the feature name. Only the
#       files named are copied, so a file the human kept is never among them,
#       and each one named is overwritten: the caller has already asked whose
#       spec may go and already made its backup.
#   scaffold review <Feature>
#       review.md from the template, the title carrying the feature name, over
#       whatever an earlier run left there. The report is a snapshot of the
#       working tree, so replacing it whole is what a re-run means.
#   marker <file> <line> <text>
#       Insert `TODO Code Review: <text> (<today>)` above that line, in the
#       comment syntax of that file type and at its indentation. An extension
#       this script has no syntax for is a stop, never a guess.
#   compile-entry <Feature> <REQ-###> final|superseded-by:<REQ-###> [<text>]
#       The entry of _docs/requirements.md: drop the `draft`
#       suffix, mark it superseded, or append a new entry and move the counter
#       past its number. The wording is the model's and arrives as <text>; an
#       entry already on file keeps its source. A number carried by two entries
#       is a stop.
#   section <file> <heading> [<text>]
#       Replace the body of `## <heading>` with the text as given. No text
#       leaves the section as it is — the template's hint stays in place.
#
# Prints KEY=value lines, then SECTION: blocks. Exit codes: 0 — the edit was
# made (or there was nothing to do and that is said); 1 — the environment is
# wrong; 2 — the project is not in a state this edit applies to, and no file
# was changed.

set -uo pipefail
[[ -r "$(dirname "$0")/lib/log.sh" ]] && . "$(dirname "$0")/lib/log.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/../templates"
TODAY="$(date +%Y-%m-%d)"

if [[ ! -r "$SCRIPT_DIR/lib/format.sh" ]]; then
  printf 'ERROR=missing: %s/lib/format.sh\n' "$SCRIPT_DIR" >&2
  exit 1
fi
# The formats this script writes are the formats feature-state.sh reads: an
# entry or a marker is found here exactly where the readers find it, and never
# inside an HTML comment holding the template's example.
. "$SCRIPT_DIR/lib/format.sh"

# ── Arguments ─────────────────────────────────────────────────────
ROOT_DIR="."
ARGS=()
while (( $# > 0 )); do
  case "$1" in
    --root) ROOT_DIR="${2:-}"; shift ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
set -- ${ARGS[@]+"${ARGS[@]}"}

OP="${1:-}"
case "$OP" in
  backup|status|verdict-stale|scaffold|arch-index|marker|compile-entry|section) shift ;;
  "") printf 'ERROR=no operation: spec-edit.sh <op> — backup, status, verdict-stale, scaffold, arch-index, marker, compile-entry, section\n' >&2; exit 1 ;;
  *)  printf 'ERROR=unknown operation: %s\n' "$OP" >&2; exit 1 ;;
esac

[[ -d "$ROOT_DIR" ]] || { printf 'ERROR=not a directory: %s\n' "$ROOT_DIR" >&2; exit 1; }
cd "$ROOT_DIR" || exit 1
SPECS="_docs"

die2() { printf 'ERROR=%s\n' "$1" >&2; exit 2; }

# The folder on disk, matched without regard to case: a feature typed `cart`
# and a folder named `Cart` are the same feature.
resolve_folder() {
  local want="$1" d name
  [[ -n "$want" ]] || die2 "no feature name"
  if [[ -d "$SPECS/$want" ]]; then printf '%s\n' "$want"; return 0; fi
  for d in "$SPECS"/*/; do
    [[ -d "$d" ]] || continue
    name="${d%/}"; name="${name##*/}"
    if [[ "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" == "$(printf '%s' "$want" | tr 'A-Z' 'a-z')" ]]; then
      printf '%s\n' "$name"; return 0
    fi
  done
  die2 "no feature folder _docs/$want — /sdd-next-story $want creates it"
}

# In place, without a temp file left behind on failure.
replace_file() {
  local target="$1" source="$2"
  cat "$source" > "$target" || { printf 'ERROR=could not write %s\n' "$target" >&2; exit 1; }
}

# `_docs/architecture.index.md` is derived and never written by hand: it is
# built from whatever `_docs/architecture/` holds at the moment it runs, so a
# section a project deleted, renamed or added of its own is in the index
# without anybody remembering to edit it. The set of section files is the
# project's to choose — nothing here requires a particular one.
ARCH_N=0
arch_index() {
  local dir="$SPECS/architecture" f topic
  ARCH_N=0
  [[ -d "$dir" ]] || return 2
  {
    printf -- '---\ntype: architecture-index\ntags:\n  - sdd/architecture\n---\n\n'
    printf '# Architecture Index\n\n'
    printf '<!-- Written whole by `spec-edit.sh arch-index` from the files in\n'
    printf '_docs/architecture/. An edit here is lost on the next run: what the rows\n'
    printf 'say lives in the section files they point at. -->\n\n'
    printf '| Topic | Path |\n|-------|------|\n'
  } > "$TMP/idx" || exit 1
  for f in "$dir"/*.md; do
    [[ -f "$f" ]] || continue
    # The topic a reader sees is the file's own heading; a `# ` line inside a
    # comment is a template showing a format, not the title of the file.
    topic="$(md_uncomment "$f" | sed -n 's/^# [[:space:]]*//p' | sed -n '1s/[[:space:]]*$//p')"
    [[ -n "$topic" ]] || topic="${f##*/}"
    # The row serves two readers at once. Its text is the path from the project
    # root, which is what every assignment and every protocol names and what a
    # role opens; its target is the path from this file, which is what a reader
    # in Obsidian or on a repository page follows. One row, and neither reader
    # has to translate it.
    printf '| %s | [%s](%s) |\n' "$topic" "$f" "${f#$SPECS/}" >> "$TMP/idx"
    ARCH_N=$(( ARCH_N + 1 ))
  done
  [[ $ARCH_N -gt 0 ]] || return 2
  replace_file "$SPECS/architecture.index.md" "$TMP/idx"
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sdd-edit.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

case "$OP" in

# ── backup ────────────────────────────────────────────────────────
backup)
  [[ -d "$SPECS" ]] || die2 "no $SPECS/ — there is nothing to back up"
  find "$SPECS" -type f -name '*.md' ! -path "$SPECS/.backup/*" | LC_ALL=C sort > "$TMP/list"
  n=$(grep -c . < "$TMP/list" || true)
  if [[ "$n" -eq 0 ]]; then
    printf 'BACKUP=\nFILES=0\n\nNOTES:\nNo .md file under %s/ — nothing was copied, and nothing is at risk.\n' "$SPECS"
    exit 0
  fi
  DEST="$SPECS/.backup/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$DEST" || { printf 'ERROR=could not create %s\n' "$DEST" >&2; exit 1; }
  while IFS= read -r f; do
    rel="${f#$SPECS/}"
    mkdir -p "$DEST/$(dirname "$rel")" || exit 1
    cp "$f" "$DEST/$rel" || { printf 'ERROR=could not copy %s — nothing is overwritten without its copy\n' "$f" >&2; exit 1; }
  done < "$TMP/list"
  printf 'BACKUP=%s\nFILES=%s\n\nCOPIED:\n' "$DEST" "$n"
  sed "s|^$SPECS/||" "$TMP/list"
  ;;

# ── status ────────────────────────────────────────────────────────
status)
  FOLDER="$(resolve_folder "${1:-}")" || exit 2
  shift
  WANT="${1:-}"; shift || true
  case "$WANT" in
    ready|draft) ;;
    *) die2 "not a status: ${WANT:-<empty>} — ready or draft" ;;
  esac
  (( $# > 0 )) || die2 "no file named: status <Feature> $WANT <file ...>"

  # Every file is checked before any is written: half a flip is worse than none.
  for name in "$@"; do
    path="$SPECS/$FOLDER/${name##*/}"
    [[ -f "$path" ]] || die2 "no such file: $path"
    [[ -n "$(md_field_line "$path" status)" ]] || die2 "$path carries no status — a status is not added where the format has none. It is the \`status\` property of the frontmatter, or the \`> Status:\` line of a document written before them"
  done
  # A file already at that status is left byte for byte as it is: the caller
  # asked for a state, and someone else reaching it first is the answer.
  : > "$TMP/updated"; : > "$TMP/unchanged"
  for name in "$@"; do
    path="$SPECS/$FOLDER/${name##*/}"
    if [[ "$(md_status "$path")" == "$WANT" ]]; then
      printf '%s\n' "$path" >> "$TMP/unchanged"
    else
      md_field_set "$path" Status "$WANT" > "$TMP/f" || exit 1
      replace_file "$path" "$TMP/f"
      printf '%s\n' "$path" >> "$TMP/updated"
    fi
  done
  printf 'STATUS=%s\n\nUPDATED:\n' "$WANT"
  cat "$TMP/updated"
  printf '\nUNCHANGED:\n'
  cat "$TMP/unchanged"
  ;;

# ── verdict-stale ─────────────────────────────────────────────────
verdict-stale)
  FOLDER="$(resolve_folder "${1:-}")" || exit 2
  path="$SPECS/$FOLDER/review.md"
  [[ -f "$path" ]] || die2 "no such file: $path — there is no report to invalidate"
  [[ -n "$(md_field_line "$path" verdict)" ]] || die2 "$path carries no \`> Verdict:\` line"
  line="stale — fixes applied $TODAY"
  md_field_set "$path" Verdict "$line" > "$TMP/f" || exit 1
  replace_file "$path" "$TMP/f"
  printf 'VERDICT=%s\nFILE=%s\n' "$line" "$path"
  ;;

# ── arch-index ────────────────────────────────────────────────────
arch-index)
  arch_index || die2 "no section files under $SPECS/architecture/ — the index is built from that folder, and a project whose architecture is the single $SPECS/architecture.md has none"
  printf 'INDEX=%s\nSECTIONS=%s\n' "$SPECS/architecture.index.md" "$ARCH_N"
  ;;

# ── scaffold ──────────────────────────────────────────────────────
scaffold)
  KIND="${1:-}"; shift || true
  case "$KIND" in

  init)
    mkdir -p "$SPECS" || exit 1
    MONO=0
    [[ "${1:-}" == "--mono" ]] && MONO=1
    copied=""; untouched=""; skipped=""

    scaffold_one() {
      local src="$1" dst="$2"
      [[ -f "$src" ]] || die2 "no template $src"
      if md_untouched "$dst" "$src"; then
        # The copy is already made and nobody has written into it. Copying the
        # template over it again would say the same thing and cost something: the
        # compilation counter lives inside a comment, where the content test does
        # not see it, and a re-copy would move it back to REQ-001.
        untouched="$untouched$dst
"
      elif [[ -s "$dst" ]]; then
        skipped="$skipped$dst
"
      else
        mkdir -p "$(dirname "$dst")" || exit 1
        cp "$src" "$dst" || exit 1
        copied="$copied$dst
"
      fi
    }

    for name in code-style.md requirements.md; do
      scaffold_one "$TEMPLATE_DIR/$name" "$SPECS/$name"
    done

    # The architecture baseline has two shapes and a project holds one of them.
    # The default is the folder of sections, because that is what a project of
    # any size grows into. A project already holding the single file keeps it:
    # laying the sections down beside it would leave two answers about the same
    # architecture, which is the one state the readers cannot resolve.
    if [[ $MONO -eq 1 || ( -f "$SPECS/architecture.md" && ! -d "$SPECS/architecture" ) ]]; then
      scaffold_one "$TEMPLATE_DIR/architecture.md" "$SPECS/architecture.md"
      MODE="mono"
    else
      shopt -s nullglob
      arch_have=("$SPECS"/architecture/*.md)
      arch_templates=("$TEMPLATE_DIR"/architecture/*.md)
      shopt -u nullglob
      [[ ${#arch_templates[@]} -gt 0 ]] || die2 "no templates under $TEMPLATE_DIR/architecture/"
      # Which sections a project keeps is the project's answer, and a section
      # it deleted is an answer too. So the templates are laid down once, into
      # an empty folder; a folder that already holds sections is left as it is
      # and only its index is rebuilt.
      if [[ ${#arch_have[@]} -eq 0 ]]; then
        for src in "${arch_templates[@]}"; do
          scaffold_one "$src" "$SPECS/architecture/${src##*/}"
        done
      else
        for f in "${arch_have[@]}"; do
          if md_untouched "$f" "$TEMPLATE_DIR/architecture/${f##*/}"; then
            untouched="$untouched$f
"
          else
            skipped="$skipped$f
"
          fi
        done
      fi
      # The sections a project keeps are its own to choose, and the index says
      # which they are — so it is rebuilt here rather than copied from a
      # template that would be wrong the moment one section is deleted.
      arch_index || die2 "the sections were copied but the index could not be written"
      MODE="split"
    fi

    printf 'SCAFFOLD=init\nMODE=%s\n\nCOPIED:\n%s\nUNTOUCHED:\n%s\nSKIPPED:\n%s' \
      "$MODE" "$copied" "$untouched" "$skipped"
    ;;

  feature)
    FEATURE="${1:-}"
    [[ -n "$FEATURE" ]] || die2 "no feature name: scaffold feature <Feature>"
    src="$TEMPLATE_DIR/raw.md"
    [[ -f "$src" ]] || die2 "no template $src"
    FOLDER="$FEATURE"
    if [[ -d "$SPECS" ]]; then
      for d in "$SPECS"/*/; do
        [[ -d "$d" ]] || continue
        name="${d%/}"; name="${name##*/}"
        if [[ "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" == "$(printf '%s' "$FEATURE" | tr 'A-Z' 'a-z')" ]]; then
          FOLDER="$name"; break
        fi
      done
    fi
    dst="$SPECS/$FOLDER/raw.md"
    [[ -s "$dst" ]] && die2 "$dst already describes this feature — it is never overwritten"
    mkdir -p "$SPECS/$FOLDER" || exit 1
    # Every `<FeatureName>` the template carries, not only the one in the title:
    # the frontmatter names the feature in a property of its own, and it sits
    # above the title. No template mentions the placeholder anywhere else.
    sed "s|<FeatureName>|$FEATURE|g" "$src" > "$TMP/f" || exit 1
    replace_file "$dst" "$TMP/f"
    printf 'SCAFFOLD=feature\nFOLDER=%s\nRAW=%s\n' "$FOLDER" "$dst"
    ;;

  spec)
    FEATURE="${1:-}"; shift || true
    [[ -n "$FEATURE" ]] || die2 "no feature name: scaffold spec <Feature> <file ...>"
    FOLDER="$(resolve_folder "$FEATURE")" || exit 2
    (( $# > 0 )) || die2 "no file named: scaffold spec <Feature> <file ...> — the files this run writes, and none of the ones it kept"

    # Every file is checked before any is copied: half a scaffold is worse than
    # none, and a name this script does not know is a typo, never a fourth file.
    for name in "$@"; do
      case "${name##*/}" in
        new-requirements.md|design.md|tasks.md) ;;
        *) die2 "not a spec file: ${name##*/} — new-requirements.md, design.md or tasks.md" ;;
      esac
      [[ -f "$TEMPLATE_DIR/${name##*/}" ]] || die2 "no template $TEMPLATE_DIR/${name##*/}"
    done

    copied=""
    for name in "$@"; do
      name="${name##*/}"
      dst="$SPECS/$FOLDER/$name"
      sed "s|<FeatureName>|$FOLDER|g" "$TEMPLATE_DIR/$name" > "$TMP/f" || exit 1
      replace_file "$dst" "$TMP/f"
      copied="$copied$dst
"
    done
    printf 'SCAFFOLD=spec\nFOLDER=%s\n\nCOPIED:\n%s' "$FOLDER" "$copied"
    ;;

  review)
    FOLDER="$(resolve_folder "${1:-}")" || exit 2
    src="$TEMPLATE_DIR/review.md"
    [[ -f "$src" ]] || die2 "no template $src"
    dst="$SPECS/$FOLDER/review.md"
    sed "s|<FeatureName>|$FOLDER|g" "$src" > "$TMP/f" || exit 1
    replace_file "$dst" "$TMP/f"
    printf 'SCAFFOLD=review\nFOLDER=%s\nREVIEW=%s\n' "$FOLDER" "$dst"
    ;;

  *) die2 "not a scaffold: ${KIND:-<empty>} — init, feature, spec or review" ;;
  esac
  ;;

# ── marker ────────────────────────────────────────────────────────
marker)
  FILE="${1:-}"; LINE="${2:-}"; TEXT="${3:-}"
  [[ -n "$FILE" && -n "$LINE" && -n "$TEXT" ]] || die2 "marker <file> <line> <text>"
  [[ -f "$FILE" ]] || die2 "no such file: $FILE"
  case "$LINE" in ''|*[!0-9]*) die2 "not a line number: $LINE" ;; esac
  total=$(grep -c '' "$FILE" || true)
  [[ "$LINE" -ge 1 && "$LINE" -le "$total" ]] || die2 "$FILE has $total lines — line $LINE is not in it"

  base="${FILE##*/}"
  case "$base" in *.*) ext="${base##*.}" ;; *) ext="" ;; esac
  open=""; close=""
  case "$ext" in
    java|kt|ts|tsx|js|jsx|scss|go|c|cpp|h|cs) open="//" ;;
    sql)                                      open="--" ;;
    sh|bash|py|rb|yaml|yml|toml|properties)   open="#"  ;;
    html|xml|md)                              open="<!--"; close=" -->" ;;
    css)                                      open="/*";   close=" */"  ;;
    *) die2 "no comment syntax known for .${ext:-<no extension>} ($FILE) — the marker is not guessed" ;;
  esac

  indent="$(sed -n "${LINE}p" "$FILE" | sed 's/[^[:space:]].*//')"
  awk -v n="$LINE" -v m="$indent$open TODO Code Review: $TEXT ($TODAY)$close" '
    NR == n { print m } { print }
  ' "$FILE" > "$TMP/f" || exit 1
  replace_file "$FILE" "$TMP/f"
  printf 'MARKER=%s:%s\nDATE=%s\n' "$FILE" "$LINE" "$TODAY"
  ;;

# ── compile-entry ─────────────────────────────────────────────────
compile-entry)
  FEATURE="${1:-}"; REQ="${2:-}"; MODE="${3:-}"; TEXT="${4:-}"
  [[ -n "$FEATURE" && -n "$REQ" && -n "$MODE" ]] || die2 "compile-entry <Feature> <REQ-###> final|superseded-by:<REQ-###> [<text>]"
  # Both forms of an id are accepted, the plain `REQ-003` and the domained
  # `REQ-ACC-003` — which one a project writes is the project's decision, and
  # lib/format.sh is where the shape of an id is read.
  md_req_is_id "$REQ" || die2 "not a requirement number: $REQ — REQ-### or REQ-<DOMAIN>-### is the format"
  case "$MODE" in
    final) ;;
    superseded-by:*)
      md_req_is_id "${MODE#superseded-by:}" || \
        die2 "not a requirement number: ${MODE#superseded-by:} — REQ-### or REQ-<DOMAIN>-### is the format" ;;
    *) die2 "not a mode: $MODE — final or superseded-by:REQ-###" ;;
  esac

  FILE="$SPECS/requirements.md"
  [[ -f "$FILE" ]] || die2 "no $FILE — /sdd-init writes it"

  # The entries are the ones the readers see: the template's example block is an
  # HTML comment, and an entry written into it would belong to no feature.
  md_req_lines "$FILE" "$REQ" > "$TMP/lines"
  hits=$(grep -c . < "$TMP/lines" || true)
  [[ "$hits" -le 1 ]] || die2 "$REQ is carried by $hits entries — the duplicate is the human's call, and no entry is edited until it is gone"

  suffix=""
  case "$MODE" in superseded-by:*) suffix=", superseded by ${MODE#superseded-by:}" ;; esac

  # The anchor another document links to: the id in lower case, as a block id at
  # the end of the entry. It is written here rather than left to a role, so that
  # `[REQ-001](requirements.md#^req-001)` resolves for every entry on the page
  # and not only for the ones somebody remembered.
  ANCHOR="^$(printf '%s' "$REQ" | tr '[:upper:]' '[:lower:]')"

  if [[ "$hits" -eq 1 ]]; then
    # An entry on file keeps the source that wrote it: a refinement does not
    # change whose requirement it was.
    at="$(cat "$TMP/lines")"
    old="$(awk -v n="$at" 'NR == n { print; exit }' "$FILE")"
    src="${old##*\*(Source: }"; src="${src%%)*}"; src="${src%%,*}"
    body="$TEXT"
    if [[ -z "$body" ]]; then
      body="${old#*— }"; body="${body%% \*(Source:*}"
    fi
    # Whatever the line carries after the source — a note in a comment — is not
    # this script's to drop: it owns the entry, not the margin beside it.
    tail=""
    case "$old" in
      *'*(Source: '*)
        rest="${old#*\*(Source: }"
        case "$rest" in *')*'*) tail="${rest#*)\*}" ;; esac ;;
    esac
    case "$tail" in
      *"$ANCHOR"*) ;;
      *) tail="$tail $ANCHOR" ;;
    esac
    new="- **$REQ** — $body *(Source: $src$suffix)*$tail"
    awk -v n="$at" -v line="$new" 'NR == n { print line; next } { print }' "$FILE" > "$TMP/f" || exit 1
    replace_file "$FILE" "$TMP/f"
    action="updated"
  else
    [[ -n "$TEXT" ]] || die2 "$REQ has no entry yet, so its wording has to come with it: compile-entry $FEATURE $REQ $MODE <text>"
    new="- **$REQ** — $TEXT *(Source: $FEATURE$suffix)* $ANCHOR"
    # Appended at the end of `## Requirements`, after whatever is already there.
    # The heading is looked for outside the comments, like everything else here.
    at="$(md_uncomment "$FILE" | awk '
      /^## Requirements/ { inside = 1; next }
      inside && /^## / { print NR; found = 1; exit }
      END { if (inside && !found) print NR + 1 }
    ')"
    [[ -n "$at" ]] || die2 "$FILE has no \`## Requirements\` section — an entry is never written where the format has no place for it"
    awk -v n="$at" -v line="$new" '
      NR == n { print line; print "" } { print }
      END { if (n > NR) print line }
    ' "$FILE" > "$TMP/f" || exit 1
    replace_file "$FILE" "$TMP/f"
    action="appended"
  fi

  # The counter never points at a number already issued — the counter of this
  # entry's own domain, which is the only sequence the entry took a number out
  # of. A file carrying no marker for the domain gets one: the entry is written
  # either way, and a domain whose next number is nowhere on file is a number
  # handed out twice on the next run.
  domain="$(md_req_domain "$REQ")"
  next=$(( 10#$(md_req_number "$REQ") + 1 ))
  free="$(md_req_id "$domain" "$next")"
  current="$(md_counter "$FILE" "$domain")"
  if [[ -n "$current" ]] && (( 10#$(md_req_number "$current") > next )); then
    free="$current"
  elif ! md_counter_set "$FILE" "$free" > "$TMP/f"; then
    # No marker anywhere in the file: the counter has no place to live, and the
    # entry is not held back over it.
    free=""
  else
    replace_file "$FILE" "$TMP/f"
  fi
  printf 'ENTRY=%s\nACTION=%s\nNEXT_FREE=%s\nFILE=%s\n' "$REQ" "$action" "$free" "$FILE"
  ;;

# ── section ───────────────────────────────────────────────────────
section)
  FILE="${1:-}"; HEADING="${2:-}"; TEXT="${3:-}"
  # The caller names the heading either as the file writes it — `## Problem` —
  # or bare. Both are the same section, and the answer names it bare.
  HEADING="$(printf '%s' "$HEADING" | sed 's/^#*[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -n "$FILE" && -n "$HEADING" ]] || die2 "section <file> <heading> [<text>]"
  [[ -f "$FILE" ]] || die2 "no such file: $FILE"
  # The heading is the one a reader sees: a `## ...` line inside a comment is
  # the template showing a format, not a section of this file.
  START="$(md_uncomment "$FILE" | awk -v want="## $HEADING" '$0 == want { print NR; exit }')"
  [[ -n "$START" ]] || die2 "$FILE has no section \`## $HEADING\`"

  if [[ -z "$TEXT" ]]; then
    printf 'SECTION=%s\nCHANGED=no\nFILE=%s\n\nNOTES:\nNo text was given, so the section keeps what the template put there.\n' "$HEADING" "$FILE"
    exit 0
  fi

  END_LINE="$(md_uncomment "$FILE" | awk -v s="$START" '
    NR > s && /^## / { print NR; found = 1; exit }
    END { if (!found) print NR + 1 }
  ')"
  printf '%s\n' "$TEXT" > "$TMP/body"
  awk -v s="$START" -v e="$END_LINE" -v bodyfile="$TMP/body" '
    NR == s { print; print ""; while ((getline l < bodyfile) > 0) print l; print ""; next }
    NR > s && NR < e { next }
    { print }
  ' "$FILE" > "$TMP/f" || exit 1
  replace_file "$FILE" "$TMP/f"
  printf 'SECTION=%s\nCHANGED=yes\nFILE=%s\n' "$HEADING" "$FILE"
  ;;

esac

exit 0
