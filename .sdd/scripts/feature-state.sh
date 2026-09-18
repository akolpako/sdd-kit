#!/usr/bin/env bash
# Reads the files of a feature under _docs/ and prints its state, its stage,
# and the command that comes next.
#
# This file is the only place the stage table lives — `ENGINE.md` → *Scripts*
# points here rather than repeating it. A precondition check and a status report
# that each derive the stage from the files by hand drift apart, and then two
# commands disagree on where the same feature stands.
#
# Usage: feature-state.sh [<FeatureName>] [<project-root>]
#   No <FeatureName> (or an empty one) reports every feature under `_docs/`.
#   <project-root> defaults to the current directory.
#
# Prints — one feature:
#   MODE=feature
#   FEATURE=<name>                       the argument, as given
#   FOLDER=<name>                        the folder it resolved to on disk; it
#                                        differs from FEATURE only on a
#                                        case-insensitive filesystem, where the
#                                        two names are the same folder
#   RAW=present|empty|missing            a file that exists but holds only
#   REQUIREMENTS=present|empty|missing   whitespace is `empty`, and counts as
#   DESIGN=present|empty|missing         missing everywhere a stage is decided
#   TASKS=present|empty|missing
#   MISSING_SPECS=<file,...>             of the three spec files
#   STATUS_REQUIREMENTS=draft|ready|absent|<as written>
#   STATUS_DESIGN=...
#   STATUS_TASKS=...
#   TASKS_TOTAL=<M>                      every task, blocked ones included
#   TASKS_DONE=<N>                       marked [x]
#   TASKS_BLOCKED=<K>                    unchecked and carrying BLOCKED:
#   TASK_TYPES=<type,...>                the types the task list actually holds
#   UNKNOWN_TYPES=<type,...>             types no developer role owns; `-` is a
#                                        task whose Type line is missing
#   REVIEW=present|empty|missing         _docs/<folder>/review.md — the report
#                                        of the last code review. Not a spec
#                                        file: no stage is decided by it, and
#                                        nothing counts it among MISSING_SPECS
#   REVIEW_DATE=<YYYY-MM-DD>             its `> Reviewed:` line
#   REVIEW_BASE=<ref>                    its `> Base:` line
#   REVIEW_ROOT=<commit>                 its `> Root:` line — what the reviewed
#                                        diff was taken against. A report whose
#                                        root is not the current one describes
#                                        code that has since moved
#   REVIEW_VERDICT=<as written>|absent   its `> Verdict:` line
#   COMPILATION=present|missing          _docs/requirements.md
#   COMPILATION_ACTIVE=<n>               entries sourced by this feature,
#   COMPILATION_DRAFT=<n>                by status
#   COMPILATION_SUPERSEDED=<n>
#   STAGE=<stage>
#   NEXT=<command>                       empty when the feature is done. One
#                                        stage has more than one successor:
#                                        `implemented` follows REVIEW_VERDICT —
#                                        absent or unrecognized → /sdd-code-review,
#                                        `blocked` → /sdd-code-fix,
#                                        `stale` → /sdd-code-review,
#                                        `approved…` → /sdd-actualize
#   TASKS:                  <ID>|<state>|<type>|<requires>|<title>|<reason>
#                           six fields; state is one of done, open, blocked, or
#                           done+blocked — [x] and still carrying BLOCKED:
#   COMPILATION_ENTRIES:    <REQ-###>|<status>
#                           status is active, draft, or superseded by REQ-###
#   ANOMALIES:              one per line — reported, never fixed
#   NOTES:                  what the script could not settle on its own
#
# Prints — every feature:
#   MODE=all, COUNT, COMPILATION, then
#   FEATURES:   <name>|<stage>|<done>|<total>|<blocked>|<next>
#               in stage order, least advanced first
#   ANOMALIES:  each line prefixed with its feature
#   NOTES:
#
# Stage:
#   empty                   no file at all
#   raw                     raw.md only
#   specified (incomplete)  some but not all three spec files
#   specified               all three, at least one not `ready`
#   reviewed                all three `ready`, no task done
#   in progress N/M         some tasks done
#   implemented             every task done
#   actualized              implemented, and every compilation entry of the
#                           feature is out of `draft`
# The stage is the furthest one whose signals all hold. Signals that disagree
# leave the earlier stage standing, and the disagreement goes to ANOMALIES.
# `, K blocked` is appended to the stage whenever K > 0.
#
# Exit codes: 0 — printed; 1 — <project-root> is not a readable directory;
#             2 — no `_docs/`, no feature folder in it, or no such feature.

