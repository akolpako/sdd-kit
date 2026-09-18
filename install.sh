#!/usr/bin/env bash

# ── Bash version gate ─────────────────────────────────────────────
# The folder browser uses mapfile, namerefs and fractional read timeouts —
# all bash 4+. macOS still ships 3.2.57, where those fail one by one with
# errors that say nothing about the actual cause. Fail here instead, once.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  echo "SDD installer requires bash 4+ (this is ${BASH_VERSION:-not bash}; macOS ships 3.2)." >&2
  echo "Install a newer one:  brew install bash" >&2
  echo "Then re-run:          $0" >&2
  exit 1
fi

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Colors ────────────────────────────────────────────────────────
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
REVERSE='\033[7m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BRIGHT_CYAN='\033[1;36m'
BRIGHT_WHITE='\033[1;37m'

# ── Banner ────────────────────────────────────────────────────────
print_banner() {
  printf "\n"
  printf "${BRIGHT_CYAN}${BOLD}"
  printf "  ███████╗██████╗ ██████╗ \n"
  printf "  ██╔════╝██╔══██╗██╔══██╗\n"
  printf "  ███████╗██║  ██║██║  ██║\n"
  printf "  ╚════██║██║  ██║██║  ██║\n"
  printf "  ███████║██████╔╝██████╔╝\n"
  printf "  ╚══════╝╚═════╝ ╚═════╝ \n"
  printf "${RESET}"
  printf "  ${BRIGHT_WHITE}${BOLD}S p e c - D r i v e n   D e v e l o p m e n t${RESET}\n"
  printf "  ${DIM}Setup Installer${RESET}\n"
  printf "\n"
}

# ── Folder Browser ────────────────────────────────────────────────
VISIBLE_ROWS=10

# Get subdirectories of a path (sorted, no hidden except . entry)
get_dirs() {
  local path="$1"
  local dirs=()
  dirs+=(".")
  local d
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    dirs+=("${d##*/}")
  done < <(find "$path" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | sort)
  printf '%s\n' "${dirs[@]}"
}

# Read a single keypress, return symbolic name
read_key() {
  local key char seq
  IFS= read -rsn1 char || char=""
  if [[ "$char" == $'\033' ]]; then
    IFS= read -rsn2 -t 0.1 seq 2>/dev/null || seq=""
    case "$seq" in
      "[A") key="UP" ;;
      "[B") key="DOWN" ;;
      "[C") key="RIGHT" ;;
      "[D") key="LEFT" ;;
      *)    key="ESC" ;;
    esac
  elif [[ "$char" == "" || "$char" == $'\n' ]]; then
    key="ENTER"
  else
    key="$char"
  fi
  printf '%s' "$key"
}

# Draw the folder list (10 visible rows)
draw_list() {
  local -n _dirs=$1
  local selected=$2
  local scroll=$3
  local current_path=$4
  local total=${#_dirs[@]}
  local end=$(( scroll + VISIBLE_ROWS ))
  if (( end > total )); then end=$total; fi

  printf "\r${CYAN}  Location: ${BRIGHT_WHITE}${BOLD}%s${RESET}\n" "$current_path"
  printf "  ${DIM}↑↓ navigate  →  enter  ←  back  Enter select${RESET}\n"
  printf "\n"

  local i
  for (( i = scroll; i < end; i++ )); do
    local name="${_dirs[$i]}"
    local prefix="    "
    if (( i == selected )); then
      if [[ "$name" == "." ]]; then
        printf "  ${REVERSE}${BRIGHT_CYAN}${BOLD} ▶  %-40s${RESET}\n" "(here)"
      else
        printf "  ${REVERSE}${BRIGHT_WHITE}${BOLD} ▸  %-40s${RESET}\n" "$name/"
      fi
    else
      if [[ "$name" == "." ]]; then
        printf "  ${CYAN}   %-40s${RESET}\n" "(here)"
      else
        printf "  ${DIM}   %-40s${RESET}\n" "$name/"
      fi
    fi
  done

  # Scroll indicator
  if (( total > VISIBLE_ROWS )); then
    printf "\n  ${DIM}Showing %d–%d of %d folders${RESET}\n" "$(( scroll + 1 ))" "$end" "$total"
  else
    printf "\n"
  fi
}

# Count lines drawn so we can erase and redraw
lines_drawn() {
  local total=$1
  local visible=$(( total < VISIBLE_ROWS ? total : VISIBLE_ROWS ))
  local extra=0
  if (( total > VISIBLE_ROWS )); then extra=1; fi
  echo $(( 3 + visible + 1 + extra ))  # header(3) + rows + blank + maybe scroll line
}

erase_lines() {
  local n=$1
  local i
  for (( i = 0; i < n; i++ )); do
    printf '\033[A\033[2K'
  done
}

browse_folder() {
  local current
  current="$(cd ~ 2>/dev/null && pwd || echo /)"

  local selected=0
  local scroll=0

  tput civis 2>/dev/null || true  # hide cursor

  # Initial draw
  mapfile -t dirs < <(get_dirs "$current")
  local total=${#dirs[@]}
  local drawn=0

  while true; do
    if (( drawn > 0 )); then
      erase_lines "$drawn"
    fi
    draw_list dirs "$selected" "$scroll" "$current"
    drawn=$(lines_drawn "$total")

    local key
    key=$(read_key)

    case "$key" in
      UP)
        if (( selected > 0 )); then
          selected=$(( selected - 1 ))
          if (( selected < scroll )); then
            scroll=$(( scroll - 1 ))
          fi
        fi
        ;;
      DOWN)
        if (( selected < total - 1 )); then
          selected=$(( selected + 1 ))
          if (( selected >= scroll + VISIBLE_ROWS )); then
            scroll=$(( scroll + 1 ))
          fi
        fi
        ;;
      RIGHT)
        local name="${dirs[$selected]}"
        if [[ "$name" != "." ]]; then
          local next="$current/$name"
          if [[ -d "$next" ]]; then
            current="$next"
            mapfile -t dirs < <(get_dirs "$current")
            total=${#dirs[@]}
            selected=0
            scroll=0
          fi
        fi
        ;;
      LEFT)
        local parent
        parent="$(dirname "$current")"
        if [[ "$parent" != "$current" ]]; then
          local old_base
          old_base="$(basename "$current")"
          current="$parent"
          mapfile -t dirs < <(get_dirs "$current")
          total=${#dirs[@]}
          # Try to land on the folder we came from
          selected=0
          scroll=0
          local j
          for (( j = 0; j < total; j++ )); do
            if [[ "${dirs[$j]}" == "$old_base" ]]; then
              selected=$j
              scroll=$(( selected > VISIBLE_ROWS - 1 ? selected - VISIBLE_ROWS + 1 : 0 ))
              break
            fi
          done
        fi
        ;;
      ENTER)
        local chosen="${dirs[$selected]}"
        if [[ "$chosen" == "." ]]; then
          erase_lines "$drawn"
          tput cnorm 2>/dev/null || true
          SELECTED_DIR="$current"
          return 0
        else
          local target="$current/$chosen"
          if [[ -d "$target" ]]; then
            erase_lines "$drawn"
            tput cnorm 2>/dev/null || true
            SELECTED_DIR="$target"
            return 0
          fi
        fi
        ;;
    esac
  done
}

# ── Menu picker ───────────────────────────────────────────────────
# One arrow-key list, used for every choice that is not a folder: the action,
# the host, the project. The reverse-video idiom is the folder browser's, so
# there is one way to pick a thing in this installer.
#
# A row a run cannot act on — a project whose folder is gone, on a sync — is
# listed and skipped over rather than hidden, because the row is the only place
# that says the folder went missing.
MENU_CHOICE=-1
MENU_DISABLED=()

menu_enabled() {
  (( ${#MENU_DISABLED[@]} == 0 )) && return 0
  [[ "${MENU_DISABLED[$1]:-0}" == "0" ]]
}

# Returns 1 when the list was left without a choice: Esc, ← or nothing
# selectable in it. Every caller has somewhere to go back to.
choose_menu() {
  local title="$1"
  local -n _labels=$2
  local total=${#_labels[@]}
  local selected=0 scroll=0 drawn=0 key i end extra

  MENU_CHOICE=-1
  (( total > 0 )) || return 1

  while (( selected < total )) && ! menu_enabled "$selected"; do
    selected=$(( selected + 1 ))
  done
  (( selected < total )) || return 1

  tput civis 2>/dev/null || true

  while true; do
    if (( drawn > 0 )); then
      erase_lines "$drawn"
    fi

    end=$(( scroll + VISIBLE_ROWS ))
    if (( end > total )); then end=$total; fi

    printf "\r${CYAN}  %s${RESET}\n" "$title"
    printf "  ${DIM}↑↓ navigate  Enter select  Esc back${RESET}\n"
    printf "\n"
    for (( i = scroll; i < end; i++ )); do
      if (( i == selected )); then
        printf "  ${REVERSE}${BRIGHT_WHITE}${BOLD} ▸  %-56s${RESET}\n" "${_labels[$i]}"
      elif menu_enabled "$i"; then
        printf "  ${CYAN}   %-56s${RESET}\n" "${_labels[$i]}"
      else
        printf "  ${DIM}   %-56s${RESET}\n" "${_labels[$i]}"
      fi
    done
    printf "\n"

    extra=0
    if (( total > VISIBLE_ROWS )); then
      printf "  ${DIM}Showing %d–%d of %d${RESET}\n" "$(( scroll + 1 ))" "$end" "$total"
      extra=1
    fi
    drawn=$(( 4 + end - scroll + extra ))

    key=$(read_key)
    case "$key" in
      UP)
        for (( i = selected - 1; i >= 0; i-- )); do
          if menu_enabled "$i"; then
            selected=$i
            break
          fi
        done
        if (( selected < scroll )); then
          scroll=$selected
        fi
        ;;
      DOWN)
        for (( i = selected + 1; i < total; i++ )); do
          if menu_enabled "$i"; then
            selected=$i
            break
          fi
        done
        if (( selected >= scroll + VISIBLE_ROWS )); then
          scroll=$(( selected - VISIBLE_ROWS + 1 ))
        fi
        ;;
      ESC|LEFT)
        erase_lines "$drawn"
        tput cnorm 2>/dev/null || true
        return 1
        ;;
      ENTER)
        erase_lines "$drawn"
        tput cnorm 2>/dev/null || true
        MENU_CHOICE=$selected
        return 0
        ;;
    esac
  done
}

