#!/usr/bin/env bash
# The precondition gate of every SDD command: runs the scripts that command
# needs, applies its checks, and prints one verdict.
#
# The wording of every STOP:, ASK: and WARN: line is owned here — the command
# that runs this script relays those lines and adds nothing of its own. What the
# checks mean is `ENGINE.md` → *Scripts*; this script is where the decision runs,
# so it comes out the same every time and no command re-derives it from the files.
#
# Usage: gate.sh <command> <FeatureName> [<base-ref>] [<project-root>] [--prompt-data]
#        gate.sh <command> <FeatureName> --verify [--files=<f,...>] [--scope=<s>]
#   <command>       init | new | specify | review | implement | code-review |
#                   code-fix | actualize
#   init            takes no feature name: gate.sh init [<project-root>]
#   <base-ref>      code-review only, and optional
#   <project-root>  defaults to the current directory
#   --prompt-data   also print the sections a spawn prompt is built from and
#                   nothing decides from. `.sdd/scripts/spawn-prompt.sh` passes
#                   it; a command never does — those bytes would enter the
#                   orchestrator's context to be copied back out unchanged.
#   --verify        check the postconditions of the step instead of its
#                   preconditions, and print those and nothing else. What a step
#                   left behind is read from disk here, never by the orchestrator
#                   from the files.
#   /sdd-status has no gate: it checks nothing, and runs feature-state.sh itself.
#
# Prints — every command:
#   GATE=ok|ask|done|stop  ok   — go;
#                          ask  — go only after the human answers every ASK:
#                                 line with an explicit yes;
#                          done — nothing is left to do;
#                          stop — the command cannot run
#   FEATURE=<name>         the argument, as given            (not under init)
#   FOLDER=<name>          the folder it resolved to on disk — every path and
#                          every later step follows this, not the argument
#   STAGE=<stage>
#   SPAWN:        one assignment per line, `<role>|<protocol,...>|<scope>`. The
#                 command relays a record as printed — it adds no protocol and
#                 drops none. Which role follows which protocols is decided here
#                 and nowhere else. A record for work this run does not have is
#                 not printed: under implement that is ROLE_ORDER. What only the
#                 human knows — which file they let /sdd-specify overwrite, which
#                 stack /sdd-code-fix has findings in — the command drops, as a
#                 whole record.
#   STOP:         one reason per line, worded as the human is told it
#   ASK:          one question per line, the same way
#   WARN:         reported, never a reason to stop
#   ANOMALIES:    from feature-state.sh, unchanged
#   NOTES:        from every script that ran, each line prefixed with the one it
#                 came from
#
# Under --prompt-data, and only there:
#   SPEC_FILES:   the paths of this run, one per line — every command
#   COMPILATION_ENTRIES:  review
#   UNTRACKED:, BLOCKED:  code-review
#   TODO:                 implement
#
# A key the command does not decide from is not printed. At GATE=stop and
# GATE=done no record section is — no role is spawned from them. Per command,
# on top of the common part:
#   init         PROJECT=greenfield|brownfield, TEMPLATES=ok|missing:<file,...>,
#                EXISTING=<file,...>, BUILD_ROOT, BUILD_BACKEND, BUILD_FRONTEND,
#                DETECTED:
#   new          NAME_OK=yes|no, NAME_WARN=<text>, RAW=..., FEATURES:
#   specify      RAW, REQUIREMENTS, DESIGN, TASKS, STATUS_*, COMPILATION,
#                NEXT_REQ=REQ-###, MODE=draft, REQ_DOMAINS:, REQ_DUPLICATES:
#   review       the same, plus TASKS:
#   implement    TASKS_DONE, TASKS_TOTAL, TASKS_BLOCKED, ROLE_ORDER, BUILD_ROOT,
#                BUILD_BACKEND, BUILD_FRONTEND, BASELINE, BUILD_FILES
#   code-review  BASE, ROOT, DIFF, CHANGED, REVIEW_PATH, REVIEW_PREVIOUS
#   code-fix     REVIEW, REVIEW_PATH, REVIEW_DATE, REVIEW_ROOT, REVIEW_VERDICT,
#                ROOT, BUILD_ROOT, BUILD_BACKEND, BUILD_FRONTEND
#   actualize    REQUIREMENTS, DESIGN, COMPILATION, NEXT_REQ, REQ_DOMAINS:,
#                COMPILATION_ENTRIES:
#
# Prints under --verify, and nothing else:
#   VERIFY=ok|fail
#   FAIL:         one reason per line, worded as the human is told it
#
# What each step is checked to have left behind:
#   init         the three files of _docs/ exist and hold something
#   new          the feature folder and its raw.md
#   specify      --files=<f,...>, of new-requirements.md, design.md and tasks.md:
#                each is on disk and carries `> Status: draft`. The files the
#                human kept were not written by this run and are not named
#   implement    --scope=backend|frontend: no task of that type is left `open`;
#                the ones that are are named
#   code-review  review.md exists, holds something, and carries `> Verdict:`
#   actualize    no entry this feature sourced is still `draft`, and the
#                compilation counter stands past every number handed out
#   review, code-fix have no --verify: what they leave behind is the human's
#   yes and the writes of spec-edit.sh, and both are mechanical already.
#   Whether the text is any good is not checked here at all — that is the work
#   of /sdd-spec-review and /sdd-code-review.
#
# Exit codes: 0 — a verdict was printed; 1 — the environment is wrong;
#             2 — a script this gate ran exited 2 and GATE=stop.
# Under --verify: 0 — VERIFY=ok; 1 — the environment is wrong; 2 — VERIFY=fail,
#             so `a script that exits non-zero means the step did not happen`
#             holds for the check as it does for everything else.

set -uo pipefail
[[ -r "$(dirname "$0")/lib/log.sh" ]] && . "$(dirname "$0")/lib/log.sh"

# ── Arguments ─────────────────────────────────────────────────────
# --prompt-data adds the sections only a spawn prompt is built from. It is for
# spawn-prompt.sh, whose gate run never reaches the orchestrator's context.
PROMPT_DATA=0
VERIFY=0; V_FILES=""; V_SCOPE=""
GATE_ARGS=()
for arg in ${1+"$@"}; do
  case "$arg" in
    --prompt-data) PROMPT_DATA=1 ;;
    --verify)      VERIFY=1 ;;
    --files=*)     V_FILES="${arg#--files=}" ;;
    --scope=*)     V_SCOPE="${arg#--scope=}" ;;
    *)             GATE_ARGS+=("$arg") ;;
  esac
done
set -- ${GATE_ARGS[@]+"${GATE_ARGS[@]}"}

CMD="${1:-}"
case "$CMD" in
  init|new|specify|review|implement|code-review|code-fix|actualize) ;;
  "") printf 'ERROR=no command: gate.sh <command> <FeatureName> [<base-ref>] [<project-root>]\n' >&2; exit 1 ;;
  *)  printf 'ERROR=unknown command: %s — one of init, new, specify, review, implement, code-review, code-fix, actualize\n' "$CMD" >&2; exit 1 ;;
esac

FEATURE=""; BASE_ARG=""; ROOT_DIR="."
if [[ "$CMD" == "init" ]]; then
  ROOT_DIR="${2:-.}"
else
  FEATURE="${2:-}"
  if [[ -z "$FEATURE" ]]; then
    printf 'ERROR=no feature name: gate.sh %s <FeatureName>\n' "$CMD" >&2
    exit 1
  fi
  if [[ "$CMD" == "code-review" ]]; then
    BASE_ARG="${3:-}"; ROOT_DIR="${4:-.}"
  else
    ROOT_DIR="${3:-.}"
  fi
fi
if [[ ! -d "$ROOT_DIR" ]]; then
  printf 'ERROR=not a directory: %s\n' "$ROOT_DIR" >&2
  exit 1
fi

# The options of --verify, checked before anything is read: an argument the
# caller got wrong is the environment, not a failed postcondition, and VERIFY=fail
# would be read as the step having gone wrong.
if [[ $VERIFY -eq 1 ]]; then
  if [[ $PROMPT_DATA -eq 1 ]]; then
    printf 'ERROR=--verify and --prompt-data are two different runs: one checks what a step left behind, the other feeds a prompt\n' >&2
    exit 1
  fi
  case "$CMD" in
    review|code-fix)
      printf 'ERROR=%s has no --verify: what it leaves behind is the human'"'"'s yes and the writes of spec-edit.sh, and both are mechanical already\n' "$CMD" >&2
      exit 1 ;;
    specify)
      [[ -n "$V_FILES" ]] || {
        printf 'ERROR=no --files=<file,...>: name the files this run was to write — the ones the human kept were written by an earlier run and are not checked here\n' >&2
        exit 1; }
      V_SCOPE_BAD="$V_SCOPE" ;;
    implement)
      case "$V_SCOPE" in
        backend|frontend) ;;
        *) printf 'ERROR=no --scope=backend|frontend: a verify names the role whose tasks are checked, one role at a time\n' >&2
           exit 1 ;;
      esac
      V_FILES_BAD="$V_FILES" ;;
    *)
      V_FILES_BAD="$V_FILES"; V_SCOPE_BAD="$V_SCOPE" ;;
  esac
  if [[ -n "${V_FILES_BAD:-}" || -n "${V_SCOPE_BAD:-}" ]]; then
    printf 'ERROR=%s takes no %s: --files is /sdd-specify'"'"'s and --scope is /sdd-implement'"'"'s\n' \
      "$CMD" "$([[ -n "${V_FILES_BAD:-}" ]] && printf -- '--files' || printf -- '--scope')" >&2
    exit 1
  fi