set -uo pipefail
[[ -r "$(dirname "$0")/lib/log.sh" ]] && . "$(dirname "$0")/lib/log.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -r "$SCRIPT_DIR/lib/format.sh" ]]; then
  printf 'ERROR=missing: %s/lib/format.sh\n' "$SCRIPT_DIR" >&2
  exit 1
fi
. "$SCRIPT_DIR/lib/format.sh"

FEATURE=""
ROOT_DIR="."
case $# in
  0) ;;
  1) FEATURE="${1:-}" ;;
  *) FEATURE="${1:-}"; ROOT_DIR="${2:-.}" ;;
esac

if [[ ! -d "$ROOT_DIR" ]]; then
  printf 'ERROR=not a directory: %s\n' "$ROOT_DIR" >&2
  exit 1
fi

SPECS="$ROOT_DIR/_docs"
COMPILATION_FILE="$SPECS/requirements.md"

if [[ ! -d "$SPECS" ]]; then
  printf 'ERROR=missing: %s\n' "$SPECS" >&2
  exit 2
fi

# Counters, not ${#array[@]}: on bash 3.2 an empty array counts as unset under
# `set -u` and reading its length aborts the script.
NOTES=(); N_NOTES=0
note() { NOTES+=("$1"); N_NOTES=$(( N_NOTES + 1 )); }

COMPILATION_STATE="missing"
[[ -f "$COMPILATION_FILE" ]] && COMPILATION_STATE="present"
[[ "$COMPILATION_STATE" == "missing" ]] && \
  note "No _docs/requirements.md — no feature can be told apart from actualized, and every finished one stays at 'implemented'."

# ── Reading one file ──────────────────────────────────────────────
# HTML comments, the `> Status:` line and the compilation entries are read
# through `lib/format.sh`: one scanner, so a check and a report never disagree
# on which lines of a file are real.

file_state() {
  if [[ ! -f "$1" ]]; then printf 'missing'; return 0; fi
  if grep -q '[^[:space:]]' "$1" 2>/dev/null; then printf 'present'; else printf 'empty'; fi
}

# One record per task: ID|state|type|requires|title|reason
parse_tasks() {
  md_uncomment "$1" | awk '
    function flush() {
      if (id != "") printf "%s|%s|%s|%s|%s|%s\n", id, state, type, requires, title, reason
      id = ""; state = ""; type = ""; requires = ""; title = ""; reason = ""
    }
    /^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*TASK-[0-9]+\*\*/ {
      flush()
      line = $0
      state = (line ~ /\[[xX]\]/) ? "done" : "open"
      match(line, /TASK-[0-9]+/); id = substr(line, RSTART, RLENGTH)
      rest = substr(line, RSTART + RLENGTH)
      sub(/^\*\*/, "", rest)
      sub(/^[[:space:]]*(—|–|-)[[:space:]]*/, "", rest)
      p = index(rest, "BLOCKED:")
      if (p > 0) {
        title = substr(rest, 1, p - 1)
        reason = substr(rest, p + 8)
        sub(/[[:space:]]*(—|–|-)[[:space:]]*$/, "", title)
        if (state == "open") state = "blocked"; else state = "done+blocked"
      } else {
        title = rest
      }
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", title)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", reason)
      gsub(/\|/, "/", title); gsub(/\|/, "/", reason)
      next
    }
    /^##[^#]/ { flush(); next }
    id != "" && /\*\*Type:\*\*/ {
      t = $0; sub(/.*\*\*Type:\*\*[[:space:]]*/, "", t)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
      gsub(/\|/, "/", t)
      type = tolower(t)
    }
    id != "" && /\*\*Requires:\*\*/ {
      r = $0; sub(/.*\*\*Requires:\*\*[[:space:]]*/, "", r)
      # A requirement is written as a link to its anchor — `[REQ-001](…)`. The
      # record carries the ids and not the hrefs: the link is how the document
      # reads, and this is what a reader of the record is after. Text carrying
      # no link comes through untouched.
      gsub(/\][[:space:]]*\([^)]*\)/, "", r)
      gsub(/\[/, "", r)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", r)
      gsub(/[[:space:]]*,[[:space:]]*/, ",", r)
      gsub(/\|/, "/", r)
      requires = r
    }
    END { flush() }
  '
}