# ── Host picker ───────────────────────────────────────────────────
# Which host reads the files this install writes.
HOST_KEYS=(claude copilot)
HOST_LABELS=("Claude Code" "GitHub Copilot  (CLI and VS Code)")

choose_host() {
  MENU_DISABLED=()
  choose_menu "Which host reads these files?" HOST_LABELS || return 1
  SELECTED_HOST="${HOST_KEYS[$MENU_CHOICE]}"
}

# ── Install ───────────────────────────────────────────────────────
# --sync walks every registered project and would otherwise repeat the whole
# file list per project; there, only what changed is worth a line.
LINK_REPORT_ALL=1

# ── The manifest ──────────────────────────────────────────────────
# The engine installs copies, and a copy carries no proof of where it came
# from. The manifest is that proof: one line per file the installer wrote, with
# the checksum of what it wrote, so a later run can tell its own file from one
# the project has edited since. It records what the installer put there, not
# what the engine holds now — those are different questions, and only the first
# one keeps "edited in the project" answerable after the engine has moved on.
#
# Paths are project-relative, so a moved project is still readable. Directories
# are not listed: prune_empty_dirs already decides those. Neither are the three
# merged files — CLAUDE.md, .github/copilot-instructions.md and .gitignore —
# which belong to the project, block and all.
MANIFEST_NAME=".sdd/.sdd-manifest"
MANIFEST_LINES=()

# What the manifest said before this run: path -> the checksum the installer
# last wrote there. It is what tells an untouched copy from an edited one.
declare -A MANIFEST_HAVE=()

# What this run has recorded so far, as a set. prune_target subtracts it from
# MANIFEST_HAVE to get the paths the engine no longer ships.
declare -A MANIFEST_NOW=()

# The host the manifest records, which is the same value the registry holds.
# remove_installed needs it to write the manifest back for a project it could
# not finish emptying.
MANIFEST_HOST=""

# Files the project edited since they were installed. Collected during the walk
# and settled once at the end of it, so one edited file never holds up the rest
# of the tree and a project with twenty of them still asks one question.
EDITED_LABELS=()
EDITED_SRCS=()
EDITED_DSTS=()

# "force", "keep", or empty for "ask if there is anybody to ask". --force and
# --keep-edits set it; see the flag handling near usage().
EDIT_ANSWER=""

# ── Checksums ─────────────────────────────────────────────────────
# Every file the installer touches is checksummed at least once, and a project
# holds well over a hundred of them. One process per file — and the pipe to
# cut made it two — is what a plain re-install spent nearly all its time on,
# forking rather than hashing. So the sums are taken in bulk instead: one pass
# over the engine, one over what the manifest says the project already has,
# and afterwards every read comes from here.
#
# The cache is an optimization and never a second source of truth. A path it
# does not hold is hashed on its own, which is what keeps the answer right for
# a file the bulk pass could not name — one with a newline in it, say, which
# both tools escape rather than print.

# shasum is what macOS ships, sha256sum what most Linux images ship. Settled
# once at startup: the probe was cheap, but it ran per file.
if command -v shasum >/dev/null 2>&1; then
  SUM_CMD=(shasum -a 256)
else
  SUM_CMD=(sha256sum)
fi

declare -A SUM_CACHE=()