else
  if [[ -n "$V_FILES" || -n "$V_SCOPE" ]]; then
    printf 'ERROR=--files and --scope belong to --verify: they name what a finished step is checked against\n' >&2
    exit 1
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/../templates"
SPECS="$ROOT_DIR/_docs"

# What counts as written into a file is a format, and the formats are read in
# one place: `EXISTING=` is the same test `spec-edit.sh scaffold init` sorts by,
# or the gate and the scaffold would disagree about the same files.
if [[ ! -r "$SCRIPT_DIR/lib/format.sh" ]]; then
  printf 'ERROR=missing: %s/lib/format.sh\n' "$SCRIPT_DIR" >&2
  exit 1
fi
. "$SCRIPT_DIR/lib/format.sh"

# Counters, not ${#array[@]}: on bash 3.2 an empty array counts as unset under
# `set -u` and reading its length aborts the script.
STOPS=(); N_STOP=0
ASKS=();  N_ASK=0
WARNS=(); N_WARN=0
stop() { STOPS+=("$1"); N_STOP=$(( N_STOP + 1 )); }
ask()  { ASKS+=("$1");  N_ASK=$((  N_ASK  + 1 )); }
warn() { WARNS+=("$1"); N_WARN=$(( N_WARN + 1 )); }

RC2=0   # a subordinate script exited 2 and that turned into a stop

kv() {
  printf '%s\n' "$1" | awk -v k="$2" '
    index($0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit }
  '
}

# The lines of one `SECTION:` block. A KEY=value line never matches a header,
# so the block ends at the next header or at the end of the output.
section() {
  printf '%s\n' "$1" | awk -v want="$2:" '
    /^[A-Z_]+:$/ { inside = ($0 == want); next }
    inside && NF { print }
  '
}

list_features() {
  find "$SPECS" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null \
    | sed 's|.*/||' | sort
}

# ── The architecture baseline ─────────────────────────────────────
# It has two shapes and a project holds one of them: a folder of sections under
# `_docs/architecture/`, entered through the generated
# `_docs/architecture.index.md`, or the single `_docs/architecture.md`. Which
# shape a project is in is resolved here and nowhere else, so every check,
# every warning and every prompt names the same file.
#
# What is checked of it anywhere in this script is that the entry point exists
# and holds something. Which sections a project keeps is the project's own
# answer — a section that does not apply is deleted, and a check demanding a
# fixed set would overrule that. Whether what the files say is right is the
# architect's job and no file test's: a folder full of files proves nothing.
ARCH_MODE=""; ARCH_ENTRY=""; ARCH_PATH=""
arch_sections() {
  find "$SPECS/architecture" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort
}
if [[ -n "$(arch_sections)" ]]; then
  if [[ -f "$SPECS/architecture.md" ]]; then
    ARCH_MODE="conflict"
  else
    ARCH_MODE="split"
  fi
  ARCH_ENTRY="_docs/architecture.index.md"; ARCH_PATH="$SPECS/architecture.index.md"
elif [[ -f "$SPECS/architecture.md" ]]; then
  ARCH_MODE="mono"
  ARCH_ENTRY="_docs/architecture.md"; ARCH_PATH="$SPECS/architecture.md"
else
  ARCH_MODE="absent"
  ARCH_ENTRY="_docs/architecture.index.md"; ARCH_PATH="$SPECS/architecture.index.md"
fi
arch_present() { [[ -f "$ARCH_PATH" ]] && grep -q '[^[:space:]]' "$ARCH_PATH" 2>/dev/null; }
# Whether anybody has written into the baseline, as against the scaffold having
# copied its templates there. A section file a project added of its own has no
# template to compare against and counts as written.
arch_written() {
  local f
  case "$ARCH_MODE" in
    mono)  ! md_untouched "$SPECS/architecture.md" "$TEMPLATE_DIR/architecture.md" \
             && [[ -s "$SPECS/architecture.md" ]] ;;
    split)
      while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        md_untouched "$f" "$TEMPLATE_DIR/architecture/${f##*/}" && continue
        [[ -s "$f" ]] && return 0
      done <<< "$(arch_sections)"
      return 1 ;;
    *) return 1 ;;
  esac
}
ARCH_CONFLICT_LINE="_docs/architecture.md and _docs/architecture/ are both on disk — the architecture of a project is a folder of sections or a single file, never both, and nothing can say which of the two a role is meant to read. Keep one and delete the other; \`spec-edit.sh arch-index\` rebuilds the index of the folder."

# ── Which scripts this command runs ───────────────────────────────
NEED_FS=1; NEED_BC=0; NEED_RS=0; NEED_NR=0
case "$CMD" in
  init)        NEED_FS=0; NEED_BC=1 ;;
  specify)     NEED_NR=1 ;;
  review)      NEED_NR=1 ;;
  actualize)   NEED_NR=1 ;;
  implement)   NEED_BC=1 ;;
  code-review) NEED_RS=1 ;;
  code-fix)    NEED_RS=1; NEED_BC=1 ;;
esac

# A postcondition is read from fewer places than a precondition: the build
# command and the review set say nothing about what a step left behind.
if [[ $VERIFY -eq 1 ]]; then
  NEED_BC=0; NEED_RS=0; NEED_NR=0
  [[ "$CMD" == "actualize" ]] && NEED_NR=1
fi

# Every script runs before anything is reported: a violation found in the first
# one never skips the second, so the human gets every reason in one message.
FS_ERR="$(mktemp)"; BC_ERR="$(mktemp)"; NR_ERR="$(mktemp)"; RS_ERR="$(mktemp)"
trap 'rm -f "$FS_ERR" "$BC_ERR" "$NR_ERR" "$RS_ERR"' EXIT

FS_OUT=""; FS_RC=0; FS_ERRLINE=""
BC_OUT=""; BC_RC=0; BC_ERRLINE=""
NR_OUT=""; NR_RC=0; NR_ERRLINE=""
RS_OUT=""; RS_RC=0; RS_ERRLINE=""

if [[ $NEED_FS -eq 1 ]]; then
  FS_OUT="$("$SCRIPT_DIR/feature-state.sh" "$FEATURE" "$ROOT_DIR" 2>"$FS_ERR")"; FS_RC=$?
  FS_ERRLINE="$(cat "$FS_ERR")"
fi
if [[ $NEED_BC -eq 1 ]]; then
  BC_OUT="$("$SCRIPT_DIR/build-command.sh" "$ROOT_DIR" 2>"$BC_ERR")"; BC_RC=$?
  BC_ERRLINE="$(cat "$BC_ERR")"
fi
if [[ $NEED_NR -eq 1 ]]; then
  NR_OUT="$("$SCRIPT_DIR/next-req.sh" "$ROOT_DIR" 2>"$NR_ERR")"; NR_RC=$?
  NR_ERRLINE="$(cat "$NR_ERR")"
fi
if [[ $NEED_RS -eq 1 ]]; then
  RS_OUT="$(cd "$ROOT_DIR" && "$SCRIPT_DIR/review-set.sh" "$BASE_ARG" 2>"$RS_ERR")"; RS_RC=$?
  RS_ERRLINE="$(cat "$RS_ERR")"
fi

# Exit 1 is the environment, never the project: it is relayed and nothing else
# is decided from a run that could not read its own inputs.
if [[ $FS_RC -eq 1 || $BC_RC -eq 1 || $NR_RC -eq 1 ]]; then
  [[ $FS_RC -eq 1 ]] && printf '%s\n' "$FS_ERRLINE" >&2
  [[ $BC_RC -eq 1 ]] && printf '%s\n' "$BC_ERRLINE" >&2
  [[ $NR_RC -eq 1 ]] && printf '%s\n' "$NR_ERRLINE" >&2
  exit 1
fi