# One record per compilation entry sourced by <feature>: REQ-###|<status>|<source>
# The source is matched the way the folder itself is resolved — case-insensitively
# — so an entry that names `cart` for the folder `Cart` is still this feature's
# entry. Dropping it would leave the feature at `implemented` for good, with
# nothing in the output to say why. The source comes back as written so the
# caller can report the difference.
parse_compilation() {
  [[ -f "$COMPILATION_FILE" ]] || return 0
  md_uncomment "$COMPILATION_FILE" | awk -v want="$1" "$MD_AWK_ENTRY"'
    BEGIN { lcwant = tolower(want) }
    md_is_entry($0) {
      req = md_id($0)
      p = index($0, "(Source:")
      if (p == 0) next
      rest = substr($0, p + 8)
      q = index(rest, ")")
      if (q > 0) rest = substr(rest, 1, q - 1)
      n = split(rest, part, ",")
      src = part[1]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", src)
      if (tolower(src) != lcwant) next
      status = "active"
      for (i = 2; i <= n; i++) {
        f = part[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f)
        if (f == "draft") status = "draft"
        else if (f ~ /^superseded by REQ-([A-Z][A-Z0-9]*-)*[0-9]+/) status = f
      }
      # The record is three fields split on `|`, so a source carrying one would
      # shift every field after it — the status would be read as the source and
      # the entry would land in the wrong counter. Same substitution and same
      # replacement character as parse_tasks, and applied after the match above
      # so the source is still compared as the folder spells it.
      gsub(/\|/, "/", src)
      print req "|" status "|" src
    }
  '
}