# The sums of many files at once. Both tools write one line per file as
# <64 hex><two spaces><path>, and a line shaped any other way — the escaped
# form, or a file that could not be read — is skipped rather than guessed at.
#
# Chunked because an argument list has a limit and a project's tree has none.
sums_prime() {
  local paths=("$@") total=${#paths[@]} i chunk=500 line sum path
  (( total )) || return 0

  for (( i = 0; i < total; i += chunk )); do
    while IFS= read -r line; do
      [[ "${line:64:2}" == "  " ]] || continue
      sum="${line:0:64}"
      path="${line:66}"
      [[ -n "$path" ]] || continue
      SUM_CACHE["$path"]="$sum"
    done < <("${SUM_CMD[@]}" -- "${paths[@]:i:chunk}" 2>/dev/null)
  done
}

# Every file under one directory, in one pass. This is the engine side: the
# walk reads the source sum of all but the files it skips, and hashing those
# few as well costs less than working out which they are.
sums_prime_tree() {
  local dir="$1" paths=() p
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' p; do
    paths+=("$p")
  done < <(find "$dir" -type f -print0 2>/dev/null)
  sums_prime "${paths[@]}"
}

# The project side: the files the manifest names, as the project has them now.
# A path the manifest lists and the project no longer has is left out — every
# caller tests for it before asking for its sum.
sums_prime_manifest() {
  local target="$1" rel paths=()
  (( ${#MANIFEST_HAVE[@]} )) || return 0
  for rel in "${!MANIFEST_HAVE[@]}"; do
    [[ -f "$target/$rel" ]] || continue
    paths+=("$target/$rel")
  done
  sums_prime "${paths[@]}"
}

file_sum() {
  local sum="${SUM_CACHE[$1]-}"
  if [[ -z "$sum" ]]; then
    sum="$("${SUM_CMD[@]}" -- "$1")"
    sum="${sum:0:64}"
    SUM_CACHE["$1"]="$sum"
  fi
  printf '%s' "$sum"
}

# ── Permission bits ───────────────────────────────────────────────
# Read in bulk and cached for the same reason the sums are: every file the
# walk writes needs its source's mode, and asking stat once per file cost more
# than reading the whole engine's modes in a single pass. Which stat this is
# gets settled once as well, rather than probed on every call.
#
# The cache is an optimization, not a source of truth: a path it does not hold
# is read on its own.
if stat -f '%OLp' . >/dev/null 2>&1; then
  STAT_MODE_ARGS=(-f '%OLp')
  STAT_MODE_LIST_ARGS=(-f '%OLp %N')
else
  STAT_MODE_ARGS=(-c '%a')
  STAT_MODE_LIST_ARGS=(-c '%a %n')
fi

declare -A MODE_CACHE=()

# One line per file, the mode then a space then the path as it was given. A
# line without both is skipped and left to file_mode's own call.
modes_prime() {
  local paths=("$@") total=${#paths[@]} i chunk=500 line mode path
  (( total )) || return 0

  for (( i = 0; i < total; i += chunk )); do
    while IFS= read -r line; do
      [[ "$line" == *" "* ]] || continue
      mode="${line%% *}"
      path="${line#* }"
      [[ -n "$mode" && -n "$path" ]] || continue
      MODE_CACHE["$path"]="$mode"
    done < <(stat "${STAT_MODE_LIST_ARGS[@]}" -- "${paths[@]:i:chunk}" 2>/dev/null)
  done
}

modes_prime_tree() {
  local dir="$1" paths=() p
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' p; do
    paths+=("$p")
  done < <(find "$dir" -type f -print0 2>/dev/null)
  modes_prime "${paths[@]}"
}

file_mode() {
  local mode="${MODE_CACHE[$1]-}"
  if [[ -z "$mode" ]]; then
    mode="$(stat "${STAT_MODE_ARGS[@]}" -- "$1")"
    MODE_CACHE["$1"]="$mode"
  fi
  printf '%s' "$mode"
}

# The modes a run still owes its copies, collected here and set in one call per
# distinct mode instead of one per file. A hundred and thirty chmod processes
# per install is half a second of forking to set two values, 644 and 755.
#
# Deferring is safe because nothing between the copy and the flush reads a
# destination's mode: file_sum takes the sum from the source, and prune_target
# only ever removes paths this run did not write. The flush happens in
# manifest_write, which is the one point every flow that copied anything has to
# pass through — the manifest is written from the same copies. A run that dies
# before that point leaves its copies with whatever mode cp gave them, and it
# leaves no manifest either: the install is unfinished on both counts, and the
# fix for both is the same re-run.
CHMOD_MODES=()
CHMOD_PATHS=()

chmod_later() {
  CHMOD_MODES+=("$1")
  CHMOD_PATHS+=("$2")
}

modes_flush() {
  local n=${#CHMOD_PATHS[@]} i mode
  (( n )) || return 0

  # The distinct modes, in the order they first turned up.
  local -A seen=()
  local modes=()
  for (( i = 0; i < n; i++ )); do
    mode="${CHMOD_MODES[$i]}"
    [[ -n "${seen[$mode]-}" ]] && continue
    seen["$mode"]=1
    modes+=("$mode")
  done

  local -a batch
  for mode in "${modes[@]}"; do
    batch=()
    for (( i = 0; i < n; i++ )); do
      [[ "${CHMOD_MODES[$i]}" == "$mode" ]] && batch+=("${CHMOD_PATHS[$i]}")
    done
    # No `--`: BSD chmod does not take it. Every path here is absolute — the
    # target is resolved with `cd && pwd` before the walk starts — so there is
    # nothing for chmod to read as an option.
    (( ${#batch[@]} )) && chmod "$mode" "${batch[@]}"
  done

  CHMOD_MODES=()
  CHMOD_PATHS=()
  return 0
}

# One manifest line. Every path this run keeps goes through here, whether it
# was written now or left exactly as the project has it.
manifest_line() {
  local label="$1" sum="$2"
  MANIFEST_LINES+=("$sum"$'\t'"$label")
  MANIFEST_NOW["$label"]=1
}

# The manifest as this project has it, before the run rewrites it. A project
# with no manifest — installed before the engine copied, or not installed at
# all — reads as empty, which is what makes every existing file a real file the
# installer never wrote.
manifest_read() {
  local target="$1" line sum rel
  MANIFEST_HAVE=()
  MANIFEST_HOST=""
  [[ -f "$target/$MANIFEST_NAME" ]] || return 0
  while IFS=$'\t' read -r sum rel || [[ -n "$sum" ]]; do
    [[ -n "$rel" ]] || continue
    if [[ "$sum" == "host" ]]; then
      MANIFEST_HOST="$rel"
      continue
    fi
    case "$sum" in '#'*) continue ;; esac
    MANIFEST_HAVE["$rel"]="$sum"
  done < "$target/$MANIFEST_NAME"
}

# Written once, at the end of the walk. A run that fails half-way leaves the
# manifest it already had, never one claiming files it never wrote.
manifest_write() {
  modes_flush
  local target="$1" host="$2"
  [[ -d "$target/.sdd" ]] || mkdir -p "$target/.sdd"
  {
    printf '# Written by install.sh. Do not edit.\n'
    printf 'host\t%s\n' "$host"
    if (( ${#MANIFEST_LINES[@]} )); then
      printf '%s\n' "${MANIFEST_LINES[@]}" | LC_ALL=C sort -t$'\t' -k2
    fi
  } > "$target/$MANIFEST_NAME"
}

# One engine file, copied into the project and recorded in the manifest.
#
# A symlink into $SRC_DIR is an install from the engine as it was before it
# copied; it is replaced by the copy, which is all the migration this needs.
# Any other symlink is the project's own and is left alone.
#
# A real file is one of three things. With no manifest line it is a file the
# installer never wrote, and it is refused exactly as it always was. With a
# line whose checksum still matches, it is this installer's own copy: silently
# replaced when the engine's differs, silently left when it does not. With a
# line whose checksum differs, the project edited it, and that is not the
# walk's to decide — it goes to resolve_edits with the rest of them.
install_item() {
  local src="$1"
  local dst="$2"
  local label="$3"
  local was now

  if [[ -L "$dst" ]]; then
    case "$(readlink "$dst")" in
      "$SRC_DIR"/*) rm "$dst" ;;
      *)
        printf "  ${YELLOW}\u26a0${RESET}  %s ${DIM}(skipped \u2014 real file exists)${RESET}\n" "$label"
        return 0
        ;;
    esac
  elif [[ -e "$dst" ]]; then
    was="${MANIFEST_HAVE[$label]-}"
    if [[ -z "$was" ]]; then
      printf "  ${YELLOW}\u26a0${RESET}  %s ${DIM}(skipped \u2014 real file exists)${RESET}\n" "$label"
      return 0
    fi
    now="$(file_sum "$dst")"
    if [[ "$now" != "$was" ]]; then
      EDITED_LABELS+=("$label")
      EDITED_SRCS+=("$src")
      EDITED_DSTS+=("$dst")
      return 0
    fi
    if [[ "$(file_sum "$src")" == "$now" ]]; then
      if (( LINK_REPORT_ALL )); then
        printf "  ${DIM}\u2013${RESET}  %s ${DIM}(unchanged)${RESET}\n" "$label"
      fi
      manifest_line "$label" "$now"
      return 0
    fi
  fi

  write_item "$src" "$dst" "$label"
}

# The copy itself, and the line that records it.
write_item() {
  local src="$1" dst="$2" label="$3" sum

  cp "$src" "$dst"
  # .sdd/scripts/*.sh have to stay executable: a copy that is not fails at the
  # first gate.sh call, and that failure reads as an engine bug rather than an
  # install one. Recorded rather than set here — see modes_flush.
  chmod_later "$(file_mode "$src")" "$dst"
  # cp wrote the source's bytes, so the source's sum is the sum of what now
  # sits at the destination. Reading the file back would only ask the disk a
  # question already answered.
  sum="$(file_sum "$src")"
  SUM_CACHE["$dst"]="$sum"
  manifest_line "$label" "$sum"
  printf "  ${GREEN}\u2713${RESET}  %s\n" "$label"
}

# The files the project edited, settled once for the whole project.
#
# Neither answer is the installer's to pick. Overwriting loses work somebody
# did; keeping leaves a project running a version of the engine nobody can
# identify. So the run says which files these are and asks — once, for all of
# them, because a project with twenty edited prompts must not become twenty
# questions.
#
# Either answer leaves the paths in the manifest and so leaves them the
# installer's to remove on uninstall. Keeping also keeps the checksum the
# manifest already had, so the next run asks again.
resolve_edits() {
  local n=${#EDITED_LABELS[@]} i answer decision=""

  (( n )) || return 0

  printf "\n  ${YELLOW}%d file(s) changed in this project since they were installed:${RESET}\n" "$n"
  for (( i = 0; i < n; i++ )); do
    printf "    %s\n" "${EDITED_LABELS[$i]}"
  done

  decision="$EDIT_ANSWER"
  if [[ -z "$decision" ]]; then
    if [[ -t 0 ]]; then
      while [[ -z "$decision" ]]; do
        printf "  Overwrite them with the engine's copies, or keep them? ${BRIGHT_WHITE}[overwrite/keep]${RESET} "
        read -r answer || { decision="keep"; break; }
        case "$answer" in
          o|O|overwrite|Overwrite) decision="force" ;;
          k|K|keep|Keep)           decision="keep" ;;
        esac
      done
    else
      decision="keep"
      printf "  ${DIM}Nothing was asked \u2014 there is no terminal on stdin, and keeping is the answer that loses nothing.${RESET}\n"
      printf "  ${DIM}Answer in advance with ${RESET}${BRIGHT_WHITE}--force${RESET}${DIM} to overwrite, or ${RESET}${BRIGHT_WHITE}--keep-edits${RESET}${DIM} to keep.${RESET}\n"
    fi
  fi

  for (( i = 0; i < n; i++ )); do
    if [[ "$decision" == "force" ]]; then
      write_item "${EDITED_SRCS[$i]}" "${EDITED_DSTS[$i]}" "${EDITED_LABELS[$i]}"
    else
      manifest_line "${EDITED_LABELS[$i]}" "${MANIFEST_HAVE[${EDITED_LABELS[$i]}]}"
    fi
  done

  if [[ "$decision" == "force" ]]; then
    printf "  ${BRIGHT_WHITE}%d file(s) overwritten with the engine's copy.${RESET}\n" "$n"
  else
    printf "  ${BRIGHT_WHITE}%d file(s) kept as this project has them.${RESET}\n" "$n"
  fi
}

install_dir() {
  local src="$1"
  local dst="$2"
  local rel="$3"

  if [[ ! -d "$dst" ]]; then
    mkdir -p "$dst"
    printf "  ${CYAN}+${RESET}  %s\n" "$rel"
  fi

  local item name
  for item in "$src"/* "$src"/.[!.]*; do
    [[ -e "$item" ]] || continue
    name="${item##*/}"
    # OS clutter never leaves the engine repo.
    case "$name" in
      .DS_Store) continue ;;
    esac
    if [[ -d "$item" ]]; then
      install_dir "$item" "$dst/$name" "${rel}${name}/"
    else
      install_item "$item" "$dst/$name" "${rel}${name}"
    fi
  done
}

# ── Where each engine path lands ──────────────────────────────────
# Everything the engine ships lives under .sdd/. Most of it keeps that path in
# the project; a few directories are read by the host from somewhere else, and
# where that is depends on the host the project chose at install time. A project
# has exactly one host: claude fills .claude/, copilot fills .github/, and
# neither writes a single file into the other's directory.
#
# adapter_dest answers for one host and one engine directory, and sets:
#   MAP_DEST   where that directory lands in the project
#   MAP_SHAPE  what happens to the names inside it —
#                plain   the tree is copied name for name
#                suffix  a file trades its .md for MAP_ARG
#                        (architect.md → architect.agent.md)
#                wrap    a file becomes a directory holding one file, MAP_ARG
#                        (sdd-specify.md → sdd-specify/SKILL.md)
#   MAP_ARG    what the shape needs
#   MAP_KEEP   1 when the engine directory is installed at .sdd/<name>/ as well.
#              True of rules alone: .sdd/rules/X.md is the path a prompt names,
#              one path valid on every host, while the host's copy is what makes
#              the file always-on in the main session.
# A directory the map does not claim installs itself at .sdd/<name>/, which is
# what the walk in install_files does with everything else.
adapter_dest() {
  local host="$1" name="$2"
  MAP_DEST=""; MAP_SHAPE="plain"; MAP_ARG=""; MAP_KEEP=0
  case "$host:$name" in
    claude:agents)    MAP_DEST=".claude/agents" ;;
    claude:commands)  MAP_DEST=".claude/commands" ;;
    claude:skills)    MAP_DEST=".claude/skills" ;;
    claude:rules)     MAP_DEST=".claude/rules"; MAP_KEEP=1 ;;
    claude:_claude)   MAP_DEST=".claude" ;;
    copilot:agents)   MAP_DEST=".github/agents";       MAP_SHAPE="suffix"; MAP_ARG=".agent.md" ;;
    copilot:commands) MAP_DEST=".github/skills";       MAP_SHAPE="wrap";   MAP_ARG="SKILL.md" ;;
    copilot:skills)   MAP_DEST=".github/skills" ;;
    copilot:rules)    MAP_DEST=".github/instructions"; MAP_SHAPE="suffix"; MAP_ARG=".instructions.md"; MAP_KEEP=1 ;;
    *) return 1 ;;
  esac
  return 0
}