# ── The state of the feature ──────────────────────────────────────
FOLDER="$FEATURE"; STAGE=""
ST_RAW=""; ST_REQ=""; ST_DES=""; ST_TSK=""
S_REQ=""; S_DES=""; S_TSK=""
T_DONE=0; T_TOTAL=0; T_BLOCKED=0
ST_REVIEW=""; R_DATE=""; R_ROOT=""; R_VERDICT=""
COMPILATION=""; ANOMALIES=""; TASK_RECS=""; COMP_RECS=""
FS_FOUND=0

if [[ $NEED_FS -eq 1 && $FS_RC -eq 0 ]]; then
  FS_FOUND=1
  FOLDER="$(kv "$FS_OUT" FOLDER)"
  STAGE="$(kv "$FS_OUT" STAGE)"
  ST_RAW="$(kv "$FS_OUT" RAW)"
  ST_REQ="$(kv "$FS_OUT" REQUIREMENTS)"
  ST_DES="$(kv "$FS_OUT" DESIGN)"
  ST_TSK="$(kv "$FS_OUT" TASKS)"
  S_REQ="$(kv "$FS_OUT" STATUS_REQUIREMENTS)"
  S_DES="$(kv "$FS_OUT" STATUS_DESIGN)"
  S_TSK="$(kv "$FS_OUT" STATUS_TASKS)"
  T_DONE="$(kv "$FS_OUT" TASKS_DONE)"
  T_TOTAL="$(kv "$FS_OUT" TASKS_TOTAL)"
  T_BLOCKED="$(kv "$FS_OUT" TASKS_BLOCKED)"
  ST_REVIEW="$(kv "$FS_OUT" REVIEW)"
  R_DATE="$(kv "$FS_OUT" REVIEW_DATE)"
  R_ROOT="$(kv "$FS_OUT" REVIEW_ROOT)"
  R_VERDICT="$(kv "$FS_OUT" REVIEW_VERDICT)"
  COMPILATION="$(kv "$FS_OUT" COMPILATION)"
  ANOMALIES="$(section "$FS_OUT" ANOMALIES)"
  TASK_RECS="$(section "$FS_OUT" TASKS)"
  COMP_RECS="$(section "$FS_OUT" COMPILATION_ENTRIES)"
fi

# ══ --verify: what the step left behind ═══════════════════════════
# Only what is mechanical: a file on disk, a marker in it, a task no longer
# open. Everything else the run produced is judged by a human or by a review.
FAILS=(); N_FAIL=0
fail() { FAILS+=("$1"); N_FAIL=$(( N_FAIL + 1 )); }

no_feature_fail() {
  fail "No feature folder for '$FEATURE' under _docs/ — nothing this run was to write is on disk."
}

verify_init() {
  local f
  for f in code-style.md requirements.md; do
    if [[ ! -f "$SPECS/$f" ]]; then
      fail "_docs/$f is not on disk — the setup did not create it."
    elif ! grep -q '[^[:space:]]' "$SPECS/$f" 2>/dev/null; then
      fail "_docs/$f is there and holds nothing — the setup left it blank."
    fi
  done
  # A file existing and a file holding text are both true of a template the
  # scaffold copied and nobody wrote into. The scaffold now runs on brownfield
  # too, so a run cut off between the copy and the analysis leaves exactly that
  # — and without this the next run is told the file is already written and
  # skips it, for the rest of the project's life.
  #
  # `requirements.md` is not tested here: project-baseline.md has it
  # staying the template on purpose, because requirements are not derived from
  # code, so an untouched copy of it is what a successful setup leaves behind.
  if md_untouched "$SPECS/code-style.md" "$TEMPLATE_DIR/code-style.md"; then
    fail "_docs/code-style.md holds nothing but the template it was copied from — the setup created it and never wrote the analysis into it."
  fi
  # The architecture baseline is checked at its entry point and no deeper — the
  # reasoning is where ARCH_MODE is resolved.
  if [[ "$ARCH_MODE" == "conflict" ]]; then
    fail "$ARCH_CONFLICT_LINE"
  elif [[ ! -f "$ARCH_PATH" ]]; then
    fail "$ARCH_ENTRY is not on disk — the setup created no architecture baseline."
  elif ! arch_present; then
    fail "$ARCH_ENTRY is there and holds nothing — the setup created it and never wrote into it."
  fi
}

verify_new() {
  if [[ $FS_RC -eq 2 ]]; then no_feature_fail; return 0; fi
  [[ -d "$SPECS/$FOLDER" ]] || fail "_docs/$FOLDER/ was not created."
  case "$ST_RAW" in
    present) ;;
    empty)   fail "_docs/$FOLDER/raw.md is there and holds nothing — the template was not written into it." ;;
    *)       fail "_docs/$FOLDER/raw.md was not created." ;;
  esac
}

verify_specify() {
  if [[ $FS_RC -eq 2 ]]; then no_feature_fail; return 0; fi
  local name base state marker
  for name in $(printf '%s' "$V_FILES" | tr ',' ' '); do
    base="${name##*/}"
    case "$base" in
      new-requirements.md) state="$ST_REQ"; marker="$S_REQ" ;;
      design.md)       state="$ST_DES"; marker="$S_DES" ;;
      tasks.md)        state="$ST_TSK"; marker="$S_TSK" ;;
      *) printf 'ERROR=--files knows the three spec files only — new-requirements.md, design.md, tasks.md — and got: %s\n' "$base" >&2
         exit 1 ;;
    esac
    case "$state" in
      present)
        # The scaffold runs before the spawn, so a run cut off between the copy
        # and the role's write leaves a template carrying `status: draft` —
        # which every other check here passes.
        if md_untouched "$SPECS/$FOLDER/$base" "$TEMPLATE_DIR/$base"; then
          fail "_docs/$FOLDER/$base holds nothing but the template it was copied from — the scaffold created it and the role it was assigned to never wrote the spec into it."
        elif [[ "$marker" == "absent" ]]; then
          fail "_docs/$FOLDER/$base carries no status — a spec with no marker cannot be told apart from a reviewed one. It is the \`status\` property of the frontmatter, or the \`> Status:\` line of a document written before them."
        elif [[ "$marker" != "draft" ]]; then
          fail "_docs/$FOLDER/$base says status '$marker' where this run writes 'draft' — 'ready' is what /sdd-spec-review leaves, and nothing here promotes a spec."
        fi ;;
      empty) fail "_docs/$FOLDER/$base is there and holds nothing — the role it was assigned to did not write it." ;;
      *)     fail "_docs/$FOLDER/$base is not on disk — the role it was assigned to did not write it." ;;
    esac
  done
}

verify_implement() {
  if [[ $FS_RC -eq 2 ]]; then no_feature_fail; return 0; fi
  local left
  left="$(printf '%s\n' "$TASK_RECS" | awk -F'|' -v s="$V_SCOPE" '
    $2 == "open" && $3 == s { printf "%s%s %s", sep, $1, $5; sep = ", " }
  ')"
  [[ -n "$left" ]] && \
    fail "Still open after the $V_SCOPE role returned: $left. A task is marked by the role that owns the loop — one left open is reported by name, never marked here on its behalf."
}

verify_code_review() {
  if [[ $FS_RC -eq 2 ]]; then no_feature_fail; return 0; fi
  case "$ST_REVIEW" in
    present)
      # The template carries a `verdict` property of its own, so the scaffold's
      # copy answers the check below without a report having been written.
      if md_untouched "$SPECS/$FOLDER/review.md" "$TEMPLATE_DIR/review.md"; then
        fail "_docs/$FOLDER/review.md holds nothing but the template it was copied from — the scaffold created it and the report was never written into it."
      elif [[ -z "$R_VERDICT" || "$R_VERDICT" == "absent" ]]; then
        fail "_docs/$FOLDER/review.md carries no verdict — a report is not one until it says what it concluded. It is the \`verdict\` property of the frontmatter, or the \`> Verdict:\` line of a report written before them."
      fi ;;
    empty) fail "_docs/$FOLDER/review.md is there and holds nothing — the report was not written." ;;
    *)     fail "_docs/$FOLDER/review.md is not on disk — the report was not written." ;;
  esac
}