# ── The compilation file itself, read once ────────────────────────
# What is wrong with the file rather than with one feature. An entry with no
# source belongs to no feature, so no feature's ANOMALIES: can carry it.
if [[ "$COMPILATION_STATE" == "present" ]]; then
  md_comment_open "$COMPILATION_FILE" && \
    note "requirements.md leaves an HTML comment open — every entry after the stray '<!--' is invisible, and the features they belong to cannot reach 'actualized'."
  NO_SOURCE=$(md_uncomment "$COMPILATION_FILE" | awk "$MD_AWK_ENTRY"'
    md_is_entry($0) && index($0, "(Source:") == 0 {
      printf "%s%s", (n++ ? ", " : ""), md_id($0)
    }
    END { if (n) print "" }')
  [[ -n "$NO_SOURCE" ]] && \
    note "Compilation entries carrying no *(Source: ...)*: $NO_SOURCE — they belong to no feature, and no stage can see them."
fi

# ── Collecting one feature ────────────────────────────────────────
# Everything below writes into these, read by the two printers.
collect() {
  local f="$1" dir="$SPECS/$1" rec rest id state type requires title reason tlabel
  local cstatus csrc srcdrift=""

  ANOM=(); N_ANOM=0
  TASK_RECS=(); N_TASK_RECS=0
  COMP_RECS=(); N_COMP_RECS=0
  T_TOTAL=0; T_DONE=0; T_BLOCKED=0
  C_ACTIVE=0; C_DRAFT=0; C_SUPERSEDED=0
  TYPES=""; UNKNOWN=""; SEEN_IDS=""; MISSING_SPECS=""

  anom() { ANOM+=("$1"); N_ANOM=$(( N_ANOM + 1 )); }

  ST_RAW=$(file_state "$dir/raw.md")
  ST_REQ=$(file_state "$dir/new-requirements.md")
  ST_DES=$(file_state "$dir/design.md")
  ST_TSK=$(file_state "$dir/tasks.md")

  S_REQ=$(md_status "$dir/new-requirements.md")
  S_DES=$(md_status "$dir/design.md")
  S_TSK=$(md_status "$dir/tasks.md")

  # ── The code review report ──────────────────────────────────────
  # Read like any other file of the feature, and counted like none of them: it
  # is the output of a review, not part of the spec, so it never reaches
  # MISSING_SPECS and no stage waits on it.
  ST_REVIEW=$(file_state "$dir/review.md")
  R_DATE=$(md_field "$dir/review.md" reviewed)
  R_BASE=$(md_field "$dir/review.md" base)
  R_ROOT=$(md_field "$dir/review.md" root)
  R_VERDICT=$(md_field "$dir/review.md" verdict)
  [[ -z "$R_VERDICT" ]] && R_VERDICT="absent"

  # ── The three spec files ────────────────────────────────────────
  local spec_count=0 name label st marker
  for pair in "new-requirements.md:$ST_REQ:$S_REQ" "design.md:$ST_DES:$S_DES" "tasks.md:$ST_TSK:$S_TSK"; do
    name="${pair%%:*}"; label="${pair#*:}"; st="${label%%:*}"; marker="${label#*:}"
    if [[ "$st" == "present" ]]; then
      spec_count=$(( spec_count + 1 ))
      case "$marker" in
        ready|draft) ;;
        absent) anom "$name carries no status — counted as draft." ;;
        *)      anom "$name says status '$marker', which is neither draft nor ready — counted as draft." ;;
      esac
    else
      MISSING_SPECS="${MISSING_SPECS:+$MISSING_SPECS,}$name"
      [[ "$st" == "empty" ]] && anom "$name exists but is empty — counted as missing."
    fi
  done

  local ready_count=0 ready_names="" draft_names=""
  for pair in "new-requirements.md:$ST_REQ:$S_REQ" "design.md:$ST_DES:$S_DES" "tasks.md:$ST_TSK:$S_TSK"; do
    name="${pair%%:*}"; label="${pair#*:}"; st="${label%%:*}"; marker="${label#*:}"
    [[ "$st" == "present" ]] || continue
    if [[ "$marker" == "ready" ]]; then
      ready_count=$(( ready_count + 1 )); ready_names="${ready_names:+$ready_names, }$name"
    else
      draft_names="${draft_names:+$draft_names, }$name"
    fi
  done
  if [[ $spec_count -eq 3 && $ready_count -gt 0 && $ready_count -lt 3 ]]; then
    anom "The spec files disagree on Status — ready: $ready_names; draft: $draft_names."
  fi
  [[ "$ST_RAW" != "present" && $spec_count -gt 0 ]] && \
    anom "raw.md is $ST_RAW while the spec files exist — the intent the spec was written from is not on disk."

  [[ "$ST_REVIEW" == "empty" ]] && \
    anom "review.md exists but is empty — counted as missing, and the review it should hold has to be run again."
  if [[ "$ST_REVIEW" == "present" ]]; then
    [[ -z "$R_ROOT" ]] && \
      anom "review.md carries no '> Root:' line — there is no way to tell whether it still describes the current code."
    [[ "$R_VERDICT" == "absent" ]] && \
      anom "review.md carries no '> Verdict:' line — the report says nothing about whether the code is mergeable."
  fi

  for name in new-requirements.md design.md tasks.md; do
    md_comment_open "$dir/$name" && \
      anom "$name leaves an HTML comment open — everything after the stray '<!--' is invisible to this script, so its status and its entries are read as absent."
  done

  # ── Tasks ───────────────────────────────────────────────────────
  if [[ "$ST_TSK" == "present" ]]; then
    while IFS= read -r rec; do
      [[ -n "$rec" ]] || continue
      TASK_RECS+=("$rec"); N_TASK_RECS=$(( N_TASK_RECS + 1 ))
      id="${rec%%|*}"; rest="${rec#*|}"
      state="${rest%%|*}"; rest="${rest#*|}"
      type="${rest%%|*}"; rest="${rest#*|}"
      requires="${rest%%|*}"; rest="${rest#*|}"
      title="${rest%%|*}"; reason="${rest#*|}"

      # Two task lines may carry the same ID, and then the ID alone does not say
      # which line an anomaly is about — so every one of them names the title too.
      tlabel="$id"
      [[ -n "$title" ]] && tlabel="$id \"$title\""

      T_TOTAL=$(( T_TOTAL + 1 ))
      case "$state" in
        done)         T_DONE=$(( T_DONE + 1 )) ;;
        blocked)      T_BLOCKED=$(( T_BLOCKED + 1 )) ;;
        done+blocked) T_DONE=$(( T_DONE + 1 ))
                      anom "$tlabel is marked [x] and carries BLOCKED: — a task whose build is not green is never [x]." ;;
      esac
      [[ "$state" == "blocked" && -z "$reason" ]] && anom "$tlabel is BLOCKED with no reason after the colon."

      case ",$SEEN_IDS," in
        *",$id,"*) anom "$tlabel repeats an ID another task line already carries." ;;
        *) SEEN_IDS="${SEEN_IDS:+$SEEN_IDS,}$id" ;;
      esac

      local t="${type:--}"
      case ",$TYPES," in *",$t,"*) ;; *) TYPES="${TYPES:+$TYPES,}$t" ;; esac
      case "$t" in
        backend|frontend) ;;
        *) case ",$UNKNOWN," in *",$t,"*) ;; *) UNKNOWN="${UNKNOWN:+$UNKNOWN,}$t" ;; esac ;;
      esac
      [[ -z "$requires" ]] && anom "$tlabel has no Requires: line — it is linked to no requirement."
    done < <(parse_tasks "$dir/tasks.md")

    [[ $T_TOTAL -eq 0 ]] && anom "tasks.md holds no parsable '- [ ] **TASK-###**' line — the breakdown is empty or malformed."
    [[ -n "$UNKNOWN" ]] && anom "Task types no developer role owns: $UNKNOWN ('-' is a task with no Type line). Implementation covers backend and frontend."
  fi

  # ── Compilation ─────────────────────────────────────────────────
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    csrc="${rec##*|}"; rec="${rec%|*}"   # the source is for the check below, not the report
    COMP_RECS+=("$rec"); N_COMP_RECS=$(( N_COMP_RECS + 1 ))
    cstatus="${rec#*|}"
    case "$cstatus" in
      draft)          C_DRAFT=$(( C_DRAFT + 1 )) ;;
      superseded*)    C_SUPERSEDED=$(( C_SUPERSEDED + 1 )) ;;
      *)              C_ACTIVE=$(( C_ACTIVE + 1 )) ;;
    esac
    # The record carries the source with `|` replaced, so the folder is compared
    # under the same substitution: otherwise a folder holding one would drift
    # against its own entries.
    if [[ "$csrc" != "${f//|//}" ]]; then
      case ",$srcdrift," in *",$csrc,"*) ;; *) srcdrift="${srcdrift:+$srcdrift,}$csrc" ;; esac
    fi
  done < <(parse_compilation "$f")

  [[ -n "$srcdrift" ]] && \
    anom "Compilation entries name the source '$srcdrift' while the folder is '$f' — the same feature under two spellings."

  # ── The stage ───────────────────────────────────────────────────
  # Read top to bottom: the first branch whose signals hold wins, so a later
  # signal never carries the feature past a stage an earlier one contradicts.
  if [[ "$ST_RAW" != "present" && $spec_count -eq 0 ]]; then
    STAGE="empty"; STAGE_RANK=0; NEXT="/sdd-next-story $f"
  elif [[ $spec_count -eq 0 ]]; then
    STAGE="raw"; STAGE_RANK=1; NEXT="/sdd-specify $f"
  elif [[ $spec_count -lt 3 ]]; then
    STAGE="specified (incomplete)"; STAGE_RANK=2; NEXT="/sdd-specify $f"
  elif [[ $ready_count -lt 3 ]]; then
    STAGE="specified"; STAGE_RANK=3; NEXT="/sdd-spec-review $f"
    [[ $T_DONE -gt 0 ]] && anom "$T_DONE task(s) are [x] while the spec is still draft — the code was built from an unreviewed spec."
  elif [[ $T_DONE -eq 0 ]]; then
    STAGE="reviewed"; STAGE_RANK=4; NEXT="/sdd-implement $f"
  elif [[ $T_DONE -lt $T_TOTAL ]]; then
    STAGE="in progress $T_DONE/$T_TOTAL"; STAGE_RANK=5; NEXT="/sdd-implement $f"
  else
    if [[ "$COMPILATION_STATE" == "present" && $N_COMP_RECS -gt 0 && $C_DRAFT -eq 0 ]]; then
      STAGE="actualized"; STAGE_RANK=7; NEXT=""
    else
      STAGE="implemented"; STAGE_RANK=6
      # The one stage with more than one successor. Which it is comes from the
      # review report, never from the stage name: no review yet, a review that
      # blocked, a review the fixes invalidated, and a review that approved
      # send the human to three different commands.
      case "$(printf '%s' "$R_VERDICT" | tr '[:upper:]' '[:lower:]')" in
        blocked*)  NEXT="/sdd-code-fix $f" ;;
        approved*) NEXT="/sdd-actualize $f" ;;
        stale*)    NEXT="/sdd-code-review $f" ;;
        *)         NEXT="/sdd-code-review $f" ;;
      esac
      [[ $C_DRAFT -gt 0 ]] && anom "The compilation still holds $C_DRAFT draft entry(ies) for a feature that is implemented — /sdd-actualize is what promotes them."
      [[ "$COMPILATION_STATE" == "present" && $N_COMP_RECS -eq 0 ]] && \
        anom "Every task is done and the compilation holds no entry sourced by this feature — nothing can take it past 'implemented'; /sdd-actualize is what writes them."
    fi
  fi
  [[ $T_BLOCKED -gt 0 ]] && STAGE="$STAGE, $T_BLOCKED blocked"
}