# Handled outside the .sdd/ walk: every directory either host's map claims —
# including one this host does not install at all, which must not fall back to
# .sdd/ — and the three files that are merged into the project rather than
# copied. rules is the exception, and the map says so with MAP_KEEP: the walk
# installs it at .sdd/rules/ and the map adds the host's copy on top of that.
#
# log/ and sdd.conf are skipped for a different reason: the engine ships
# neither, but both appear inside a clone the moment someone runs the engine's
# own scripts or commands there. Copied into a project they would carry that
# clone's log and that clone's build commands into every install.
#
# .venv is the same kind of leftover and is named here as a guard. The
# repository keeps its virtualenv at the root, beside token-counter.sh, where
# this walk never looks — but one `python3 -m venv .sdd/.venv` run from the
# wrong directory would otherwise put an interpreter and its site-packages into
# every project the installer touches, and that went unnoticed once already.
sdd_walk_skips() {
  local name="$1" host
  case "$name" in
    AGENTS.md|_gitignore.claude|_gitignore.copilot) return 0 ;;
    log|sdd.conf|.venv) return 0 ;;
  esac
  for host in claude copilot; do
    if adapter_dest "$host" "$name"; then
      (( MAP_KEEP )) || return 0
    fi
  done
  return 1
}

# The name one source file takes at the destination.
shaped_name() {
  local name="$1" shape="$2" arg="$3"
  case "$shape" in
    suffix) printf '%s' "${name%.md}$arg" ;;
    wrap)   printf '%s' "${name%.md}/$arg" ;;
    *)      printf '%s' "$name" ;;
  esac
}

# One mapped engine directory, at the path its host reads it from. Only the
# names at the top level are shaped — a directory inside one is a tree the
# engine ships whole, and goes in name for name.
install_mapped() {
  local src="$1" dst="$2" rel="$3" shape="$4" arg="$5"
  local item name out

  if [[ ! -d "$dst" ]]; then
    mkdir -p "$dst"
    printf "  ${CYAN}+${RESET}  %s\n" "$rel"
  fi

  for item in "$src"/* "$src"/.[!.]*; do
    [[ -e "$item" ]] || continue
    name="${item##*/}"
    case "$name" in
      .DS_Store) continue ;;
    esac
    if [[ -d "$item" ]]; then
      install_dir "$item" "$dst/$name" "${rel}${name}/"
      continue
    fi
    out="$(shaped_name "$name" "$shape" "$arg")"
    if [[ "$out" == */* && ! -d "$dst/${out%/*}" ]]; then
      mkdir -p "$dst/${out%/*}"
      printf "  ${CYAN}+${RESET}  %s\n" "${rel}${out%/*}/"
    fi
    install_item "$item" "$dst/$out" "${rel}${out}"
  done
}

# Skills the human installed into this clone with `npx skills add`, each in
# the directory of the one host it is for: .claude/skills/ goes to Claude Code
# projects alone, .agents/skills/ to Copilot projects alone. They land beside
# the engine's own skills and are handled like them from then on — recorded in
# the manifest, refreshed by --sync, pruned once they leave the clone, removed
# by --uninstall.
installed_skills_dir() {
  case "$1" in
    claude)  printf '%s' "$SRC_DIR/.claude/skills" ;;
    copilot) printf '%s' "$SRC_DIR/.agents/skills" ;;
  esac
}

# `npx skills add` links a skill directory to one canonical copy unless told
# to copy, so a skill here may be a link. It is resolved before the walk: the
# project gets the files, never a link into this clone.
#
# A name the engine already ships is the engine's — a skill under .sdd/skills/
# and, for copilot, a command packaged as .github/skills/<name>/. The installed
# one is skipped and named, rather than let the two overwrite each other.
install_installed_skills() {
  local target="$1" host="$2" src item name real
  src="$(installed_skills_dir "$host")"
  [[ -d "$src" ]] || return 0
  adapter_dest "$host" skills || return 0

  for item in "$src"/*; do
    [[ -d "$item" && -f "$item/SKILL.md" ]] || continue
    name="${item##*/}"
    if [[ -d "$SRC_DIR/.sdd/skills/$name" ]] \
       || { [[ "$host" == "copilot" ]] && [[ -f "$SRC_DIR/.sdd/commands/$name.md" ]]; }; then
      printf "  ${YELLOW}\u26a0${RESET}  %s ${DIM}(skipped \u2014 the engine ships a skill of that name)${RESET}\n" "${src#"$SRC_DIR"/}/$name/"
      continue
    fi
    real="$(cd "$item" && pwd -P)" || continue
    sums_prime_tree "$real"
    modes_prime_tree "$real"
    install_dir "$real" "$target/$MAP_DEST/$name" "$MAP_DEST/$name/"
  done
}

# A project path back to the engine path it came from. prune_empty_dirs needs
# it: .claude/agents/ in a project is .sdd/agents/ here, and a folder the engine
# still has must not be removed as empty. .claude/ itself answers .sdd/, which
# is there as long as the engine is.
#
# It reverses the claude side and nothing else, on purpose. The copilot side is
# not reversible — .github/skills/ receives from two engine directories, and
# .github/skills/sdd-specify/ comes from a file while the guard tests -d — and
# it never has to be: nothing under .github/ is ever pruned, because that
# directory is shared with the project. Do not teach this the .github/ side. The
# answer would be a guess, and no caller exists that could act on it.
src_for_rel() {
  local rel="${1%/}" head item name
  case "$rel" in
    .claude)   printf '%s' ".sdd"; return 0 ;;
    .claude/*) ;;
    *)         printf '%s' "$rel"; return 0 ;;
  esac

  head="${rel#.claude/}"
  head=".claude/${head%%/*}"
  for item in "$SRC_DIR"/.sdd/*; do
    [[ -d "$item" ]] || continue
    name="${item##*/}"
    adapter_dest claude "$name" || continue
    if [[ "$MAP_DEST" == "$head" ]]; then
      printf '%s' ".sdd/${name}${rel#"$head"}"
      return 0
    fi
  done
  printf '%s' "$rel"
}

# ── Merged files (not copied) ─────────────────────────────────────
# Two files in the project are merged rather than copied whole, because the
# project writes on them too: the host's instruction file, which carries the
# engine core, and .gitignore, which carries the block that keeps the engine out
# of the project's history. The engine's text goes between markers and
# everything outside them stays the project's own, re-install after re-install.
#
# The markers travel as arguments rather than sitting in these functions,
# because a .gitignore has no <!-- --> to hide a marker in.
SDD_BEGIN='<!-- SDD:BEGIN -->'
SDD_END='<!-- SDD:END -->'
GITIGNORE_BEGIN='# SDD:BEGIN'
GITIGNORE_END='# SDD:END'

# Yes/no prompt. Just Enter means yes; only n/N declines.
confirm() {
  local prompt="$1" answer
  printf "  %s ${BRIGHT_WHITE}[Y/n]${RESET} " "$prompt"
  read -r answer || return 1
  case "$answer" in
    n|N) return 1 ;;
    *)   return 0 ;;
  esac
}

has_block() {
  local file="$1" begin="$2" end="$3"
  grep -qxF "$begin" "$file" && grep -qxF "$end" "$file"
}

# What the block currently holds, markers excluded.
extract_block() {
  awk -v b="$2" -v e="$3" '
    $0 == e { inside = 0 }
    inside  { print }
    $0 == b { inside = 1 }
  ' "$1"
}

# Put the engine text in the block: replace it if the markers are there,
# append the block otherwise. Text outside the markers is copied verbatim.
write_block() {
  local src="$1" dst="$2" begin="$3" end="$4"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/sdd-merge.XXXXXX")"

  if [[ -f "$dst" ]] && has_block "$dst" "$begin" "$end"; then
    awk -v b="$begin" -v e="$end" -v src="$src" '
      $0 == b { print; while ((getline line < src) > 0) print line; close(src); inside = 1; next }
      $0 == e { print; inside = 0; next }
      !inside { print }
    ' "$dst" > "$tmp"
  else
    if [[ -s "$dst" ]]; then
      cat "$dst" > "$tmp"
      printf '\n' >> "$tmp"
    else
      : > "$tmp"
    fi
    {
      printf '%s\n' "$begin"
      awk '{ print }' "$src"
      printf '%s\n' "$end"
    } >> "$tmp"
  fi

  cat "$tmp" > "$dst"   # keep the project file's own permissions
  rm -f "$tmp"
}