verify_actualize() {
  if [[ $FS_RC -eq 2 ]]; then no_feature_fail; return 0; fi
  if [[ $NR_RC -eq 2 ]]; then
    fail "_docs/requirements.md is not on disk — nothing of this feature was promoted into it."
    return 0
  fi
  local drafts counter highest
  drafts="$(printf '%s\n' "$COMP_RECS" | awk -F'|' '
    $2 == "draft" { printf "%s%s", sep, $1; sep = ", " }
  ')"
  [[ -n "$drafts" ]] && \
    fail "Still draft in _docs/requirements.md: $drafts. An entry stays draft until its wording matches the final new-requirements.md, and a draft entry keeps the feature short of actualized."
  # Against the entries, never against NEXT: NEXT counts the numbers every
  # feature's new-requirements.md declares as well, and a feature still in review
  # legitimately holds numbers this counter has not reached. What is wrong here
  # is a counter standing on a number an entry already carries.
  # Every sequence the file holds, not one: a project that groups its
  # requirements carries a marker per domain, and an ACC marker standing on a
  # number an ACC entry already has is the same defect as the undomained one.
  local key f_counter f_highest counter highest markers=0
  while IFS='|' read -r key f_counter f_highest _rest; do
    [[ -n "$key" ]] || continue
    counter="${f_counter#COUNTER=}"; highest="${f_highest#HIGHEST=}"
    [[ -n "$counter" ]] && markers=$(( markers + 1 ))
    if [[ -z "$counter" && -n "$highest" ]]; then
      fail "_docs/requirements.md carries no '<!-- Next free number: -->' marker for ${key/#-/the undomained} requirements, and entries already carry numbers up to $highest — the next feature has no number to start from."
    elif [[ -n "$counter" && -n "$highest" ]] && (( 10#$(md_req_number "$counter") <= 10#$(md_req_number "$highest") )); then
      fail "The counter of _docs/requirements.md says $counter and an entry already carries $highest — the next feature would be handed a number that is in use."
    fi
  done <<EOF
$(section "$NR_OUT" DOMAINS | awk -F'|' '{ print $1 "|" $3 "|" $4 }')
EOF
  if [[ $markers -eq 0 ]]; then
    fail "_docs/requirements.md carries no '<!-- Next free number: -->' marker — the next feature has no number to start from."
  fi
}

if [[ $VERIFY -eq 1 ]]; then
  case "$CMD" in
    init)        verify_init ;;
    new)         verify_new ;;
    specify)     verify_specify ;;
    implement)   verify_implement ;;
    code-review) verify_code_review ;;
    actualize)   verify_actualize ;;
  esac
  if [[ $N_FAIL -gt 0 ]]; then printf 'VERIFY=fail\n'; else printf 'VERIFY=ok\n'; fi
  printf '\nFAIL:\n'
  for f in ${FAILS[@]+"${FAILS[@]}"}; do printf '%s\n' "$f"; done
  [[ $N_FAIL -gt 0 ]] && exit 2
  exit 0
fi

# The feature is not there — the same fact under seven commands, and a stop
# under every one but /sdd-next-story, where it is the normal case.
no_feature_stop() {
  local tail="$1" names
  case "$FS_ERRLINE" in
    *"no such feature"*)
      names="$(section "$FS_OUT" FEATURES | awk '{ printf "%s%s", sep, $0; sep = ", " }')"
      stop "No feature '$FEATURE' under _docs/. The feature folders that exist: ${names:-none}. Check the spelling, or start it with /sdd-next-story $FEATURE." ;;
    *"missing:"*)
      stop "The project has no _docs/ yet — $tail Run /sdd-init, then /sdd-next-story $FEATURE." ;;
    *)
      stop "${FS_ERRLINE#ERROR=}" ;;
  esac
  RC2=1
}

# The three spec files. Only `present` satisfies a required file: `empty` and
# `missing` are named apart, because "you have not written it yet" and "it is
# there and blank" send the human to two different places.
require_specs() {
  local tail="$1" pair file state
  for pair in "$ST_REQ:new-requirements.md" "$ST_DES:design.md" "$ST_TSK:tasks.md"; do
    state="${pair%%:*}"; file="${pair#*:}"
    case "$state" in
      present) ;;
      empty)   stop "_docs/$FOLDER/$file is there and holds nothing$tail /sdd-specify $FEATURE writes it." ;;
      *)       stop "_docs/$FOLDER/$file is missing$tail /sdd-specify $FEATURE writes it." ;;
    esac
  done
}

# The status markers of the three files, as one list: ", new-requirements.md
# (draft), tasks.md (no status)". Empty when all three are ready.
draft_list() {
  local pair marker file out=""
  for pair in "$S_REQ:new-requirements.md" "$S_DES:design.md" "$S_TSK:tasks.md"; do
    marker="${pair%%:*}"; file="${pair#*:}"
    [[ "$marker" == "ready" ]] && continue
    [[ "$marker" == "absent" ]] && marker="no status"
    out="$out, $file ($marker)"
  done
  printf '%s' "${out#, }"
}

# ── The build command ─────────────────────────────────────────────
# The values are the human's answer in `.sdd/sdd.conf`, and nothing else: the
# DETECTED: rows are a proposal the script never substitutes for a missing one.
# What the rows do decide here is the SHAPE of the project — which stacks it
# has — and the shape is what says which answers it needs.
BUILD_ROOT=""; BUILD_BACKEND=""; BUILD_FRONTEND=""; BUILD_FILES=0; BASELINE=""
BUILD_DETECTED=""; HAS_BACKEND=0; HAS_FRONTEND=0
PROPOSE_BACKEND=""; PROPOSE_FRONTEND=""
PROPOSE_BACKEND_FILE=""; PROPOSE_FRONTEND_FILE=""
if [[ $NEED_BC -eq 1 && $BC_RC -eq 0 ]]; then
  BUILD_ROOT="$(kv "$BC_OUT" ROOT)"
  BUILD_BACKEND="$(kv "$BC_OUT" BACKEND)"
  BUILD_FRONTEND="$(kv "$BC_OUT" FRONTEND)"
  BUILD_DETECTED="$(section "$BC_OUT" DETECTED)"
  BUILD_FILES="$(printf '%s\n' "$BUILD_DETECTED" | grep -c . || true)"
  while IFS='|' read -r d_dir d_file d_cmd d_stack; do
    [[ -n "$d_stack" ]] || continue
    [[ "$d_dir" == "." ]] && d_path="$d_file" || d_path="$d_dir/$d_file"
    case "$d_stack" in
      backend)  HAS_BACKEND=1
                [[ -z "$PROPOSE_BACKEND"  ]] && { PROPOSE_BACKEND="$d_cmd";  PROPOSE_BACKEND_FILE="$d_path"; } ;;
      frontend) HAS_FRONTEND=1
                [[ -z "$PROPOSE_FRONTEND" ]] && { PROPOSE_FRONTEND="$d_cmd"; PROPOSE_FRONTEND_FILE="$d_path"; } ;;
    esac
  done <<EOF
$BUILD_DETECTED
EOF
fi
# Two stacks and no root command leave BASELINE empty on purpose: the two
# commands are run one after the other, never joined into one shell line — the
# second would start in the directory the first cd'd into.
BASELINE="$BUILD_ROOT"

# The answers a project of this shape needs, and the ASK: for each one it does
# not have. This is the only place a missing build command becomes a verdict:
# `build-command.sh` prints what the human wrote and proposes the rest, and it
# is deliberate that the proposal never takes the place of an answer — a role
# handed a guessed command verifies something nobody agreed to, and the run
# before this step showed it doing exactly that in silence.
#
# The shape decides the keys:
#   backend only        SDD_BUILD_BACKEND, or SDD_BUILD_ROOT standing in
#   frontend only       SDD_BUILD_FRONTEND, or SDD_BUILD_ROOT standing in
#   backend + frontend  both stack keys; SDD_BUILD_ROOT is then the
#                       whole-project verification and stands in for neither
#   neither detected    SDD_BUILD_ROOT — a Makefile, a script, anything the
#                       three build files do not name
# The standing-in is `build-command.sh`'s, so a value that arrives here is
# already the one a role would be handed, and the check is one -z per stack.
ask_build() {
  local key="$1" what="$2" proposal="$3" file="$4"
  if [[ -n "$proposal" ]]; then
    ask "No build command for $what: .sdd/sdd.conf holds no $key, and $file says this project has that stack. Detection proposes \`$proposal\` — accept it or name another, and write the line into .sdd/sdd.conf as $key=<command>. A command is one line run from the project root; nothing is built until it is there, because a proposal is not an answer."
  else
    ask "No build command for $what: .sdd/sdd.conf holds no $key, and no pom.xml, build.gradle or package.json was found to propose one from. Write the command that verifies this project into .sdd/sdd.conf as $key=<command> — one line, run from the project root. Nothing is built until it is there."
  fi
}