# ── Printing ──────────────────────────────────────────────────────
print_feature() {
  printf 'MODE=feature\n'
  printf 'FEATURE=%s\n' "$1"
  printf 'FOLDER=%s\n' "$FOLDER"
  printf 'RAW=%s\n' "$ST_RAW"
  printf 'REQUIREMENTS=%s\n' "$ST_REQ"
  printf 'DESIGN=%s\n' "$ST_DES"
  printf 'TASKS=%s\n' "$ST_TSK"
  printf 'MISSING_SPECS=%s\n' "$MISSING_SPECS"
  printf 'STATUS_REQUIREMENTS=%s\n' "$S_REQ"
  printf 'STATUS_DESIGN=%s\n' "$S_DES"
  printf 'STATUS_TASKS=%s\n' "$S_TSK"
  printf 'TASKS_TOTAL=%s\n' "$T_TOTAL"
  printf 'TASKS_DONE=%s\n' "$T_DONE"
  printf 'TASKS_BLOCKED=%s\n' "$T_BLOCKED"
  printf 'TASK_TYPES=%s\n' "$TYPES"
  printf 'UNKNOWN_TYPES=%s\n' "$UNKNOWN"
  printf 'REVIEW=%s\n' "$ST_REVIEW"
  printf 'REVIEW_DATE=%s\n' "$R_DATE"
  printf 'REVIEW_BASE=%s\n' "$R_BASE"
  printf 'REVIEW_ROOT=%s\n' "$R_ROOT"
  printf 'REVIEW_VERDICT=%s\n' "$R_VERDICT"
  printf 'COMPILATION=%s\n' "$COMPILATION_STATE"
  printf 'COMPILATION_ACTIVE=%s\n' "$C_ACTIVE"
  printf 'COMPILATION_DRAFT=%s\n' "$C_DRAFT"
  printf 'COMPILATION_SUPERSEDED=%s\n' "$C_SUPERSEDED"
  printf 'STAGE=%s\n' "$STAGE"
  printf 'NEXT=%s\n' "$NEXT"

  printf '\nTASKS:\n'
  for rec in ${TASK_RECS[@]+"${TASK_RECS[@]}"}; do printf '%s\n' "$rec"; done

  printf '\nCOMPILATION_ENTRIES:\n'
  for rec in ${COMP_RECS[@]+"${COMP_RECS[@]}"}; do printf '%s\n' "$rec"; done
}