# mode: ask            — ask before touching a file the project already owns
#       yes            — append without asking (--target, no terminal to ask at)
#       existing-only  — refresh a block that is there, never add a new one
#                        (--sync: a missing block is a decision already made)
merge_md() {
  local src="$1" dst="$2" label="$3" mode="${4:-ask}" begin="$5" end="$6"

  if [[ ! -f "$src" ]]; then
    printf "  ${YELLOW}⚠${RESET}  %s not found in source — skipped\n" "$label"
    return 1
  fi

  # A link into this engine: the file is ours and the block replaces it. A link
  # to anywhere else is the project's own arrangement — a .gitignore kept in a
  # dotfiles repo, say — and is written through, not removed.
  if [[ -L "$dst" ]]; then
    case "$(readlink "$dst")" in
      "$SRC_DIR"/*)
        rm "$dst"
        write_block "$src" "$dst" "$begin" "$end"
        printf "  ${GREEN}✓${RESET}  %s ${DIM}(link replaced by SDD block)${RESET}\n" "$label"
        return 0
        ;;
    esac
  fi

  if [[ ! -e "$dst" ]]; then
    write_block "$src" "$dst" "$begin" "$end"
    printf "  ${GREEN}✓${RESET}  %s\n" "$label"
    return 0
  fi

  if has_block "$dst" "$begin" "$end"; then
    if diff -q <(extract_block "$dst" "$begin" "$end") <(awk '{ print }' "$src") >/dev/null; then
      printf "  ${DIM}–${RESET}  %s ${DIM}(SDD block up to date)${RESET}\n" "$label"
    else
      write_block "$src" "$dst" "$begin" "$end"
      printf "  ${GREEN}✓${RESET}  %s ${DIM}(SDD block updated)${RESET}\n" "$label"
    fi
    return 0
  fi

  if [[ "$mode" == "existing-only" ]]; then
    printf "  ${DIM}–${RESET}  %s ${DIM}(no SDD block — left alone)${RESET}\n" "$label"
    return 0
  fi

  # The project's own file. Its content survives either way, but appending
  # to a file the engine does not own is the human's call.
  printf "\n  ${YELLOW}%s already exists in this project.${RESET}\n" "$label"
  printf "  ${DIM}The SDD block would be appended; the existing content is kept.${RESET}\n"
  local approved=0
  if [[ "$mode" == "yes" ]]; then
    approved=1
  elif confirm "Add the SDD block to $label?"; then
    approved=1
  fi

  if (( approved )); then
    write_block "$src" "$dst" "$begin" "$end"
    printf "  ${GREEN}✓${RESET}  %s ${DIM}(SDD block appended)${RESET}\n" "$label"
    return 0
  fi
  printf "  ${YELLOW}⚠${RESET}  %s ${DIM}(left untouched)${RESET}\n" "$label"
  return 1
}

# Drop the block and its markers. A file that was nothing but the block is
# the engine's own and goes with it; anything else keeps its content.
remove_block() {
  local file="$1" label="$2" begin="$3" end="$4" dest tmp
  [[ -e "$file" ]] || return 0

  if [[ -L "$file" ]]; then
    dest="$(readlink "$file")"
    case "$dest" in
      "$SRC_DIR"/*) rm "$file"; printf "  ${RED}−${RESET}  %s ${DIM}(link removed)${RESET}\n" "$label" ;;
    esac
    return 0
  fi

  if ! has_block "$file" "$begin" "$end"; then
    printf "  ${DIM}–${RESET}  %s ${DIM}(no SDD block)${RESET}\n" "$label"
    return 0
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/sdd-merge.XXXXXX")"
  awk -v b="$begin" -v e="$end" '
    $0 == b { inside = 1; next }
    $0 == e { inside = 0; next }
    !inside { print }
  ' "$file" > "$tmp"

  if [[ -z "$(tr -d '[:space:]' < "$tmp")" ]]; then
    rm -f "$file" "$tmp"
    printf "  ${RED}−${RESET}  %s ${DIM}(held nothing but the engine)${RESET}\n" "$label"
  else
    cat "$tmp" > "$file"
    rm -f "$tmp"
    printf "  ${GREEN}✓${RESET}  %s ${DIM}(SDD block removed)${RESET}\n" "$label"
  fi
}

# ── Registry ──────────────────────────────────────────────────────
# Which projects this engine is installed into: one line each, the absolute
# path, a tab, and the host it was installed for. Local to this machine —
# .gitignore keeps it out of the engine's history. SDD_REGISTRY moves the file,
# which is what the installer's own tests need and nothing else uses.
#
# A line without a tab is a corrupt file, not an older format: there has never
# been a one-column registry anywhere, so reading one as `claude` would be a
# guess dressed up as compatibility. Every access goes through the helpers
# below, because a whole-line grep is exactly what stopped matching the day the
# host joined the line, and it stopped matching silently.
REGISTRY="${SDD_REGISTRY:-$SRC_DIR/installed-repos.txt}"

registry_corrupt() {
  printf "\n  ${RED}%s is corrupt.${RESET} Line %d is not <path><TAB>claude|copilot:\n" "$REGISTRY" "$1" >&2
  printf "    %s\n\n" "$2" >&2
  exit 2
}

# One line into REG_PATH and REG_HOST, or 1 if it does not fit the format.
registry_split() {
  local line="$1"
  [[ "$line" == *$'\t'* ]] || return 1
  REG_PATH="${line%%$'\t'*}"
  REG_HOST="${line#*$'\t'}"
  [[ -n "$REG_PATH" ]] || return 1
  case "$REG_HOST" in
    claude|copilot) return 0 ;;
    *)              return 1 ;;
  esac
}

# The host a path is registered under, or 1 if it is not registered at all.
registry_host() {
  local target="$1" line n=0
  [[ -f "$REGISTRY" ]] || return 1
  while IFS= read -r line; do
    n=$(( n + 1 ))
    [[ -n "$line" ]] || continue
    registry_split "$line" || registry_corrupt "$n" "$line"
    if [[ "$REG_PATH" == "$target" ]]; then
      printf '%s' "$REG_HOST"
      return 0
    fi
  done < "$REGISTRY"
  return 1
}

# Records the path under this host, replacing the line it already has.
registry_add() {
  local target="$1" host="$2" line n=0 found=0 tmp
  [[ -f "$REGISTRY" ]] || : > "$REGISTRY"
  tmp="$(mktemp "${TMPDIR:-/tmp}/sdd-registry.XXXXXX")"
  while IFS= read -r line; do
    n=$(( n + 1 ))
    [[ -n "$line" ]] || continue
    registry_split "$line" || registry_corrupt "$n" "$line"
    if [[ "$REG_PATH" == "$target" ]]; then
      found=1
      printf '%s\t%s\n' "$target" "$host" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$REGISTRY"
  (( found )) || printf '%s\t%s\n' "$target" "$host" >> "$tmp"
  cat "$tmp" > "$REGISTRY"
  rm -f "$tmp"
}

registry_remove() {
  local target="$1" line n=0 tmp
  [[ -f "$REGISTRY" ]] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/sdd-registry.XXXXXX")"
  while IFS= read -r line; do
    n=$(( n + 1 ))
    [[ -n "$line" ]] || continue
    registry_split "$line" || registry_corrupt "$n" "$line"
    if [[ "$REG_PATH" != "$target" ]]; then
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$REGISTRY"
  cat "$tmp" > "$REGISTRY"
  rm -f "$tmp"
}

# Every registered project, in registry order, into two parallel arrays.
registry_load() {
  local -n _p=$1
  local -n _h=$2
  local line n=0
  _p=(); _h=()
  [[ -s "$REGISTRY" ]] || return 0
  while IFS= read -r line; do
    n=$(( n + 1 ))
    [[ -n "$line" ]] || continue
    registry_split "$line" || registry_corrupt "$n" "$line"
    _p+=("$REG_PATH")
    _h+=("$REG_HOST")
  done < "$REGISTRY"
}

# The registry as a menu. with_all adds the row that means every project at
# once, which only a sync can act on; allow_missing says whether a project whose
# folder is gone can still be chosen, which only an uninstall can do — the
# registry entry is exactly what it is there to remove.
#
# The choice comes back in CHOSEN_ALL, or in CHOSEN_PATH and CHOSEN_HOST.
CHOSEN_PATH=""
CHOSEN_HOST=""
CHOSEN_ALL=0

choose_project() {
  local title="$1" with_all="$2" allow_missing="$3"
  local paths=() hosts=() labels=() i total base=0

  CHOSEN_PATH=""; CHOSEN_HOST=""; CHOSEN_ALL=0
  registry_load paths hosts
  total=${#paths[@]}
  if (( total == 0 )); then
    printf "\n  ${YELLOW}No projects registered.${RESET} ${DIM}Install into one first.${RESET}\n\n"
    return 1
  fi

  MENU_DISABLED=()
  if (( with_all )); then
    labels+=("every registered project  ($total)")
    MENU_DISABLED+=(0)
    base=1
  fi
  for (( i = 0; i < total; i++ )); do
    if [[ -d "${paths[$i]}" ]]; then
      labels+=("$(printf '%s  (%s)' "${paths[$i]}" "${hosts[$i]}")")
      MENU_DISABLED+=(0)
    else
      labels+=("$(printf '%s  (%s) — folder is gone' "${paths[$i]}" "${hosts[$i]}")")
      if (( allow_missing )); then MENU_DISABLED+=(0); else MENU_DISABLED+=(1); fi
    fi
  done

  choose_menu "$title" labels || return 1

  if (( with_all )) && (( MENU_CHOICE == 0 )); then
    CHOSEN_ALL=1
    return 0
  fi
  i=$(( MENU_CHOICE - base ))
  CHOSEN_PATH="${paths[$i]}"
  CHOSEN_HOST="${hosts[$i]}"
}

# ── Install / sync / uninstall ────────────────────────────────────
# What fell short of a complete install: the counter, and one entry per
# shortfall carrying the whole text the human needs. The text is written where
# the shortfall is found, so nothing downstream has to work out which one
# happened, and the next partially-installable thing adds an entry here rather
# than a branch in do_install.
INSTALL_INCOMPLETE=0
INSTALL_SHORTFALLS=()

shortfall() {
  INSTALL_INCOMPLETE=$(( INSTALL_INCOMPLETE + 1 ))
  INSTALL_SHORTFALLS+=("$1")
}

# Writes every engine file into $target for one host, and merges the two files
# that are merged rather than copied.
install_files() {
  local target="$1" mode="$2" host="$3"
  local item name dest shape arg
  local host_label instr_label instr_dst gi_src gi_lines text

  INSTALL_INCOMPLETE=0
  INSTALL_SHORTFALLS=()
  MANIFEST_LINES=()
  MANIFEST_NOW=()
  EDITED_LABELS=()
  EDITED_SRCS=()
  EDITED_DSTS=()
  manifest_read "$target"

  if [[ ! -d "$SRC_DIR/.sdd" ]]; then
    printf "  ${YELLOW}⚠${RESET}  .sdd/ not found in source — nothing to install\n"
    printf -v text "  ${YELLOW}There is no .sdd/ directory in %s.${RESET} Nothing was installed.\n  ${DIM}That path is meant to be a clone of the SDD engine.${RESET}" "$SRC_DIR"
    shortfall "$text"
    return 1
  fi

  # The bulk passes, before anything asks for a single sum or mode: the engine
  # as it is now, and the project as the manifest last described it.
  sums_prime_tree "$SRC_DIR/.sdd"
  modes_prime_tree "$SRC_DIR/.sdd"
  sums_prime_manifest "$target"

  # The core: every path under .sdd/ that is not handled below.
  for item in "$SRC_DIR"/.sdd/* "$SRC_DIR"/.sdd/.[!.]*; do
    [[ -e "$item" ]] || continue
    name="${item##*/}"
    [[ "$name" == ".DS_Store" ]] && continue
    sdd_walk_skips "$name" && continue
    if [[ -d "$item" ]]; then
      install_dir "$item" "$target/.sdd/$name" ".sdd/$name/"
    else
      [[ -d "$target/.sdd" ]] || mkdir -p "$target/.sdd"
      install_item "$item" "$target/.sdd/$name" ".sdd/$name"
    fi
  done

  # The host's own directories, each at the path that host reads it from.
  for item in "$SRC_DIR"/.sdd/*; do
    [[ -d "$item" ]] || continue
    name="${item##*/}"
    adapter_dest "$host" "$name" || continue
    dest="$MAP_DEST"; shape="$MAP_SHAPE"; arg="$MAP_ARG"
    install_mapped "$item" "$target/$dest" "$dest/" "$shape" "$arg"
  done

  # The skills the human installed into this clone for this host.
  install_installed_skills "$target" "$host"

  # The engine core, into the one file this host reads. Never two: Copilot CLI
  # reads AGENTS.md and CLAUDE.md both, so a second copy would be the core in
  # context twice.
  case "$host" in
    claude)  host_label="Claude Code"; instr_label="CLAUDE.md" ;;
    copilot) host_label="Copilot";     instr_label=".github/copilot-instructions.md" ;;
  esac
  instr_dst="$target/$instr_label"
  [[ -d "${instr_dst%/*}" ]] || mkdir -p "${instr_dst%/*}"
  if ! merge_md "$SRC_DIR/.sdd/AGENTS.md" "$instr_dst" "$instr_label" "$mode" "$SDD_BEGIN" "$SDD_END"; then
    printf -v text "  ${YELLOW}%s carries no SDD block.${RESET} That block is the engine — the file is what %s reads, and without the block it sees none of the workflow.\n  ${DIM}Paste the text of .sdd/AGENTS.md between ${RESET}${BRIGHT_WHITE}%s${RESET}${DIM} and ${RESET}${BRIGHT_WHITE}%s${RESET}${DIM} there, or re-run the installer.${RESET}" \
      "$instr_label" "$host_label" "$SDD_BEGIN" "$SDD_END"
    shortfall "$text"
  fi

  # Every file above is a copy of an engine file, and the engine is its own
  # repository. Committed, the whole engine lands in the project's history, and
  # every sync from then on shows up there as a diff nobody in that project
  # wrote. Under .claude/ the engine got away with saying nothing, because a
  # project has no such directory otherwise; .github/ is the opposite — already
  # there, already tracked, and `git add .` takes the engine with it in silence.
  #
  # The block is load-bearing twice over: it is also the only thing keeping the
  # engine out of /sdd-code-review's set under .github/. review-set.sh excludes
  # _docs/, .sdd/ and .claude/ and deliberately not .github/, because both
  # halves of that set honour .gitignore — the untracked half reads it, and the
  # tracked half never sees a file that was never committed.
  #
  # Nothing inside .sdd/ is exempt, .sdd/sdd.conf included. It once was, because
  # it holds how this project is verified and that answer is the same for
  # everyone who checks the repository out. It also holds JIRA_TOKEN, and a
  # personal access token must never reach a commit — that outweighs the
  # convenience. The cost is real and worth stating: a teammate's clone meets
  # the gate's ASK: again and builds nothing until they answer it a second time.
  # Whoever would rather pay the other price keeps only JIRA_URL in
  # .sdd/sdd.conf and the token in ~/.config/sdd-kit/tokens.env, which
  # jira-fetch.sh reads either way.
  #
  # The first line stays `.sdd/*` rather than `.sdd/` so a future exemption can
  # be written as a negation at all: git will not re-include a file whose parent
  # directory is excluded.
  gi_src="$SRC_DIR/.sdd/_gitignore.$host"
  if ! merge_md "$gi_src" "$target/.gitignore" ".gitignore" "$mode" "$GITIGNORE_BEGIN" "$GITIGNORE_END"; then
    gi_lines="$(sed 's/^/    /' "$gi_src" 2>/dev/null || true)"
    printf -v text "  ${YELLOW}.gitignore carries no SDD block.${RESET} The engine's files are copies of this machine's clone: committed, they put the whole engine in the project's history, and under .github/ they enter /sdd-code-review's set as well.\n  ${DIM}Paste these lines into .gitignore, or re-run the installer:${RESET}\n%s" \
      "$gi_lines"
    shortfall "$text"
  fi

  # Last, and only once the walk is through: what to do about the files this
  # project edited, and then the record of what this run wrote.
  resolve_edits
  manifest_write "$target" "$host"
}