check_build_config() {
  if [[ $HAS_BACKEND -eq 1 && $HAS_FRONTEND -eq 1 ]]; then
    [[ -n "$BUILD_BACKEND"  ]] || ask_build SDD_BUILD_BACKEND  "the backend stack"  "$PROPOSE_BACKEND"  "$PROPOSE_BACKEND_FILE"
    [[ -n "$BUILD_FRONTEND" ]] || ask_build SDD_BUILD_FRONTEND "the frontend stack" "$PROPOSE_FRONTEND" "$PROPOSE_FRONTEND_FILE"
  elif [[ $HAS_BACKEND -eq 1 ]]; then
    [[ -n "$BUILD_BACKEND"  ]] || ask_build SDD_BUILD_BACKEND  "the backend stack"  "$PROPOSE_BACKEND"  "$PROPOSE_BACKEND_FILE"
  elif [[ $HAS_FRONTEND -eq 1 ]]; then
    [[ -n "$BUILD_FRONTEND" ]] || ask_build SDD_BUILD_FRONTEND "the frontend stack" "$PROPOSE_FRONTEND" "$PROPOSE_FRONTEND_FILE"
  else
    [[ -n "$BUILD_ROOT" ]] || ask_build SDD_BUILD_ROOT "this project" "" ""
  fi
}

# ── The review set ────────────────────────────────────────────────
RS_BASE=""; RS_ROOT=""; RS_DIFF=""; RS_UNTRACKED=""; RS_NOTES=""; CHANGED=0
if [[ $NEED_RS -eq 1 && $RS_RC -eq 0 ]]; then
  RS_BASE="$(kv "$RS_OUT" BASE)"
  RS_ROOT="$(kv "$RS_OUT" ROOT)"
  RS_DIFF="$(kv "$RS_OUT" DIFF)"
  RS_NOTES="$(section "$RS_OUT" NOTES)"
  RS_UNTRACKED="$(section "$RS_OUT" UNTRACKED)"
  # A stat row carries ' | '; the trailing "N files changed" summary does not.
  n_diff=$(section "$RS_OUT" DIFFSTAT | grep -c ' | ' || true)
  n_untracked=$(printf '%s\n' "$RS_UNTRACKED" | grep -c . || true)
  CHANGED=$(( n_diff + n_untracked ))
fi

# ── The next free REQ number ──────────────────────────────────────
NEXT_REQ=""; REQ_DUPLICATES=""; REQ_DOMAINS=""
# Exit 3 is a printed report too: the domains, the duplicates and the notes are
# all there, and NEXT is empty because the scan found no free number to give.
# Reading it as a failure would drop the table that says why.
if [[ $NEED_NR -eq 1 && ( $NR_RC -eq 0 || $NR_RC -eq 3 ) ]]; then
  NEXT_REQ="$(kv "$NR_OUT" NEXT)"
  REQ_DUPLICATES="$(section "$NR_OUT" DUPLICATES)"
  # The whole table, because the domain a feature's requirements belong to is
  # the session's decision and not this script's: NEXT_REQ answers for the
  # undomained sequence, and REQ_DOMAINS: is where the answer for `ACC` is when
  # the session picks one.
  REQ_DOMAINS="$(section "$NR_OUT" DOMAINS)"
fi

# ══ The checks, per command ═══════════════════════════════════════

check_init() {
  local f missing="" existing=""
  # `EXISTING=` is what the role is told already holds an answer, and a file
  # holding nothing but the template it was copied from holds none. Testing `-f`
  # here handed that file over as written, so an interrupted setup was reported
  # as a finished one for the rest of the project's life.
  for f in code-style.md requirements.md; do
    [[ -f "$TEMPLATE_DIR/$f" ]] || missing="${missing:+$missing,}$f"
    [[ -f "$SPECS/$f" ]] && ! md_untouched "$SPECS/$f" "$TEMPLATE_DIR/$f" \
      && existing="${existing:+$existing,}$f"
  done
  # Both shapes of the architecture baseline are written from templates, so
  # both sets have to be installed whichever shape this project turns out to
  # take. The folder is a starting set and not a required one — what is missing
  # here is an engine that cannot scaffold, not a project that deleted a
  # section it does not need.
  [[ -f "$TEMPLATE_DIR/architecture.md" ]] || missing="${missing:+$missing,}architecture.md"
  [[ -n "$(find "$TEMPLATE_DIR/architecture" -maxdepth 1 -name '*.md' -type f 2>/dev/null)" ]] \
    || missing="${missing:+$missing,}architecture/"
  arch_written && existing="${existing:+$existing,}${ARCH_ENTRY#_docs/}"
  TEMPLATES="ok"
  if [[ -n "$missing" ]]; then
    TEMPLATES="missing:$missing"
    stop "Templates the setup writes from are not there: $missing. The engine is installed incompletely — report it instead of inventing a structure for those files."
  fi
  EXISTING="$existing"

  # Brownfield is a codebase to read: a build file, or source under it. Neither
  # one found is greenfield — nothing to analyze, and that is not a failure.
  local hits
  hits="$(find "$ROOT_DIR" -mindepth 1 -maxdepth 3 \
      \( -name '.git' -o -name '_docs' -o -name '.sdd' -o -name '.claude' \
         -o -name 'node_modules' -o -name 'target' -o -name 'build' -o -name 'dist' \
         -o -name '.venv' -o -name 'vendor' \) -prune -o -type f \
      \( -name 'pom.xml' -o -name 'build.gradle' -o -name 'build.gradle.kts' \
         -o -name 'package.json' -o -name 'Cargo.toml' -o -name 'go.mod' \
         -o -name 'pyproject.toml' -o -name 'composer.json' -o -name 'CMakeLists.txt' \
         -o -name '*.java' -o -name '*.kt' -o -name '*.ts' -o -name '*.tsx' \
         -o -name '*.js' -o -name '*.py' -o -name '*.go' -o -name '*.rs' \
         -o -name '*.rb' -o -name '*.php' -o -name '*.cs' \) -print 2>/dev/null | head -1)"
  if [[ -n "$hits" ]]; then PROJECT="brownfield"; else PROJECT="greenfield"; fi
}