list_features() {
  find "$SPECS" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null \
    | sed 's|.*/||' | sort
}

# The folder a name resolves to on disk. On a case-insensitive filesystem
# `_docs/cart` opens `_docs/Cart`, and every step that only compared the
# argument with itself would never notice — so the comparison happens here,
# against the folders that are actually there.
resolve_folder() {
  local want="$1" lc names name
  names=$(list_features)
  while IFS= read -r name; do
    [[ "$name" == "$want" ]] && { printf '%s' "$name"; return 0; }
  done <<< "$names"
  lc=$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r name; do
    [[ "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" == "$lc" ]] && { printf '%s' "$name"; return 0; }
  done <<< "$names"
  printf '%s' "$want"
}

# ── Run ───────────────────────────────────────────────────────────
ALL_ANOM=(); N_ALL_ANOM=0
FEATURE_ROWS=(); N_ROWS=0

if [[ -n "$FEATURE" ]]; then
  if [[ ! -d "$SPECS/$FEATURE" ]]; then
    printf 'ERROR=no such feature: %s\n' "$FEATURE" >&2
    printf 'FEATURES:\n'
    list_features
    exit 2
  fi
  FOLDER=$(resolve_folder "$FEATURE")
  # Everything downstream — the paths, the compilation source, the NEXT command
  # — uses the folder as it is spelled on disk, never the argument as typed.
  collect "$FOLDER"
  [[ "$FOLDER" != "$FEATURE" ]] && \
    ANOM+=("The argument is '$FEATURE' and the folder on disk is '$FOLDER' — on a case-insensitive filesystem they are one and the same folder.")
  print_feature "$FEATURE"
  printf '\nANOMALIES:\n'
  for a in ${ANOM[@]+"${ANOM[@]}"}; do printf '%s\n' "$a"; done