# What the engine has dropped since the last install, and the folders that
# leaves empty. It runs straight after install_files in the same process, and
# reads the two things that run left behind: MANIFEST_HAVE, the manifest as the
# project had it, and MANIFEST_NOW, every path this run kept. A path in the
# first and not the second is a path the engine no longer ships.
#
# A file the project edited is kept even so. The edit is somebody's work, and
# the engine dropping the file is not a reason to throw it away — so it stays,
# stays in the manifest, and is named in the output as kept.
prune_target() {
  local target="$1" host="$2"
  local dir link rel path kept=0

  if (( ${#MANIFEST_HAVE[@]} )); then
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      [[ -n "${MANIFEST_NOW[$rel]-}" ]] && continue
      path="$target/$rel"
      [[ -e "$path" ]] || continue
      if [[ "$(file_sum "$path")" != "${MANIFEST_HAVE[$rel]}" ]]; then
        manifest_line "$rel" "${MANIFEST_HAVE[$rel]}"
        kept=1
        printf "  ${YELLOW}\u2260${RESET}  %s ${DIM}(gone from the engine \u2014 kept, changed in this project)${RESET}\n" "$rel"
      else
        rm "$path"
        printf "  ${RED}\u2212${RESET}  %s ${DIM}(gone from the engine)${RESET}\n" "$rel"
      fi
    done < <(printf '%s\n' "${!MANIFEST_HAVE[@]}" | LC_ALL=C sort)
  fi

  # The manifest install_files wrote does not know about the two decisions
  # above, so it is written again once they are made.
  if (( kept )); then
    manifest_write "$target" "$host"
  fi

  for dir in "$target/.sdd" "$target/.claude" "$target/.github"; do
    [[ -d "$dir" ]] || continue

    # Here for installs from before the engine copied, and for nothing else. A
    # symlink into this engine whose target is gone is dead on both counts: the
    # engine does not ship the file, and no manifest ever named it. Every live
    # one the walk has already replaced with a copy.
    while IFS= read -r link; do
      [[ -n "$link" ]] || continue
      case "$(readlink "$link")" in
        "$SRC_DIR"/*)
          rm "$link"
          printf "  ${RED}\u2212${RESET}  %s ${DIM}(gone from the engine)${RESET}\n" "${link#"$target"/}"
          ;;
      esac
    done < <(find "$dir" -type l ! -exec test -e {} \; -print 2>/dev/null)

    # .sdd/ and .claude/ are the engine's own, top to bottom, so a directory
    # left empty there is its own leftover. .github/ is shared with the
    # project: the engine's files go and the directories stay, empty or not. An
    # empty .github/skills/ is one rmdir away; a .github/skills/ this installer
    # deleted because it happened to be empty is somebody else's directory
    # gone, with nothing in the output saying which run did it.
    case "$dir" in
      */.github) continue ;;
    esac

    prune_empty_dirs "$dir" "$target" 1
  done
}

# Directories left empty, deepest first. Repeated on purpose: emptying a
# child is what makes its parent empty, and one find pass only ever sees
# the tree it started with. engine_only=1 spares folders the engine still has.
prune_empty_dirs() {
  local dir="$1" target="$2" engine_only="$3"
  local changed=1 d rel

  while (( changed )); do
    changed=0
    [[ -d "$dir" ]] || break
    while IFS= read -r d; do
      rel="${d#"$target"/}"
      # A directory the engine still ships is not a leftover.
      if (( engine_only )) && [[ -d "$SRC_DIR/$(src_for_rel "$rel")" ]]; then
        continue
      fi
      if rmdir "$d" 2>/dev/null; then
        changed=1
        if (( engine_only )); then
          printf "  ${RED}−${RESET}  %s/ ${DIM}(gone from the engine)${RESET}\n" "$rel"
        fi
      fi
    done < <(find "$dir" -depth -type d -empty 2>/dev/null)
  done
}

# Everything the installer put in this project, plus the folders it leaves
# empty. The manifest is what says which files those were: a copy carries no
# mark of its own, and nothing else in the project can answer the question.
#
# A file whose checksum no longer matches was edited here, and it stays. It is
# named in the output, one line each, so what was left behind and why is on the
# screen rather than left to be discovered.
remove_installed() {
  local target="$1"
  local dir link rel path removed=0 kept=0

  # The one thing removed here that the manifest does not list. .sdd/log/ is
  # the engine's own output, written by its scripts, so it goes out with the
  # engine — and left standing it would keep .sdd/ non-empty after an uninstall
  # that reports itself complete. .sdd/sdd.conf is the human's, written by
  # hand, and stays exactly as _docs/ does.
  if [[ -d "$target/.sdd/log" ]]; then
    rm -rf "$target/.sdd/log"
    printf "  ${RED}\u2212${RESET}  .sdd/log/ ${DIM}(the engine's own log)${RESET}\n"
  fi

  manifest_read "$target"
  sums_prime_manifest "$target"
  MANIFEST_LINES=()
  MANIFEST_NOW=()
  if (( ${#MANIFEST_HAVE[@]} )); then
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      path="$target/$rel"
      [[ -e "$path" ]] || continue
      if [[ "$(file_sum "$path")" != "${MANIFEST_HAVE[$rel]}" ]]; then
        manifest_line "$rel" "${MANIFEST_HAVE[$rel]}"
        kept=$(( kept + 1 ))
        printf "  ${YELLOW}\u2260${RESET}  %s ${DIM}(kept \u2014 changed in this project)${RESET}\n" "$rel"
      else
        rm "$path"
        removed=$(( removed + 1 ))
      fi
    done < <(printf '%s\n' "${!MANIFEST_HAVE[@]}" | LC_ALL=C sort)
  fi

  # The manifest goes after every file it lists, and only once it describes
  # none of them. While a file it names is still on disk it is the one record
  # that would let a later run clean that file up — so it stays, and .sdd/
  # stays with it, which is the honest picture of what is left.
  if (( kept == 0 )); then
    rm -f "$target/$MANIFEST_NAME"
  else
    manifest_write "$target" "$MANIFEST_HOST"
    printf "  ${DIM}%s was left in place: it lists the file(s) above and nothing else.${RESET}\n" "$MANIFEST_NAME"
  fi

  for dir in "$target/.sdd" "$target/.claude" "$target/.github"; do
    [[ -d "$dir" ]] || continue

    # Here for installs from before the engine copied, and for nothing else.
    # Those have no manifest at all, and the symlink is the only thing that
    # says the file was the engine's. An install this engine wrote has no
    # symlink into $SRC_DIR left for this loop to find.
    while IFS= read -r link; do
      [[ -n "$link" ]] || continue
      case "$(readlink "$link")" in
        "$SRC_DIR"/*) rm "$link"; removed=$(( removed + 1 )) ;;
      esac
    done < <(find "$dir" -type l 2>/dev/null)

    # Shared with the project — see prune_target.
    case "$dir" in
      */.github) continue ;;
    esac

    prune_empty_dirs "$dir" "$target" 0
  done

  printf "  ${RED}\u2212${RESET}  %d installed file(s)\n" "$removed"
  if (( kept )); then
    printf "  ${YELLOW}%d file(s) left standing, changed in this project.${RESET}\n" "$kept"
  fi
}

# Which projects a --sync run walks, and how that was decided.
#
# Copies made this question worth asking. With symlinks a sync was a tidy-up;
# now it is the only thing that carries an engine edit into a project, and the
# everyday case while working on the engine is one project, not all of them.
# So a run with somebody to ask, asks — and a run without one keeps doing
# exactly what it did before, because that is what every existing script gets.
SYNC_CHOSEN=()

sync_choose() {
  local paths_name="$1" hosts_name="$2"
  local -n _paths="$paths_name"
  local -n _hosts="$hosts_name"
  local total=${#_paths[@]} i answer resolved=""

  SYNC_CHOSEN=()

  # A path names one project, and it has to be one the registry knows. Anything
  # else would be an install into a directory nobody registered, done silently.
  if [[ -n "$SYNC_PATH" ]]; then
    if [[ -d "$SYNC_PATH" ]]; then
      resolved="$(cd "$SYNC_PATH" && pwd)"
    else
      resolved="$SYNC_PATH"
    fi
    for (( i = 0; i < total; i++ )); do
      if [[ "${_paths[$i]}" == "$resolved" ]]; then
        SYNC_CHOSEN=("$i")
        return 0
      fi
    done
    printf "\n  ${RED}%s is not registered.${RESET} --sync only walks projects the installer recorded.\n" "$resolved" >&2
    printf "  ${DIM}The registry is %s. Install into the folder first, or pass one of the paths it lists.${RESET}\n\n" "$REGISTRY" >&2
    exit 2
  fi

  # Every project, said out loud in the three ways it can be meant.
  if (( SYNC_ALL )) || (( total == 1 )); then
    for (( i = 0; i < total; i++ )); do SYNC_CHOSEN+=("$i"); done
    return 0
  fi
  if [[ ! -t 0 ]]; then
    for (( i = 0; i < total; i++ )); do SYNC_CHOSEN+=("$i"); done
    printf "\n  ${DIM}Every registered project was selected \u2014 there is no terminal on stdin to ask which.${RESET}\n" >&2
    printf "  ${DIM}Say so outright with ${RESET}${BRIGHT_WHITE}--sync --all${RESET}${DIM}, or name one with ${RESET}${BRIGHT_WHITE}--sync <path>${RESET}${DIM}.${RESET}\n" >&2
    return 0
  fi

  while true; do
    printf "\n  ${CYAN}Which project should this sync bring up to date?${RESET}\n\n"
    printf "    ${BRIGHT_WHITE}0${RESET}  every registered project ${DIM}(%d)${RESET}\n" "$total"
    for (( i = 0; i < total; i++ )); do
      if [[ -d "${_paths[$i]}" ]]; then
        printf "    ${BRIGHT_WHITE}%d${RESET}  %s ${DIM}(%s)${RESET}\n" "$(( i + 1 ))" "${_paths[$i]}" "${_hosts[$i]}"
      else
        printf "    ${DIM}%d  %s (%s) — folder is gone, cannot be chosen${RESET}\n" "$(( i + 1 ))" "${_paths[$i]}" "${_hosts[$i]}"
      fi
    done
    printf "\n  Number: "
    read -r answer || answer=""

    if [[ "$answer" == "0" ]]; then
      for (( i = 0; i < total; i++ )); do SYNC_CHOSEN+=("$i"); done
      return 0
    fi
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= total )); then
      i=$(( answer - 1 ))
      if [[ -d "${_paths[$i]}" ]]; then
        SYNC_CHOSEN=("$i")
        return 0
      fi
      printf "\n  ${YELLOW}That folder is gone.${RESET} ${DIM}Forget it with: ./install.sh --uninstall %s${RESET}\n" "${_paths[$i]}"
      continue
    fi
    printf "\n  ${YELLOW}Answer with a number from the list.${RESET}\n"
  done
}

do_sync() {
  if [[ ! -s "$REGISTRY" ]]; then
    printf "\n  ${YELLOW}No projects registered.${RESET} ${DIM}Install into one first.${RESET}\n\n"
    return 0
  fi

  local paths=() hosts=() target host i synced=0
  registry_load paths hosts

  sync_choose paths hosts

  for i in "${SYNC_CHOSEN[@]}"; do
    target="${paths[$i]}"; host="${hosts[$i]}"
    printf "\n${CYAN}  %s${RESET} ${DIM}(%s)${RESET}\n\n" "$target" "$host"
    if [[ ! -d "$target" ]]; then
      printf "  ${YELLOW}\u26a0${RESET}  folder is gone \u2014 skipped\n"
      printf "  ${DIM}Forget it with: ./install.sh --uninstall %s${RESET}\n" "$target"
      continue
    fi
    LINK_REPORT_ALL=0
    install_files "$target" existing-only "$host"
    LINK_REPORT_ALL=1
    prune_target "$target" "$host"
    synced=$(( synced + 1 ))
  done

  printf "\n  ${BRIGHT_CYAN}${BOLD}Synced${RESET} %d project(s).\n\n" "$synced"
}

do_uninstall() {
  local target="$1" host="" instr=() file

  printf "\n${CYAN}  Removing SDD from %s...${RESET}\n\n" "$target"
  host="$(registry_host "$target")" || host=""

  if [[ -d "$target" ]]; then
    remove_installed "$target"

    # The recorded host says which file carries the core. Without a registry
    # entry there is nothing to go on, so both are offered — remove_block is a
    # no-op on a file that holds no block.
    case "$host" in
      claude)  instr=("CLAUDE.md") ;;
      copilot) instr=(".github/copilot-instructions.md") ;;
      *)       instr=("CLAUDE.md" ".github/copilot-instructions.md") ;;
    esac
    for file in "${instr[@]}"; do
      remove_block "$target/$file" "$file" "$SDD_BEGIN" "$SDD_END"
    done
    remove_block "$target/.gitignore" ".gitignore" "$GITIGNORE_BEGIN" "$GITIGNORE_END"
  else
    printf "  ${YELLOW}⚠${RESET}  folder is gone — only the registry entry is removed\n"
  fi
  registry_remove "$target"

  printf "\n  ${BRIGHT_CYAN}${BOLD}Done.${RESET} ${DIM}_docs/ is the project's own and was left as it is.${RESET}\n"
  if [[ "$host" != "claude" ]]; then
    printf "  ${DIM}So were the directories under .github/, empty ones included — that one is shared with the project.${RESET}\n"
  fi
  printf "\n"
}