check_new() {
  local bad reason="" lc other exact=0
  # The name alone, before anything on disk is read.
  NAME_OK="yes"; NAME_WARN=""
  case "$FEATURE" in
    */*|*\\*) reason="it carries a path separator" ;;
    .|..)     reason="it is '$FEATURE'" ;;
    .*)       reason="it starts with a dot" ;;
  esac
  if [[ -z "$reason" ]]; then
    bad="$(printf '%s' "$FEATURE" | LC_ALL=C tr -d 'A-Za-z0-9._-')"
    [[ -n "$bad" ]] && reason="it holds '$bad'"
  fi
  if [[ -n "$reason" ]]; then
    NAME_OK="no"
    stop "'$FEATURE' is not a usable folder name: $reason. A usable name holds only letters, digits, '-', '_' and '.', carries no path separator, is not '.' or '..', and does not start with '.'."
  # Two shapes are expected, not one: a PascalCase name a human chose, and a
  # Jira issue key, which carries a hyphen and is never PascalCase. An imported
  # feature is named after its issue, so warning about the key would mean a
  # warning on every import and nothing for the human to do about it.
  elif ! printf '%s' "$FEATURE" | LC_ALL=C grep -qE '^([A-Z][A-Za-z0-9]*|[A-Z][A-Z0-9]*-[0-9]+)$'; then
    NAME_WARN="'$FEATURE' is neither PascalCase nor a Jira issue key. The name is used on disk exactly as given — never renamed, capitalized, or otherwise 'fixed'."
    warn "$NAME_WARN"
  fi

  FEATURES="$(list_features)"

  # A name differing only in case is the same folder on a case-insensitive
  # filesystem — the human picks one of the two spellings before anything is
  # created. This wins over the RAW check below: a name is being chosen, not a
  # file.
  lc="$(printf '%s' "$FEATURE" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r other; do
    [[ -n "$other" ]] || continue
    [[ "$other" == "$FEATURE" ]] && { exact=1; continue; }
    if [[ "$(printf '%s' "$other" | tr '[:upper:]' '[:lower:]')" == "$lc" ]]; then
      stop "The folder '$other' already exists and differs from '$FEATURE' in case alone — on a case-insensitive filesystem they are one and the same folder. Pick one of the two spellings: '$other' or '$FEATURE'."
    fi
  done <<< "$FEATURES"

  if [[ $FS_FOUND -eq 1 && $exact -eq 1 ]]; then
    case "$ST_RAW" in
      present) stop "_docs/$FOLDER/raw.md already holds a description, and this command never overwrites one — delete the file to start over. Edit it, or run /sdd-specify $FEATURE." ;;
      *) ;;
    esac
  else
    ST_RAW="missing"
  fi

  [[ -f "$TEMPLATE_DIR/raw.md" ]] || \
    stop "Template .sdd/templates/raw.md is not there. The engine is installed incompletely — report it instead of inventing a structure for the file."

  if [[ -d "$SPECS" ]]; then
    [[ -w "$SPECS" ]] || stop "$SPECS is not writable — the feature folder cannot be created. Report the filesystem error."
  else
    [[ -w "$ROOT_DIR" ]] || stop "$ROOT_DIR is not writable — _docs/ cannot be created. Report the filesystem error."
  fi
}

check_specify() {
  if [[ $FS_RC -eq 2 ]]; then
    no_feature_stop "there is nothing to specify."
    return 0
  fi
  [[ "$ST_RAW" == "present" ]] || \
    stop "_docs/$FOLDER/raw.md is $ST_RAW — the description this spec is written from is not on disk. /sdd-next-story $FEATURE creates it."

  # A file that is present is not a stop: it sends the run to the human, who
  # decides before anything is generated. An `empty` one is overwritten silently.
  local pair state file marker present=""
  for pair in "$ST_REQ:$S_REQ:new-requirements.md" "$ST_DES:$S_DES:design.md" "$ST_TSK:$S_TSK:tasks.md"; do
    state="${pair%%:*}"; marker="${pair#*:}"; file="${marker#*:}"; marker="${marker%%:*}"
    [[ "$state" == "present" ]] || continue
    # A file the scaffold copied and nobody wrote into is not a spec: it is the
    # shape this run writes into, and asking the human whether it may be
    # overwritten asks them about a template.
    md_untouched "$SPECS/$FOLDER/$file" "$TEMPLATE_DIR/$file" && continue
    [[ "$marker" == "absent" ]] && marker="no status, counted as draft"
    present="$present, $file ($marker)"
  done
  if [[ -n "$present" ]]; then
    ask "These files already hold a spec:${present#,}. Which of them may this run overwrite? Generation does not start until the human answers, and a file marked ready carries the result of a /sdd-spec-review session that overwriting throws away."
  fi

  arch_present || \
    warn "$ARCH_ENTRY is not there — the spec is written without the architecture context, and /sdd-init is what creates it."

  if [[ $NR_RC -eq 2 ]]; then
    NEXT_REQ="REQ-001"
    warn "_docs/requirements.md is not there — create it from .sdd/templates/requirements.md, whose counter starts at REQ-001. The numbers of this run are held by the feature's own new-requirements.md, and /sdd-actualize is what writes them into the compilation."
  elif [[ $NR_RC -eq 3 ]]; then
    stop "No requirement number is free: $(kv "$NR_OUT" TAKEN) are written into the specs without any entry or declaration reserving them. The session issues no number until the human repairs the files — /sdd-actualize is what turns a used number into an entry."
  elif [[ -n "$REQ_DUPLICATES" ]]; then
    stop "The compilation is already inconsistent — carried by more than one entry: $(printf '%s' "$REQ_DUPLICATES" | tr '\n' ' '). No number is issued until the human repairs it — a REQ-### handed out twice corrupts the compilation quietly."
  fi
}

check_review() {
  if [[ $FS_RC -eq 2 ]]; then
    no_feature_stop "there is no spec to review."
    return 0
  fi
  require_specs " — there is nothing to review."

  [[ "$ST_RAW" == "present" ]] || \
    warn "_docs/$FOLDER/raw.md is $ST_RAW — the intent coverage pass of the checklist cannot run, and the session says so."
  [[ "$COMPILATION" == "present" ]] || \
    warn "_docs/requirements.md is not there — the requirements of this feature cannot be compared against the ones the project already has."
  arch_present || \
    warn "$ARCH_ENTRY is not there — the design is reviewed without the architecture context, and /sdd-init is what creates it."
  [[ $NR_RC -eq 2 ]] && NEXT_REQ=""
  [[ -n "$REQ_DUPLICATES" ]] && \
    warn "The compilation carries the same number more than once: $(printf '%s' "$REQ_DUPLICATES" | tr '\n' ' ') — repair it before this session issues a new number."
}

check_implement() {
  if [[ $FS_RC -eq 2 ]]; then
    no_feature_stop "nothing to implement."
  else
    require_specs "."

    local draft
    draft="$(draft_list)"
    [[ -n "$draft" ]] && \
      ask "Not reviewed: $draft. /sdd-spec-review $FEATURE is what promotes a spec to ready. Implementing anyway needs the human to say so in as many words, and the final report then says the work was built from an unreviewed spec."

    # Only when the file is there: a missing tasks.md already has its own line,
    # and one problem never reaches the human as two.
    if [[ "$T_TOTAL" == "0" && "$ST_TSK" == "present" ]]; then
      stop "_docs/$FOLDER/tasks.md holds no parsable '- [ ] **TASK-###**' line — the breakdown is empty or malformed. /sdd-specify $FEATURE writes it."
    fi

    local unknown carriers
    unknown="$(kv "$FS_OUT" UNKNOWN_TYPES)"
    if [[ -n "$unknown" ]]; then
      carriers="$(printf '%s\n' "$TASK_RECS" | awk -F'|' '
        $3 != "backend" && $3 != "frontend" { printf "%s%s", sep, $1; sep = ", " }
      ')"
      stop "Task types no developer role owns: $unknown ('-' is a task with no Type: line). Carried by: ${carriers:-none}. Implementation covers backend and frontend — fix the types in _docs/$FOLDER/tasks.md."
    fi
  fi

  check_build_config

  # `[x]` is the only mark that takes a task out: a blocked one is unchecked,
  # and a re-run retries it with fresh attempts.
  TODO_RECS="$(printf '%s\n' "$TASK_RECS" | awk -F'|' '
    $2 == "open" || $2 == "blocked" { printf "%s|%s|%s|%s|%s\n", $1, $2, $3, $5, $6 }
  ')"

  ROLE_ORDER=""
  case "$(kv "$FS_OUT" TASK_TYPES)" in *backend*) ROLE_ORDER="backend" ;; esac
  case "$(kv "$FS_OUT" TASK_TYPES)" in *frontend*) ROLE_ORDER="${ROLE_ORDER:+$ROLE_ORDER,}frontend" ;; esac

  # What a baseline is measured with is BASELINE, not the build files: a project
  # built by make or a script carries no file this engine detects, and its
  # command is SDD_BUILD_ROOT like any other. A project that named none is the
  # ASK above, so there is nothing left to ask about here.

  [[ "$T_BLOCKED" != "0" ]] && \
    warn "$T_BLOCKED task(s) carry BLOCKED: from an earlier run. They are unchecked, so this run retries them with fresh attempts — their TODO: records carry the reason they failed last time."
}

check_code_review() {
  if [[ $FS_RC -eq 2 ]]; then
    no_feature_stop "there is no specification to review the code against."
  else
    require_specs " — the review has nothing to measure the code against."

    # A draft spec never stops a review: it changes what the report may claim.
    local draft
    draft="$(draft_list)"
    [[ -n "$draft" ]] && \
      warn "Not reviewed: $draft. The yardstick of this review is an unreviewed spec, and the report says so. /sdd-spec-review $FEATURE is what promotes a spec to ready."

    BLOCKED_RECS="$(printf '%s\n' "$TASK_RECS" | awk -F'|' '
      $2 == "blocked" || $2 == "done+blocked" { printf "%s|%s|%s\n", $1, $5, $6 }
    ')"
    [[ "$T_BLOCKED" != "0" ]] && \
      warn "$T_BLOCKED task(s) are blocked. Their code is reviewed like the rest of the set — the report names them as unfinished by design, never as work that went missing."
    [[ "$T_DONE" == "0" ]] && \
      warn "No task is marked [x]. Whatever the working tree holds is reviewed all the same, but the feature is not implemented — check that /sdd-implement $FEATURE actually ran."
  fi

  if [[ $RS_RC -eq 1 ]]; then
    stop "Not a git repository: /sdd-code-review needs git to tell what this feature changed. Nothing here is worked out by reading the tree by hand."
  elif [[ $RS_RC -eq 2 ]]; then
    stop "${RS_ERRLINE#ERROR=}"
    RC2=1
  else
    # What review-set.sh decided about the base it was handed, when it did not
    # simply use it. The warning below says the set is the uncommitted changes;
    # this says why, which is what the human who named a ref needs to read.
    [[ -n "$RS_NOTES" ]] && warn "$RS_NOTES"
    [[ -z "$RS_BASE" ]] && \
      warn "No base branch was detected, so the review set is the uncommitted changes only. The report is labelled a partial review and never reported as complete — re-run as /sdd-code-review $FEATURE <base-ref> to review against a branch."
    [[ "$CHANGED" == "0" ]] && \
      stop "The review set is empty: nothing differs from ${RS_BASE:-the base}, and there are no untracked files. Check that /sdd-implement $FEATURE actually ran, or pass an explicit base — /sdd-code-review $FEATURE <base-ref>."
  fi
}

check_code_fix() {
  if [[ $FS_RC -eq 2 ]]; then
    no_feature_stop "there is no report to act on."
  else
    require_specs " — a fix is written against the spec, and it is not on disk."

    case "$ST_REVIEW" in
      present) ;;
      empty) stop "_docs/$FOLDER/review.md is there and holds nothing — there is no report to act on. /sdd-code-review $FEATURE writes one." ;;
      *)     stop "_docs/$FOLDER/review.md is missing — there is no report to act on. /sdd-code-review $FEATURE writes one." ;;
    esac

    case "$(printf '%s' "$R_VERDICT" | tr '[:upper:]' '[:lower:]')" in
      stale*) warn "The report says '> Verdict: $R_VERDICT' — it was already applied on the date it names, and its findings may be fixed already. A fresh /sdd-code-review $FEATURE is the reliable list." ;;
    esac
  fi

  if [[ $RS_RC -ne 0 ]]; then
    # /sdd-code-fix passes no base, so exit 2 cannot reach here: what is left is
    # a tree git cannot read at all.
    warn "Not a git repository — whether the report still describes the current code cannot be checked. A finding may be about a line that has since moved."
  elif [[ -n "$R_ROOT" && -n "$RS_ROOT" && "$R_ROOT" != "$RS_ROOT" ]]; then
    warn "The report was taken against $R_ROOT and the code now sits on $RS_ROOT — it describes a different commit range. A fix applied to a moved line is never reported as a finding closed."
  fi

  check_build_config
}

check_actualize() {
  if [[ $FS_RC -eq 2 ]]; then
    no_feature_stop "there is nothing to actualize."
    return 0
  fi
  local pair state file
  for pair in "$ST_REQ:new-requirements.md" "$ST_DES:design.md"; do
    state="${pair%%:*}"; file="${pair#*:}"
    case "$state" in
      present) ;;
      empty)   stop "_docs/$FOLDER/$file is there and holds nothing — there is nothing to promote from it. /sdd-specify $FEATURE writes it." ;;
      *)       stop "_docs/$FOLDER/$file is missing — there is nothing to promote from it. /sdd-specify $FEATURE writes it." ;;
    esac
  done

  [[ "$COMPILATION" == "present" ]] || \
    stop "_docs/requirements.md is not there — the entries this feature's requirements become have nowhere to land. /sdd-init creates it."
  arch_present || \
    stop "$ARCH_ENTRY is not there — there is nothing to promote a decision into. /sdd-init owns creating it."
  if [[ $NR_RC -eq 2 ]]; then
    stop "${NR_ERRLINE#ERROR=} — no number is issued from a count made by hand."
    RC2=1
  fi
}

PROJECT=""; TEMPLATES=""; EXISTING=""
NAME_OK=""; NAME_WARN=""; FEATURES=""
TODO_RECS=""; ROLE_ORDER=""; BLOCKED_RECS=""

# Two shapes of the same baseline on disk at once is the one state no reader
# resolves, and it holds for every command — so it is raised here rather than
# repeated in each check.
[[ "$ARCH_MODE" == "conflict" ]] && stop "$ARCH_CONFLICT_LINE"

case "$CMD" in
  init)        check_init ;;
  new)         check_new ;;
  specify)     check_specify ;;
  review)      check_review ;;
  implement)   check_implement ;;
  code-review) check_code_review ;;
  code-fix)    check_code_fix ;;
  actualize)   check_actualize ;;
esac

# ── The verdict ───────────────────────────────────────────────────
# stop beats done beats ask: a run that cannot start is not 'finished', and a
# feature with nothing left to do asks the human nothing.
if [[ $N_STOP -gt 0 ]]; then
  GATE="stop"
elif [[ "$CMD" == "implement" && "$T_TOTAL" != "0" && "$T_DONE" == "$T_TOTAL" ]]; then
  GATE="done"
elif [[ $N_ASK -gt 0 ]]; then
  GATE="ask"
else
  GATE="ok"
fi

# ── Output ────────────────────────────────────────────────────────
printf 'GATE=%s\n' "$GATE"
if [[ "$CMD" != "init" ]]; then
  printf 'FEATURE=%s\n' "$FEATURE"
  printf 'FOLDER=%s\n' "$FOLDER"
  printf 'STAGE=%s\n' "$STAGE"
fi

case "$CMD" in
  init)
    printf 'PROJECT=%s\n' "$PROJECT"
    printf 'TEMPLATES=%s\n' "$TEMPLATES"
    printf 'EXISTING=%s\n' "$EXISTING"
    printf 'BUILD_ROOT=%s\n' "$BUILD_ROOT"
    printf 'BUILD_BACKEND=%s\n' "$BUILD_BACKEND"
    printf 'BUILD_FRONTEND=%s\n' "$BUILD_FRONTEND"
    ;;
  new)
    printf 'NAME_OK=%s\n' "$NAME_OK"
    printf 'NAME_WARN=%s\n' "$NAME_WARN"
    printf 'RAW=%s\n' "$ST_RAW"
    ;;
  specify|review)
    printf 'RAW=%s\n' "$ST_RAW"
    printf 'REQUIREMENTS=%s\n' "$ST_REQ"
    printf 'DESIGN=%s\n' "$ST_DES"
    printf 'TASKS=%s\n' "$ST_TSK"
    printf 'STATUS_REQUIREMENTS=%s\n' "$S_REQ"
    printf 'STATUS_DESIGN=%s\n' "$S_DES"
    printf 'STATUS_TASKS=%s\n' "$S_TSK"
    printf 'COMPILATION=%s\n' "$COMPILATION"
    printf 'NEXT_REQ=%s\n' "$NEXT_REQ"
    if [[ "$CMD" == "specify" ]]; then printf 'MODE=draft\n'; else printf 'MODE=review\n'; fi
    ;;
  implement)
    printf 'TASKS_DONE=%s\n' "$T_DONE"
    printf 'TASKS_TOTAL=%s\n' "$T_TOTAL"
    printf 'TASKS_BLOCKED=%s\n' "$T_BLOCKED"
    printf 'ROLE_ORDER=%s\n' "$ROLE_ORDER"
    printf 'BUILD_ROOT=%s\n' "$BUILD_ROOT"
    printf 'BUILD_BACKEND=%s\n' "$BUILD_BACKEND"
    printf 'BUILD_FRONTEND=%s\n' "$BUILD_FRONTEND"
    printf 'BASELINE=%s\n' "$BASELINE"
    printf 'BUILD_FILES=%s\n' "$BUILD_FILES"
    ;;
  code-review)
    printf 'BASE=%s\n' "$RS_BASE"
    printf 'ROOT=%s\n' "$RS_ROOT"
    printf 'DIFF=%s\n' "$RS_DIFF"
    printf 'CHANGED=%s\n' "$CHANGED"
    printf 'REVIEW_PATH=_docs/%s/review.md\n' "$FOLDER"
    printf 'REVIEW_PREVIOUS=%s\n' "$R_DATE"
    ;;
  code-fix)
    printf 'REVIEW=%s\n' "$ST_REVIEW"
    # The report is read here, by the orchestrator, for the triage — so its path
    # is a key of its own and not a line of the prompt-only SPEC_FILES:.
    printf 'REVIEW_PATH=_docs/%s/review.md\n' "$FOLDER"
    printf 'REVIEW_DATE=%s\n' "$R_DATE"
    printf 'REVIEW_ROOT=%s\n' "$R_ROOT"
    printf 'REVIEW_VERDICT=%s\n' "$R_VERDICT"
    printf 'ROOT=%s\n' "$RS_ROOT"
    printf 'BUILD_ROOT=%s\n' "$BUILD_ROOT"
    printf 'BUILD_BACKEND=%s\n' "$BUILD_BACKEND"
    printf 'BUILD_FRONTEND=%s\n' "$BUILD_FRONTEND"
    ;;
  actualize)
    printf 'REQUIREMENTS=%s\n' "$ST_REQ"
    printf 'DESIGN=%s\n' "$ST_DES"
    printf 'COMPILATION=%s\n' "$COMPILATION"
    printf 'NEXT_REQ=%s\n' "$NEXT_REQ"
    ;;
esac

# Nothing is spawned from a stopped or finished run, so the material a spawn
# prompt is built from is not printed into one.
SPAWNING=0
[[ "$GATE" == "ok" || "$GATE" == "ask" ]] && SPAWNING=1

# A section the command only copies into a prompt is printed for the renderer
# alone: spawn-prompt.sh asks for it with --prompt-data, and its gate run does
# not land in the orchestrator's context.
PROMPT_ONLY=0
[[ $SPAWNING -eq 1 && $PROMPT_DATA -eq 1 ]] && PROMPT_ONLY=1

if [[ $PROMPT_ONLY -eq 1 ]]; then
  case "$CMD" in
    init)
      printf '\nSPEC_FILES:\n'
      printf '%s\n_docs/code-style.md\n_docs/requirements.md\n' "$ARCH_ENTRY" ;;
    specify|review)
      printf '\nSPEC_FILES:\n'
      printf '_docs/%s/raw.md\n' "$FOLDER"
      printf '_docs/%s/new-requirements.md\n' "$FOLDER"
      printf '_docs/%s/design.md\n' "$FOLDER"
      printf '_docs/%s/tasks.md\n' "$FOLDER"
      printf '%s\n_docs/requirements.md\n' "$ARCH_ENTRY" ;;
    implement|code-review)
      printf '\nSPEC_FILES:\n'
      printf '_docs/%s/new-requirements.md\n' "$FOLDER"
      printf '_docs/%s/design.md\n' "$FOLDER"
      printf '_docs/%s/tasks.md\n' "$FOLDER"
      printf '_docs/code-style.md\n%s\n' "$ARCH_ENTRY" ;;
    code-fix)
      printf '\nSPEC_FILES:\n'
      printf '_docs/%s/review.md\n' "$FOLDER"
      printf '_docs/%s/new-requirements.md\n' "$FOLDER"
      printf '_docs/%s/design.md\n' "$FOLDER"
      printf '_docs/%s/tasks.md\n' "$FOLDER"
      printf '_docs/code-style.md\n%s\n' "$ARCH_ENTRY" ;;
    actualize)
      printf '\nSPEC_FILES:\n'
      printf '_docs/%s/new-requirements.md\n' "$FOLDER"
      printf '_docs/%s/design.md\n' "$FOLDER"
      printf '%s\n_docs/requirements.md\n' "$ARCH_ENTRY" ;;
  esac
fi

if [[ $SPAWNING -eq 1 ]]; then
  # The assignments of this run. The table of role → protocols → scope lives
  # here and nowhere else: a role names no protocol, so a path left out of a
  # prompt is caught by nothing, and prose in nine command files was the one
  # place it could go missing.
  P=".sdd/protocols"
  [[ "$CMD" != "new" ]] && printf '\nSPAWN:\n'   # /sdd-next-story spawns nobody
  case "$CMD" in
    init)
      # Only a brownfield tree has something to read. On greenfield the section
      # stays empty, so a command that spawns what is printed spawns nobody.
      [[ "$PROJECT" == "brownfield" ]] &&
        printf 'architect|%s/project-baseline.md,%s/docs-format.md|baseline-from-codebase\n' "$P" "$P" ;;
    specify)
      printf 'requirements-engineer|%s/spec-modes.md,%s/requirements-writing.md,%s/docs-format.md|requirements\n' "$P" "$P" "$P"
      printf 'architect|%s/spec-modes.md,%s/architecture-design.md,%s/task-breakdown.md,%s/docs-format.md|design+tasks\n' "$P" "$P" "$P" "$P" ;;
    review)
      printf 'requirements-engineer|%s/spec-modes.md,%s/spec-checklist.md,%s/interview.md,%s/requirements-writing.md,%s/docs-format.md|requirements\n' "$P" "$P" "$P" "$P" "$P"
      printf 'architect|%s/spec-modes.md,%s/spec-checklist.md,%s/interview.md,%s/architecture-design.md,%s/task-breakdown.md,%s/docs-format.md|design+tasks\n' "$P" "$P" "$P" "$P" "$P" "$P" ;;
    implement)
      # Only the stacks the breakdown actually carries, in ROLE_ORDER: backend
      # before frontend, because the frontend spawn is handed what the backend
      # came back blocked on.
      case ",$ROLE_ORDER," in *,backend,*)
        printf 'backend-developer|%s/developer.md,%s/task-loop.md|backend\n' "$P" "$P" ;; esac
      case ",$ROLE_ORDER," in *,frontend,*)
        printf 'frontend-developer|%s/developer.md,%s/task-loop.md|frontend\n' "$P" "$P" ;; esac ;;
    code-review)
      printf 'code-reviewer|%s/code-review.md,%s/docs-format.md|review-set\n' "$P" "$P" ;;
    code-fix)
      # Which stacks have findings is in the report's prose and in the triage
      # the human settled — both candidates are printed, and the command drops
      # the record for a stack this run has no work in.
      printf 'backend-developer|%s/developer.md|findings-backend\n' "$P"
      printf 'frontend-developer|%s/developer.md|findings-frontend\n' "$P" ;;
    actualize)
      printf 'architect|%s/project-baseline.md,%s/docs-format.md|baseline-from-feature\n' "$P" "$P" ;;
  esac
fi

case "$CMD" in
  init)
    # The stacks this project has, and the command each is usually verified
    # with. /sdd-init puts them to the human one at a time and writes the
    # answers into .sdd/sdd.conf; nothing else here reads them.
    printf '\nDETECTED:\n'
    [[ -n "$BUILD_DETECTED" ]] && printf '%s\n' "$BUILD_DETECTED"
    ;;
  new)
    printf '\nFEATURES:\n'
    [[ -n "$FEATURES" ]] && printf '%s\n' "$FEATURES"
    ;;
  specify)
    printf '\nREQ_DOMAINS:\n'
    [[ -n "$REQ_DOMAINS" ]] && printf '%s\n' "$REQ_DOMAINS"
    printf '\nREQ_DUPLICATES:\n'
    [[ -n "$REQ_DUPLICATES" ]] && printf '%s\n' "$REQ_DUPLICATES"
    ;;
  review)
    printf '\nREQ_DOMAINS:\n'
    [[ -n "$REQ_DOMAINS" ]] && printf '%s\n' "$REQ_DOMAINS"
    printf '\nREQ_DUPLICATES:\n'
    [[ -n "$REQ_DUPLICATES" ]] && printf '%s\n' "$REQ_DUPLICATES"
    # TASKS: stays: the coverage matrix is the orchestrator's own work.
    if [[ $SPAWNING -eq 1 ]]; then
      printf '\nTASKS:\n'
      [[ -n "$TASK_RECS" ]] && printf '%s\n' "$TASK_RECS"
    fi
    if [[ $PROMPT_ONLY -eq 1 ]]; then
      printf '\nCOMPILATION_ENTRIES:\n'
      [[ -n "$COMP_RECS" ]] && printf '%s\n' "$COMP_RECS"
    fi
    ;;
  implement)
    # The task list feeds the prompt and nothing else: what a role left undone
    # is read back by --verify --scope=, not by the orchestrator from TODO:.
    if [[ $PROMPT_ONLY -eq 1 ]]; then
      printf '\nTODO:\n'
      [[ -n "$TODO_RECS" ]] && printf '%s\n' "$TODO_RECS"
    fi
    ;;
  code-review)
    if [[ $PROMPT_ONLY -eq 1 ]]; then
      printf '\nUNTRACKED:\n'
      [[ -n "$RS_UNTRACKED" ]] && printf '%s\n' "$RS_UNTRACKED"
      printf '\nBLOCKED:\n'
      [[ -n "$BLOCKED_RECS" ]] && printf '%s\n' "$BLOCKED_RECS"
    fi
    ;;
  actualize)
    # The domains the compilation already holds: the entries this promotes carry
    # the numbers the feature declared, and the counter each of them moves is
    # its own domain's.
    printf '\nREQ_DOMAINS:\n'
    [[ -n "$REQ_DOMAINS" ]] && printf '%s\n' "$REQ_DOMAINS"
    if [[ $SPAWNING -eq 1 ]]; then
      printf '\nCOMPILATION_ENTRIES:\n'
      [[ -n "$COMP_RECS" ]] && printf '%s\n' "$COMP_RECS"
    fi
    ;;
esac

printf '\nSTOP:\n'
for s in ${STOPS[@]+"${STOPS[@]}"}; do printf '%s\n' "$s"; done

printf '\nASK:\n'
for a in ${ASKS[@]+"${ASKS[@]}"}; do printf '%s\n' "$a"; done

printf '\nWARN:\n'
for w in ${WARNS[@]+"${WARNS[@]}"}; do printf '%s\n' "$w"; done

printf '\nANOMALIES:\n'
[[ -n "$ANOMALIES" ]] && printf '%s\n' "$ANOMALIES"

printf '\nNOTES:\n'
fs_notes="$(section "$FS_OUT" NOTES)"
bc_notes="$(section "$BC_OUT" NOTES)"
nr_notes="$(section "$NR_OUT" NOTES)"
[[ -n "$fs_notes" ]] && printf '%s\n' "$fs_notes" | sed 's/^/feature-state: /'
[[ -n "$bc_notes" ]] && printf '%s\n' "$bc_notes" | sed 's/^/build-command: /'
[[ -n "$nr_notes" ]] && printf '%s\n' "$nr_notes" | sed 's/^/next-req: /'

[[ $RC2 -eq 1 ]] && exit 2
exit 0