else
  count=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    count=$(( count + 1 ))
    collect "$name"
    # The rank is a sort key, stripped before printing: FEATURES: comes out in
    # stage order, least advanced first, so nobody re-derives that order.
    FEATURE_ROWS+=("$STAGE_RANK|$name|$STAGE|$T_DONE|$T_TOTAL|$T_BLOCKED|$NEXT"); N_ROWS=$(( N_ROWS + 1 ))
    for a in ${ANOM[@]+"${ANOM[@]}"}; do
      ALL_ANOM+=("$name: $a"); N_ALL_ANOM=$(( N_ALL_ANOM + 1 ))
    done
  done < <(list_features)

  if [[ $count -eq 0 ]]; then
    printf 'ERROR=no feature folder in %s\n' "$SPECS" >&2
    exit 2
  fi

  printf 'MODE=all\n'
  printf 'COUNT=%s\n' "$count"
  printf 'COMPILATION=%s\n' "$COMPILATION_STATE"

  printf '\nFEATURES:\n'
  for row in ${FEATURE_ROWS[@]+"${FEATURE_ROWS[@]}"}; do printf '%s\n' "$row"; done \
    | sort -t'|' -k1,1n -k2,2 | cut -d'|' -f2-

  printf '\nANOMALIES:\n'
  for a in ${ALL_ANOM[@]+"${ALL_ANOM[@]}"}; do printf '%s\n' "$a"; done
fi

printf '\nNOTES:\n'
for n in ${NOTES[@]+"${NOTES[@]}"}; do printf '%s\n' "$n"; done
exit 0