# The heading and the list: one entry per thing that fell short, each carrying
# its own instructions.
report_shortfalls() {
  local text
  printf "\n  ${YELLOW}${BOLD}⚠  SDD is incomplete.${RESET} %d thing(s) need a hand:\n\n" "$INSTALL_INCOMPLETE"
  for text in "${INSTALL_SHORTFALLS[@]}"; do
    printf '%s\n\n' "$text"
  done
}

do_install() {
  local target="$1" mode="${2:-ask}" host="$3" recorded=""

  # Changing the host is an uninstall first. Installing over the top would
  # leave the previous host's files standing — .github/ after a move to
  # claude — and nothing would ever collect them.
  recorded="$(registry_host "$target")" || recorded=""
  if [[ -n "$recorded" && "$recorded" != "$host" ]]; then
    printf "\n  ${RED}%s is installed for %s.${RESET} Install it for %s in two steps:\n\n" \
      "$target" "$recorded" "$host" >&2
    printf "    ./install.sh --uninstall %s\n" "$target" >&2
    printf "    ./install.sh --target %s --for %s\n\n" "$target" "$host" >&2
    exit 2
  fi

  printf "\n${CYAN}  Installing SDD files for %s...${RESET}\n\n" "$host"

  # A failure here is nothing installed at all, so the project is not recorded:
  # --sync has no reason to walk it.
  if ! install_files "$target" "$mode" "$host"; then
    report_shortfalls
    exit 1
  fi

  registry_add "$target" "$host"

  printf "\n  ${BRIGHT_CYAN}${BOLD}Done.${RESET} SDD installed at ${BRIGHT_WHITE}%s${RESET} ${DIM}(%s)${RESET}\n" "$target" "$host"
  if (( INSTALL_INCOMPLETE )); then
    report_shortfalls
  else
    printf "  ${DIM}Next: run /sdd-init to initialize _docs/ from your codebase.${RESET}\n\n"
  fi
}

# ── Abort ─────────────────────────────────────────────────────────
abort() {
  printf "\n  ${RED}Aborted.${RESET}\n\n"
  exit 0
}

# The cursor is hidden during browsing — restore it on every exit path,
# not just Ctrl-C, or a failure leaves the terminal looking frozen.
trap 'tput cnorm 2>/dev/null || true' EXIT
trap abort INT

# ── Main ──────────────────────────────────────────────────────────
usage() {
  printf '%s\n' \
    "SDD installer" \
    "" \
    "  ./install.sh                                 pick install, sync or uninstall from a menu" \
    "  ./install.sh --target <path> --for <host>    install into <path>, no questions asked" \
    "  ./install.sh --sync                          ask which registered project to bring up to date" \
    "  ./install.sh --sync <path>                   bring that one project up to date" \
    "  ./install.sh --sync --all                    bring every registered project up to date" \
    "  ./install.sh --uninstall <path>              remove the engine from <path>" \
    "  ./install.sh --help" \
    "" \
    "  <host> is claude or copilot. claude writes .claude/ and CLAUDE.md; copilot writes" \
    "  .github/ and .github/copilot-instructions.md. A project has one host, chosen at" \
    "  install time; changing it is --uninstall followed by an install." \
    "" \
    "  --sync and --uninstall take the host from the registry, so --for is an error there." \
    "" \
    "  The menu does all three, with the folder browser for an install and the registry" \
    "  as a list for the other two. Esc steps back out of any list; from the menu itself" \
    "  it ends the run." \
    "" \
    "  An install and a --sync both ask what to do about files the project edited after" \
    "  they were installed. Answer in advance, which is what a script has to do:" \
    "" \
    "  --force                                      overwrite every edited file" \
    "  --keep-edits                                 keep every edited file" \
    "" \
    "  With neither and no terminal on stdin, the edits are kept and nothing is asked." \
    "" \
    "  A plain --sync with no terminal on stdin walks every registered project, as it" \
    "  always has. --sync --all is the same thing said outright, which is what a script" \
    "  should say." \
    "" \
    "Every install is recorded in $REGISTRY, which is what --sync walks."
}

abs_dir() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    printf "  No such folder: %s\n" "$path" >&2
    return 1
  fi
  (cd "$path" && pwd)
}

# MODE is the invocation, HOST is which host's files are written. install_files
# has a third axis of its own — the merge behaviour, ask/yes/existing-only —
# and none of the three is the other.
MODE="interactive"
ARG_PATH=""
HOST=""
EDIT_FORCE=0
EDIT_KEEP=0
SYNC_PATH=""
SYNC_ALL=0

while (( $# > 0 )); do
  case "$1" in
    --sync)
      MODE="sync"
      # The path is optional, so it is taken only when it could not be
      # anything else: --sync --all and --sync --force have to keep working.
      if (( $# >= 2 )) && [[ "$2" != -* ]]; then
        SYNC_PATH="$2"; shift
      fi
      ;;
    --all)
      SYNC_ALL=1
      ;;
    --target)
      (( $# >= 2 )) || { printf "  --target needs a path\n\n" >&2; usage >&2; exit 2; }
      MODE="target"; ARG_PATH="$2"; shift
      ;;
    --uninstall)
      (( $# >= 2 )) || { printf "  --uninstall needs a path\n\n" >&2; usage >&2; exit 2; }
      MODE="uninstall"; ARG_PATH="$2"; shift
      ;;
    --for)
      (( $# >= 2 )) || { printf "  --for needs a host: claude or copilot\n\n" >&2; usage >&2; exit 2; }
      case "$2" in
        claude|copilot) HOST="$2" ;;
        *) printf "  Unknown host: %s — --for takes claude or copilot\n\n" "$2" >&2; usage >&2; exit 2 ;;
      esac
      shift
      ;;
    --force)
      EDIT_FORCE=1
      ;;
    --keep-edits)
      EDIT_KEEP=1
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      printf "  Unknown option: %s\n\n" "$1" >&2; usage >&2; exit 2
      ;;
  esac
  shift
done

# --for never gets to mean nothing. It is mandatory where the host is a choice,
# and refused where the registry already holds the answer — accepting it there
# would let the installer do something other than what it was asked.
case "$MODE" in
  target)
    if [[ -z "$HOST" ]]; then
      printf "  --target needs --for claude|copilot — a project's files are written for one host.\n\n" >&2
      usage >&2
      exit 2
    fi
    ;;
  sync|uninstall)
    if [[ -n "$HOST" ]]; then
      printf "  --for does not apply to --%s — the host comes from the registry there.\n\n" "$MODE" >&2
      usage >&2
      exit 2
    fi
    ;;
esac

# The two answers to the question in resolve_edits, given in advance. Together
# they say to overwrite and to keep the same file, so they are a usage error the
# way --sync with --for is. --uninstall asks nothing of the kind: it has its own
# rule, and leaves an edited file standing whatever these say.
# --all belongs to --sync alone, and says the same thing a path says, in the
# opposite direction. Together they are a contradiction, not a preference.
if (( SYNC_ALL )) && [[ "$MODE" != "sync" ]]; then
  printf "  --all only applies to --sync.\n\n" >&2
  usage >&2
  exit 2
fi
if (( SYNC_ALL )) && [[ -n "$SYNC_PATH" ]]; then
  printf "  --sync --all walks every project and --sync <path> walks one — pass one or the other.\n\n" >&2
  usage >&2
  exit 2
fi

if (( EDIT_FORCE && EDIT_KEEP )); then
  printf "  --force and --keep-edits are the two answers to one question — pass one or the other.\n\n" >&2
  usage >&2
  exit 2
fi
if [[ "$MODE" == "uninstall" ]] && (( EDIT_FORCE || EDIT_KEEP )); then
  printf "  --force and --keep-edits do not apply to --uninstall — an edited file is always left standing there.\n\n" >&2
  usage >&2
  exit 2
fi
if (( EDIT_FORCE )); then
  EDIT_ANSWER="force"
elif (( EDIT_KEEP )); then
  EDIT_ANSWER="keep"
fi

# ── The interactive run ───────────────────────────────────────────
# The three things the flags do, done by picking instead of typing. Each one
# returns 1 when it was left without a choice, and the menu comes back up:
# nothing here is worth losing a run over.
interactive_install() {
  local target=""

  printf "  ${CYAN}Select the project folder to install SDD into:${RESET}\n\n"

  SELECTED_DIR=""
  browse_folder
  target="$SELECTED_DIR"

  printf "\n  ${BRIGHT_WHITE}${BOLD}Selected:${RESET} ${CYAN}%s${RESET}\n\n" "$target"
  confirm "Install SDD into this folder?" || abort

  # --for can name the host on an otherwise interactive run; asked or given,
  # the answer is the same one.
  if [[ -z "$HOST" ]]; then
    printf "\n"
    SELECTED_HOST=""
    choose_host || return 1
    HOST="$SELECTED_HOST"
  fi
  printf "\n  ${BRIGHT_WHITE}${BOLD}Host:${RESET} ${CYAN}%s${RESET}\n" "$HOST"

  do_install "$target" ask "$HOST"
}

interactive_sync() {
  choose_project "Which project should this sync bring up to date?" 1 0 || return 1

  # sync_choose asks its own question when neither of these is set, and both
  # of them say what was picked here, so it asks nothing.
  if (( CHOSEN_ALL )); then
    SYNC_ALL=1
  else
    SYNC_PATH="$CHOSEN_PATH"
  fi
  do_sync
}

interactive_uninstall() {
  choose_project "Which project should the engine be removed from?" 0 1 || return 1

  printf "\n  ${BRIGHT_WHITE}${BOLD}Selected:${RESET} ${CYAN}%s${RESET} ${DIM}(%s)${RESET}\n\n" \
    "$CHOSEN_PATH" "$CHOSEN_HOST"
  printf "  ${DIM}Every file the installer wrote and still owns is removed. Files this project\n"
  printf "  edited are left standing, and so is _docs/.${RESET}\n\n"
  confirm "Remove SDD from this folder?" || abort

  do_uninstall "$CHOSEN_PATH"
}

ACTION_LABELS=(
  "Install    — put the engine into a project folder"
  "Sync       — bring an installed project up to date"
  "Uninstall  — remove the engine from a project"
)

case "$MODE" in
  interactive)
    print_banner

    while true; do
      # Sync and uninstall walk the registry, so with nothing in it there is
      # nothing for them to do — the rows say so rather than going missing.
      MENU_DISABLED=(0 0 0)
      if [[ ! -s "$REGISTRY" ]]; then
        ACTION_LABELS[1]="Sync       — no projects registered yet"
        ACTION_LABELS[2]="Uninstall  — no projects registered yet"
        MENU_DISABLED=(0 1 1)
      fi

      choose_menu "What should the installer do?" ACTION_LABELS || abort

      case "$MENU_CHOICE" in
        0) interactive_install && break ;;
        1) interactive_sync && break ;;
        2) interactive_uninstall && break ;;
      esac
    done
    ;;

  target)
    TARGET="$(abs_dir "$ARG_PATH")" || exit 2
    do_install "$TARGET" yes "$HOST"
    ;;

  sync)
    do_sync
    ;;

  uninstall)
    if [[ -d "$ARG_PATH" ]]; then
      TARGET="$(cd "$ARG_PATH" && pwd)"
    else
      TARGET="$ARG_PATH"   # already gone: the registry entry still has to go
    fi
    do_uninstall "$TARGET"
    ;;
esac
