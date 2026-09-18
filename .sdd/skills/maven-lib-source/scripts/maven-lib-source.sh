#!/usr/bin/env bash
#
# maven-lib-source — find a class in the local Maven repository and read it,
# degrading gracefully when the sources jar is not there.
#
#   maven-lib-source.sh <groupId> <artifactId> <version> <className> [options]
#   maven-lib-source.sh <groupId> <artifactId> <className> --from-project <dir>
#   maven-lib-source.sh find <className> [<className> ...] [--group-prefix <p>]
#   maven-lib-source.sh index [<group-prefix> ...] [--all] [--refresh]
#
# A search reads the class it found: when a name matches exactly one class, the
# search prints what a read of that class would have printed, so finding and
# reading are one call rather than two. Several names are answered in one scan.
#
# Options:
#   --method <name>          print that method, every overload of it; repeatable
#   --members <pattern>      keep only the declarations matching it in the index
#   --list                   a search lists its hits and reads nothing
#   --print                  print the whole class instead of the path to it
#   --out <dir>              also place the file there, and report that path
#   --spill <mode>           auto keeps a long answer in a file and prints its
#                            head; never prints it whole; always always files it
#   --from-project <dir>     take the version from that project's own build
#   --module <path>          the module inside it whose classpath to ask for
#   --group-prefix <p>       narrow a search to one group
#   --all                    let a search or an index cover the whole repository
#   --refresh                rebuild the index rather than extend it
#   --offline                never reach the network; use only what is on disk
#   --no-cache               rebuild what was already extracted or decompiled
#   --json                   print the result as one JSON object
#   --help
#
# Exit codes: 0 ok | 2 usage | 3 artifact not in the repository | 4 class not
#             found | 5 the name is ambiguous | 6 method not found | 7 nothing
#             left to try without the network | 8 a required tool is missing
#
# Two places hold what this produces, and the split is by what it costs to make
# again. A sources jar unpacks in about a second from a file already on disk, so
# its tree goes to a deterministic directory under the system temporary
# directory and is left for the system to reap. A decompilation costs a JVM
# start and depends on the version of the decompiler, so it is kept.
#
# Whole jars are unpacked, not single files: one unzip costs the same and leaves
# the whole library open to grep, which is what a question about a class usually
# turns into.

set -u

VF_VERSION="1.10.1"
VF_GAV="org.vineflower:vineflower:${VF_VERSION}"
VF_ORIGIN="decompiled(vineflower ${VF_VERSION})"

CACHE_ROOT="${HOME}/.cache/maven-lib-source"
INDEX_ROOT="${CACHE_ROOT}/index"
PROJECT_ROOT="${CACHE_ROOT}/projects"
DECL_ROOT="${CACHE_ROOT}/declarations"
TOOL_ROOT="${CACHE_ROOT}/tools"
ANSWERS_ROOT="${CACHE_ROOT}/answers"
TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT="${TMP_ROOT%/}"
SRC_ROOT="${TMP_ROOT}/maven-lib-source"

SCAN_JOBS=8

err() { printf '%s\n' "$*" >&2; }

# Progress is for a person watching a slow run. Where the output is being
# captured it is noise, and to a caller that reads before the work is done it is
# worse than noise: it is the whole answer that caller gets. So it is said to a
# terminal and nowhere else.
note() { [[ -t 2 ]] && printf '%s\n' "$*" >&2; return 0; }

usage() {
  cat <<'EOF'
maven-lib-source — read a library class instead of guessing what it does.

Read a class:
  maven-lib-source.sh <groupId> <artifactId> <version> <className> [options]
  maven-lib-source.sh <groupId> <artifactId> <className> --from-project <dir> [--module <path>]

Find which artifact holds a class, and read it:
  maven-lib-source.sh find <className> [<className> ...] [--group-prefix <p> | --from-project <dir> | --all]

A name that matches exactly one class is read rather than listed: the answer is
the class itself, whose header names the artifact it came from. Versions of one
artifact are collapsed into the newest, so twenty of them are still one hit.
Several names cost one scan, so ask for all of them at once. --list stops at
the list.

Build the search index:
  maven-lib-source.sh index <group-prefix> [<group-prefix> ...] [--refresh]
  maven-lib-source.sh index --all [--refresh]

Options:
  --method <name>        print that method; all overloads are returned.
                         Repeat it for several methods of the same class.
  --members <pattern>    keep only the declarations matching this extended
                         regular expression, case insensitively, in the index
  --list                 a search lists its hits and reads none of them
  --print                print the whole class instead of the path to it
  --out <dir>            also place the file there, and report that path
  --spill <mode>         auto (default) writes an answer longer than 120 lines
                         to a file and prints its head; never prints it whole;
                         always writes every answer. MAVEN_LIB_SOURCE_SPILL_LINES
                         moves the threshold
  --from-project <dir>   resolve the version from that project's own build
  --module <path>        the module inside it, as Maven's -pl takes it
  --group-prefix <p>     narrow a search to one group, e.g. org.apache.commons
  --all                  let a search or an index cover the whole repository
  --refresh              rebuild rather than extend
  --offline              stay on disk; never call Maven
  --no-cache             rebuild rather than reuse what was extracted before
  --json                 print one JSON object instead of text
  --help

Without --method the class is not printed. What comes back is the path to it,
the line count, and an index of its declarations with line numbers, so the
caller reads the part it needs.

Exit codes: 0 ok | 2 usage | 3 artifact missing | 4 class not found
            5 ambiguous name | 6 method missing | 7 offline dead end
            8 missing tool
EOF
}

usage_err() {
  err "maven-lib-source: $*"
  err ""
  usage >&2
  exit 2
}

# --- arguments --------------------------------------------------------------

ARGV_ALL=("$@")

MODE="read"
case "${1:-}" in
  find)  MODE="find";  shift ;;
  index) MODE="index"; shift ;;
esac

METHOD=""; OFFLINE=0; NOCACHE=0; JSON=0; PRINT=0; OUTDIR=""; MEMBERS=""
SPILL="auto"; SPILL_LINES="${MAVEN_LIB_SOURCE_SPILL_LINES:-120}"; SPILL_HEAD=14
FROM_PROJECT=""; MODULE=""; GROUP_PREFIX=""; ALL=0; REFRESH=0; LIST=0
TAB=$'\t'
METHODS=()
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --method) [[ $# -ge 2 ]] || usage_err "--method needs a name"; METHODS+=("$2"); shift 2 ;;
    --method=*) METHODS+=("${1#--method=}"); shift ;;
    --members) [[ $# -ge 2 ]] || usage_err "--members needs a pattern"; MEMBERS="$2"; shift 2 ;;
    --members=*) MEMBERS="${1#--members=}"; shift ;;
    --out) [[ $# -ge 2 ]] || usage_err "--out needs a directory"; OUTDIR="$2"; shift 2 ;;
    --out=*) OUTDIR="${1#--out=}"; shift ;;
    --spill) [[ $# -ge 2 ]] || usage_err "--spill needs auto, never or always"; SPILL="$2"; shift 2 ;;
    --spill=*) SPILL="${1#--spill=}"; shift ;;
    --from-project) [[ $# -ge 2 ]] || usage_err "--from-project needs a directory"; FROM_PROJECT="$2"; shift 2 ;;
    --from-project=*) FROM_PROJECT="${1#--from-project=}"; shift ;;
    --module) [[ $# -ge 2 ]] || usage_err "--module needs a path"; MODULE="$2"; shift 2 ;;
    --module=*) MODULE="${1#--module=}"; shift ;;
    --group-prefix) [[ $# -ge 2 ]] || usage_err "--group-prefix needs a group"; GROUP_PREFIX="$2"; shift 2 ;;
    --group-prefix=*) GROUP_PREFIX="${1#--group-prefix=}"; shift ;;
    --all) ALL=1; shift ;;
    --list) LIST=1; shift ;;
    --refresh) REFRESH=1; shift ;;
    --print) PRINT=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --no-cache) NOCACHE=1; shift ;;
    --json) JSON=1; shift ;;
    -*) usage_err "unknown option $1" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

N_POS=${#POSITIONAL[@]}

case "$SPILL" in auto|never|always) ;; *) usage_err "--spill takes auto, never or always, not ${SPILL}" ;; esac
[[ "$SPILL_LINES" =~ ^[0-9]+$ ]] || usage_err "MAVEN_LIB_SOURCE_SPILL_LINES takes a number, not ${SPILL_LINES}"

# The same name twice is one method, not two: asking for it twice would print
# the same cut twice and pay for it twice.
if [[ ${#METHODS[@]} -gt 1 ]]; then
  UNIQ=()
  for m in "${METHODS[@]}"; do
    seen=0
    for u in ${UNIQ[@]+"${UNIQ[@]}"}; do [[ "$u" == "$m" ]] && { seen=1; break; }; done
    [[ $seen -eq 1 ]] || UNIQ+=("$m")
  done
  METHODS=("${UNIQ[@]}")
fi

# One name stands for the whole list wherever a single method was assumed: the
# header and the JSON object carry them as they were given.
N_METHODS=${#METHODS[@]}
if [[ $N_METHODS -gt 0 ]]; then
  METHOD="${METHODS[0]}"
  for m in "${METHODS[@]:1}"; do METHOD="${METHOD}, ${m}"; done
fi

# An option that the mode cannot act on is said so rather than dropped: a caller
# who passed it is expecting something the answer will not carry.
[[ $LIST -eq 1 && $N_METHODS -gt 0 ]] && \
  err "maven-lib-source: --list reads nothing, so --method is ignored."
[[ "$MODE" == "find" && -n "$FROM_PROJECT" && -n "$GROUP_PREFIX" ]] && \
  err "maven-lib-source: --from-project already narrows the search, so --group-prefix is ignored."
[[ "$MODE" == "index" && ( $N_METHODS -gt 0 || -n "$MEMBERS" ) ]] && \
  err "maven-lib-source: index builds an index, so --method and --members are ignored."
[[ "$MODE" == "read" && $LIST -eq 1 ]] && \
  err "maven-lib-source: --list is a search option, so it is ignored here."
:

# A search reads what it found by calling this script again, so the path to it
# has to survive being invoked as `bash <path>` with no execute bit.
SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)" || SELF_DIR="."

# --- dependencies -----------------------------------------------------------

need() { command -v "$1" >/dev/null 2>&1; }
need unzip || { err "maven-lib-source: unzip is not on PATH"; exit 8; }

HAVE_JAVA=0; need java && HAVE_JAVA=1
HAVE_MVN=0;  need mvn  && HAVE_MVN=1

# --- local repository -------------------------------------------------------

resolve_m2() {
  local lr=""
  if [[ -n "${MAVEN_REPO_LOCAL:-}" ]]; then
    lr="$MAVEN_REPO_LOCAL"
  elif [[ -r "$HOME/.m2/settings.xml" ]]; then
    lr=$(tr -d '\n' < "$HOME/.m2/settings.xml" \
         | sed -n 's:.*<localRepository>[[:space:]]*\([^<]*\)[[:space:]]*</localRepository>.*:\1:p')
  fi
  lr="${lr//'${user.home}'/$HOME}"
  [[ -z "$lr" ]] && lr="$HOME/.m2/repository"
  printf '%s' "$lr"
}

M2="$(resolve_m2)"

# One scratch directory for the whole run. It is made eagerly: a lazy version
# behind a command substitution would run in a subshell and hand every caller a
# different directory.
SCRATCH="$(mktemp -d)"
cleanup() { render_answer; [[ -n "$SCRATCH" && -d "$SCRATCH" ]] && rm -rf "$SCRATCH"; return 0; }
trap cleanup EXIT

# --- how a long answer comes back --------------------------------------------
#
# What is done with this output is that it is read, and the reader pays for
# every line of it. A few dozen lines are cheaper printed than filed and fetched
# back, so they are printed. A long answer is written where it can be read in
# parts, and only its head returns: the header names the artifact and the class,
# which is what says whether the rest is worth reading at all.
#
# The whole run spills as one answer. A search that reads its hit does so by
# calling this script again, and that child writes into the same file rather
# than filing an answer of its own.
ANSWER_FILE=""

argv_key() { printf '%s\n' "$@" | cksum | awk '{print $1 "-" $2}'; }

render_answer() {
  [[ -n "$ANSWER_FILE" ]] || return 0
  local file="$ANSWER_FILE" n
  ANSWER_FILE=""
  exec 1>&3 3>&-
  n=$(awk 'END{print NR}' "$file")
  if [[ "$SPILL" == "always" || "$n" -gt "$SPILL_LINES" ]]; then
    head -n "$SPILL_HEAD" "$file"
    printf '\nanswer: %s lines, the first %s above. file: %s\n' "$n" "$SPILL_HEAD" "$file"
    printf 'hint: read the rest of it — sed -n %s,%sp %s\n' "$((SPILL_HEAD + 1))" "$n" "$file"
  else
    cat "$file"
  fi
  return 0
}

if [[ $JSON -eq 0 && "$SPILL" != "never" && "$MODE" != "index" && -z "${JLS_SPILL_ACTIVE:-}" ]]; then
  SPILL_NAME="${POSITIONAL[0]:-answer}"; SPILL_NAME="${SPILL_NAME##*.}"
  SPILL_NAME="${SPILL_NAME//[^A-Za-z0-9_-]/_}"
  if mkdir -p "$ANSWERS_ROOT" 2>/dev/null; then
    ANSWER_FILE="${ANSWERS_ROOT}/${SPILL_NAME}-$(argv_key ${ARGV_ALL[@]+"${ARGV_ALL[@]}"}).txt"
    if : > "$ANSWER_FILE" 2>/dev/null; then
      export JLS_SPILL_ACTIVE=1
      exec 3>&1
      exec > "$ANSWER_FILE"
    else
      ANSWER_FILE=""
    fi
  fi
fi
mvn_get() {
  [[ $OFFLINE -eq 1 ]] && return 1
  [[ $HAVE_MVN -eq 1 ]] || return 1
  mvn -q -B dependency:get -Dartifact="$1" >/dev/null 2>&1
}

# --- the classpath of a project module ---------------------------------------

# Asking Maven costs seconds, so the answer is kept and reused until the pom
# that produced it changes.
project_classpath() {
  # $1 project directory, $2 module or empty. Prints the path to the file.
  local dir="$1" mod="$2" pom key cp stamp now
  dir="${dir%/}"
  [[ -d "$dir" ]] || { err "maven-lib-source: ${dir} is not a directory."; return 1; }
  pom="${dir}/pom.xml"
  [[ -r "$pom" ]] || { err "maven-lib-source: no pom.xml in ${dir}."; return 1; }
  [[ $HAVE_MVN -eq 1 ]] || { err "maven-lib-source: mvn is not on PATH, so --from-project cannot resolve anything."; return 1; }

  key=$(printf '%s|%s' "$dir" "$mod" | cksum | tr -d ' ')
  cp="${PROJECT_ROOT}/${key}.cp"
  stamp="${PROJECT_ROOT}/${key}.stamp"
  # The stamp is what the poms say, not when they were touched. A module's own
  # pom decides its classpath as much as the root's does, so all of them count;
  # a checksum of their text catches an edit that keeps the size and the minute,
  # which a listing of names and dates does not.
  now=$(find "$dir" -name pom.xml ! -path '*/target/*' 2>/dev/null | LC_ALL=C sort \
        | while IFS= read -r p; do cat "$p"; done | cksum | tr -d ' ')

  if [[ -s "$cp" && -r "$stamp" && "$(cat "$stamp")" == "$now" ]]; then
    printf '%s' "$cp"; return 0
  fi

  mkdir -p "$PROJECT_ROOT" 2>/dev/null
  local args=(-q -B -f "$pom" dependency:build-classpath "-Dmdep.outputFile=${cp}")
  if [[ -n "$mod" ]]; then
    args+=(-pl "$mod")
  elif grep -q '<modules>' "$pom" 2>/dev/null; then
    # Every module of a reactor writes the same output file, so what survives is
    # one module's classpath rather than the sum of them. Which one is not worth
    # guessing at, and naming the module is the fix.
    err "maven-lib-source: ${pom} is a reactor and no module was named, so the classpath is one module's."
    err "hint: name the module being worked in — --module <path>. The modules it declares:"
    tr -d '\n' < "$pom" | sed -n 's:.*<modules>\(.*\)</modules>.*:\1:p' \
      | sed 's:</module>:\n:g; s:.*<module>::' | sed '/^[[:space:]]*$/d' \
      | while IFS= read -r one; do err "  ${one}"; done
  fi
  if ! mvn -o "${args[@]}" >/dev/null 2>&1; then
    if [[ $OFFLINE -eq 1 ]] || ! mvn "${args[@]}" >/dev/null 2>&1; then
      err "maven-lib-source: could not get the classpath of ${dir}${mod:+ (module ${mod})}."
      err "hint: run it yourself and read the failure — mvn -f ${pom}${mod:+ -pl ${mod}} dependency:build-classpath"
      return 1
    fi
  fi
  [[ -s "$cp" ]] || { err "maven-lib-source: Maven produced no classpath for ${dir}."; return 1; }
  printf '%s' "$now" > "$stamp" 2>/dev/null
  printf '%s' "$cp"
}

classpath_jars() {
  # $1 classpath file. One jar path per line.
  tr ':' '\n' < "$1" | sed '/^[[:space:]]*$/d' | grep '\.jar$' | sort -u
}

# The classes on a module's classpath, cached beside the classpath itself. The
# jars do not change until the build resolves differently, and rescanning four
# hundred of them is seconds paid again on every question. A jar newer than the
# cache — a snapshot reinstalled — is what makes it stale.
classpath_index() {
  # $1 classpath file. Prints the path to a "<gav>\t<fully qualified class>" file.
  local cp="$1" key idx jars stale=0 j
  key=$(cksum < "$cp" | tr -d ' ')
  idx="${PROJECT_ROOT}/${key}.tsv"
  jars="${SCRATCH}/jars.txt"
  classpath_jars "$cp" > "$jars"
  if [[ -s "$idx" && $NOCACHE -eq 0 && $REFRESH -eq 0 ]]; then
    while IFS= read -r j; do
      [[ "$j" -nt "$idx" ]] && { stale=1; break; }
    done < "$jars"
    [[ $stale -eq 0 ]] && { printf '%s' "$idx"; return 0; }
  fi
  mkdir -p "$PROJECT_ROOT" 2>/dev/null
  note "maven-lib-source: scanning $(wc -l < "$jars" | tr -d ' ') jars on that classpath. The next search reuses it."
  scan_jars < "$jars" > "${idx}.tmp" || return 1
  mv "${idx}.tmp" "$idx" || return 1
  printf '%s' "$idx"
}

version_from_classpath() {
  # $1 classpath file, $2 groupId, $3 artifactId. Prints the version.
  local gp="${2//.//}"
  classpath_jars "$1" | awk -v pat="/${gp}/${3}/" 'index($0, pat) > 0' \
    | head -1 | awk -F/ '{print $(NF-1)}'
}

# --- the index ---------------------------------------------------------------

index_file() {
  # $1 prefix or "all"
  printf '%s/%s.tsv' "$INDEX_ROOT" "$1"
}

# Lists the jars a prefix covers. Javadoc and test jars are not code anyone asks
# to read. A sources jar stands in only where the binary jar beside it is
# missing: some artifacts ship sources alone, and a class in one of them is a
# class the search should still find.
jars_under() {
  # $1 prefix or "all"
  local root="$M2"
  [[ "$1" != "all" ]] && root="${M2}/${1//.//}"
  [[ -d "$root" ]] || return 1
  find "$root" -name '*.jar' ! -name '*-javadoc.jar' \
       ! -name '*-tests.jar' ! -name '*-test-sources.jar' 2>/dev/null \
    | awk '{ if ($0 ~ /-sources\.jar$/) { b = $0; sub(/-sources\.jar$/, ".jar", b); src[b] = $0 }
             else bin[$0] = 1 }
           END { for (b in bin) print b
                 for (b in src) if (!(b in bin)) print src[b] }' \
    | sort
}

# Reads every jar on stdin and writes "<gav>\t<fully qualified class>" lines.
#
# Each worker writes a file of its own. Eight of them sharing one pipe tear each
# other's lines in half — a write longer than PIPE_BUF is not atomic — and every
# torn line is at once a class that does not exist and a class that is lost. It
# is silent, it is different on every run, and `index` writes it to disk to be
# believed later.
scan_jars() {
  local list="${SCRATCH}/scan-list.txt" parts="${SCRATCH}/parts" helper="${SCRATCH}/scan.sh" w
  cat > "$list"
  rm -rf "$parts"; mkdir -p "$parts" || return 1

  cat > "$helper" <<'EOS'
#!/usr/bin/env bash
# $1 the list of jars, $2 this worker's number, $3 how many workers, $4 its file
: > "$4"
i=0
while IFS= read -r jar; do
  i=$(( i + 1 ))
  [[ $(( (i - 1) % $3 )) -eq $(( $2 - 1 )) ]] || continue
  case "$jar" in
    *-sources.jar) pats=('*.java' '*.kt') ;;
    *)             pats=('*.class') ;;
  esac
  unzip -Z1 "$jar" "${pats[@]}" 2>/dev/null     | JLS_JAR="$jar" awk '{ print ENVIRON["JLS_JAR"] "	" $0 }' >> "$4"
done < "$1"
EOS
  chmod +x "$helper"
  for (( w = 1; w <= SCAN_JOBS; w++ )); do
    bash "$helper" "$list" "$w" "$SCAN_JOBS" "${parts}/${w}" &
  done
  wait

  cat "${parts}"/* 2>/dev/null \
    | awk -F'\t' -v m2="${M2}/" '
        BEGIN { ml = length(m2) }
        {
          jar = $1; cls = $2
          if (cls ~ /\$/) next
          if (cls ~ /(^|\/)(module-info|package-info)\./) next
          sub(/\.(class|java|kt)$/, "", cls); gsub(/\//, ".", cls)
          if (jar != last) {
            last = jar; gav = ""
            # The coordinates of a jar are its place in the repository, so a jar
            # that is not in the repository has none to read off.
            if (substr(jar, 1, ml) == m2) {
              rel = substr(jar, ml + 1)
              k = split(rel, p, "/")
              if (k >= 4) {
                ver = p[k-1]; art = p[k-2]
                grp = p[1]
                for (i = 2; i <= k-3; i++) grp = grp "." p[i]
                gav = grp ":" art ":" ver
              }
            }
            if (gav == "") outside++
          }
          if (gav == "") next
          print gav "\t" cls
        }
        END { if (outside > 0)
                printf "maven-lib-source: %d jar(s) outside %s were skipped: their coordinates are not readable.\n", outside, m2 > "/dev/stderr" }'
}

build_index() {
  # $1 prefix or "all"
  local prefix="$1" file jars tmp
  file="$(index_file "$prefix")"
  mkdir -p "$INDEX_ROOT" 2>/dev/null
  jars="${SCRATCH}/jars.txt"
  if ! jars_under "$prefix" > "$jars" || [[ ! -s "$jars" ]]; then
    err "maven-lib-source: nothing under group prefix ${prefix} in ${M2}."
    return 1
  fi
  local n; n=$(wc -l < "$jars" | tr -d ' ')
  [[ $REFRESH -eq 1 ]] && rm -f "$file"
  err "maven-lib-source: indexing ${n} jars under ${prefix}. This is done once."
  tmp="${SCRATCH}/index.tsv"
  scan_jars < "$jars" | sort -u > "$tmp" || return 1
  if [[ -s "$file" ]]; then
    sort -u "$file" "$tmp" > "${tmp}.merged" && mv "${tmp}.merged" "$file"
  else
    mv "$tmp" "$file"
  fi
  err "maven-lib-source: index at ${file} — $(wc -l < "$file" | tr -d ' ') classes."
  return 0
}

if [[ "$MODE" == "index" ]]; then
  PREFIXES=()
  [[ $N_POS -gt 0 ]] && PREFIXES=("${POSITIONAL[@]}")
  [[ -n "$GROUP_PREFIX" ]] && PREFIXES+=("$GROUP_PREFIX")
  if [[ ${#PREFIXES[@]} -eq 0 ]]; then
    [[ $ALL -eq 1 ]] || usage_err "index needs a group prefix, or --all to cover the whole repository (slow, and large)"
    PREFIXES=("all")
  fi
  rc=0
  for p in "${PREFIXES[@]}"; do build_index "$p" || rc=4; done
  exit $rc
fi

# --- find --------------------------------------------------------------------

# Twenty versions of one library in the repository are one answer, not twenty.
# Collapsing them to the newest is what keeps a search down to the classes it
# actually found — and what lets it read its single hit instead of handing back
# a list to choose from.
dedupe_hits() {
  # Reads "<gav>\t<fqn>". Writes "<gav of the newest>\t<fqn>\t<how many versions>".
  awk -F'\t' '{ if (split($1, g, ":") < 3) next
                print g[1] ":" g[2] "\t" $2 "\t" g[3] }' \
  | sort -t"$TAB" -k1,1 -k2,2 -k3,3V \
  | awk -F'\t' '{ k = $1 "\t" $2
                  if (!(k in cnt)) ord[++m] = k
                  cnt[k]++; ver[k] = $3 }
                END { for (i = 1; i <= m; i++) { k = ord[i]; split(k, p, "\t")
                        printf "%s:%s\t%s\t%s\n", p[1], ver[k], p[2], cnt[k] } }'
}

report_hits() {
  # Reads "<gav>\t<fqn>\t<versions>" on stdin. $1 is the name that was asked for.
  local name="$1"
  local hits="${SCRATCH}/hits.txt"
  cat > "$hits"
  local n; n=$(grep -c . < "$hits")
  if [[ "$n" -eq 0 ]]; then return 1; fi
  if [[ $JSON -eq 1 ]]; then
    printf '{"class":"%s","found":%s,"hits":[' "$name" "$n"
    awk -F'\t' 'NR>1{printf ","} {printf "{\"artifact\":\"%s\",\"class\":\"%s\",\"versionsInRepository\":%s}", $1, $2, $3}' "$hits"
    printf ']}\n'
  else
    printf 'class: %s\n' "$name"
    printf 'found: %s\n' "$n"
    awk -F'\t' '{ if ($3 + 0 > 1) printf "  %s  %s  (newest of %d in the repository)\n", $1, $2, $3
                  else printf "  %s  %s\n", $1, $2 }' "$hits"
    [[ "$n" -gt 1 ]] && printf 'hint: read one of them with: maven-lib-source.sh <groupId> <artifactId> <version> <class>\n'
  fi
  return 0
}

# A single hit is read rather than reported and left. The read is this script
# called again: the coordinates are known by then, so it costs one process and
# no Maven, and every option the caller gave about *what* to print is passed on.
read_hit() {
  # $1 "<groupId>:<artifactId>:<version>", $2 fully qualified class.
  local gav="$1" fqn="$2" rest args m
  args=("${gav%%:*}")                       # groupId
  rest="${gav#*:}"
  args+=("${rest%%:*}" "${rest##*:}" "$fqn")  # artifactId, version, class
  [[ $PRINT -eq 1 ]] && args+=(--print)
  [[ $OFFLINE -eq 1 ]] && args+=(--offline)
  [[ $NOCACHE -eq 1 ]] && args+=(--no-cache)
  [[ -n "$OUTDIR" ]] && args+=(--out "$OUTDIR")
  args+=(--spill "$SPILL")            # one run spills once, and the parent decides
  [[ -n "$MEMBERS" ]] && args+=(--members "$MEMBERS")
  [[ $JSON -eq 1 ]] && args+=(--json)
  for m in ${METHODS[@]+"${METHODS[@]}"}; do args+=(--method "$m"); done
  bash "$SELF" "${args[@]}"
}

if [[ "$MODE" == "find" ]]; then
  [[ $N_POS -ge 1 ]] || usage_err "find takes at least one class name"

  # A nested class lives in the file of the class that encloses it.
  FIND_NAMES=()
  for a in "${POSITIONAL[@]}"; do FIND_NAMES+=("${a%%\$*}"); done

  # A name is compared, not matched: a regular expression here would need
  # escaping that awk's -v assignment eats, and TKID would answer for
  # ErmittleCKMfuerTKID.
  filter_hits() {
    # $1 the name to keep.
    local name="$1" fq=0
    [[ "$name" == *.* ]] && fq=1
    awk -F'\t' -v name="$name" -v fq="$fq" '
      { s = $2; sub(/^.*\./, "", s)
        if (fq == 1) { if ($2 == name) print }
        else if (s == name) print }'
  }

  # Every name is answered out of one pass over the classes, so asking for four
  # of them costs what asking for one costs.
  CLASSES="${SCRATCH}/classes.tsv"
  SOURCE_LABEL=""

  if [[ -n "$FROM_PROJECT" ]]; then
    # The narrowest and most exact search there is: only what this module
    # actually puts on its classpath.
    CP="$(project_classpath "$FROM_PROJECT" "$MODULE")" || exit 3
    CP_INDEX="$(classpath_index "$CP")" || exit 3
    cp "$CP_INDEX" "$CLASSES"
    SOURCE_LABEL="the classpath of ${FROM_PROJECT}${MODULE:+ (module ${MODULE})}"
  else
    SEARCH_PREFIX=""
    [[ -n "$GROUP_PREFIX" ]] && SEARCH_PREFIX="$GROUP_PREFIX"
    [[ -z "$SEARCH_PREFIX" && $ALL -eq 1 ]] && SEARCH_PREFIX="all"

    if [[ -z "$SEARCH_PREFIX" ]]; then
      # Pick what is indexed rather than scan 20000 jars by surprise.
      : > "$CLASSES"
      if [[ -d "$INDEX_ROOT" ]]; then
        for f in "$INDEX_ROOT"/*.tsv; do
          [[ -e "$f" ]] || continue
          cat "$f" >> "$CLASSES"
        done
      fi
      if [[ ! -s "$CLASSES" ]]; then
        err "maven-lib-source: ${FIND_NAMES[0]} is in no index, and no group prefix was given."
        err "hint: narrow it — maven-lib-source.sh find ${FIND_NAMES[0]} --group-prefix <groupId prefix>"
        err "hint: or search only what a project uses — maven-lib-source.sh find ${FIND_NAMES[0]} --from-project <dir>"
        err "hint: or index once, then search instantly — maven-lib-source.sh index <groupId prefix>"
        exit 4
      fi
      SOURCE_LABEL="the indexes under ${INDEX_ROOT}"
    else
      IDX="$(index_file "$SEARCH_PREFIX")"
      if [[ -s "$IDX" && $NOCACHE -eq 0 && $REFRESH -eq 0 ]]; then
        cp "$IDX" "$CLASSES"
        SOURCE_LABEL="${SEARCH_PREFIX} (from the index at ${IDX})"
      else
        jars_under "$SEARCH_PREFIX" > "${SCRATCH}/jars.txt" || { err "maven-lib-source: nothing under ${SEARCH_PREFIX} in ${M2}."; exit 4; }
        NJ=$(wc -l < "${SCRATCH}/jars.txt" | tr -d ' ')
        [[ "$NJ" -gt 2000 ]] && note "maven-lib-source: scanning ${NJ} jars. Build an index to make this instant: maven-lib-source.sh index ${SEARCH_PREFIX}"
        scan_jars < "${SCRATCH}/jars.txt" > "$CLASSES"
        SOURCE_LABEL="${SEARCH_PREFIX} in ${M2}"
      fi
    fi
  fi

  FIND_RC=0
  FIRST=1
  for name in "${FIND_NAMES[@]}"; do
    HIT_FILE="${SCRATCH}/hits-of-${name}.txt"
    filter_hits "$name" < "$CLASSES" | sort -u | dedupe_hits > "$HIT_FILE"
    # Under --json every block is one object on one line, so nothing separates
    # them: a blank line between two of them is not what a reader of JSON lines
    # expects to have to skip.
    [[ $FIRST -eq 1 || $JSON -eq 1 ]] || printf '\n'
    FIRST=0

    # A fully qualified name that matched nothing is nearly always a guessed
    # package rather than an absent class: the class is there, one package over.
    # The simple name finds it in a second pass over a list already in hand, so
    # the caller gets the class instead of a dead end and a second call. What
    # was read is not what was asked for, so it is said plainly, and the header
    # of the answer carries the package the class actually has.
    MATCH_NAME="$name"
    if [[ ! -s "$HIT_FILE" && "$name" == *.* ]]; then
      SIMPLE="${name##*.}"
      filter_hits "$SIMPLE" < "$CLASSES" | sort -u | dedupe_hits > "$HIT_FILE"
      if [[ -s "$HIT_FILE" ]]; then
        MATCH_NAME="$SIMPLE"
        if [[ $LIST -eq 0 && "$(grep -c . < "$HIT_FILE")" -eq 1 ]]; then
          err "maven-lib-source: nothing on ${SOURCE_LABEL} is called ${name}; the one class called ${SIMPLE} was read instead."
        else
          err "maven-lib-source: nothing on ${SOURCE_LABEL} is called ${name}; these are called ${SIMPLE}."
        fi
      fi
    fi

    if [[ ! -s "$HIT_FILE" ]]; then
      err "maven-lib-source: no class matching ${name} on ${SOURCE_LABEL}."
      if [[ -n "$FROM_PROJECT" ]]; then
        err "hint: nothing that module compiles against declares it — name the module that does with --module <path>, or search the repository instead: maven-lib-source.sh find ${name##*.} --group-prefix <groupId prefix>"
      else
        err "hint: the index may predate the artifact — maven-lib-source.sh index <groupId prefix> --refresh"
      fi
      FIND_RC=4
      continue
    fi

    # One hit is read rather than listed: the read names the artifact and the
    # class itself, so a list of one above it would say the same thing twice.
    if [[ $LIST -eq 0 && "$(grep -c . < "$HIT_FILE")" -eq 1 ]]; then
      HIT_VERSIONS="$(cut -f3 < "$HIT_FILE")"
      [[ "${HIT_VERSIONS:-1}" -gt 1 && -z "$FROM_PROJECT" ]] && \
        err "maven-lib-source: the repository holds ${HIT_VERSIONS} versions of that artifact and the newest was read; --from-project <dir> takes the one the build uses."
      read_hit "$(cut -f1 < "$HIT_FILE")" "$(cut -f2 < "$HIT_FILE")" || FIND_RC=$?
    else
      report_hits "$MATCH_NAME" < "$HIT_FILE"
    fi
  done
  exit $FIND_RC
fi

# --- read: the coordinates ---------------------------------------------------

if [[ -n "$FROM_PROJECT" ]]; then
  [[ $N_POS -eq 3 ]] || usage_err "with --from-project the version comes from the project, so pass three arguments: <groupId> <artifactId> <className>"
  GROUP="${POSITIONAL[0]}"
  ARTIFACT="${POSITIONAL[1]}"
  CLASSNAME="${POSITIONAL[2]}"
  CP="$(project_classpath "$FROM_PROJECT" "$MODULE")" || exit 3
  VERSION="$(version_from_classpath "$CP" "$GROUP" "$ARTIFACT")"
  if [[ -z "$VERSION" ]]; then
    err "maven-lib-source: ${GROUP}:${ARTIFACT} is not on the classpath of ${FROM_PROJECT}${MODULE:+ (module ${MODULE})}."
    err "hint: check what is — mvn -f ${FROM_PROJECT%/}/pom.xml${MODULE:+ -pl ${MODULE}} dependency:tree -Dincludes=${GROUP}:${ARTIFACT}"
    exit 3
  fi
else
  [[ $N_POS -eq 4 ]] || usage_err "expected four arguments, got ${N_POS}"
  GROUP="${POSITIONAL[0]}"
  ARTIFACT="${POSITIONAL[1]}"
  VERSION="${POSITIONAL[2]}"
  CLASSNAME="${POSITIONAL[3]}"
fi

GROUP_PATH="${GROUP//.//}"
ARTIFACT_ROOT="${M2}/${GROUP_PATH}/${ARTIFACT}"
ARTIFACT_DIR="${ARTIFACT_ROOT}/${VERSION}"
JAR="${ARTIFACT_DIR}/${ARTIFACT}-${VERSION}.jar"
SRC_JAR="${ARTIFACT_DIR}/${ARTIFACT}-${VERSION}-sources.jar"
POM="${ARTIFACT_DIR}/${ARTIFACT}-${VERSION}.pom"

GAV_PATH="${GROUP}/${ARTIFACT}/${VERSION}"
SRC_DIR="${SRC_ROOT}/${GAV_PATH}/sources"
SRC_MARK="${SRC_ROOT}/${GAV_PATH}/.unpacked"
CACHE_DIR="${CACHE_ROOT}/${GAV_PATH}"

# Every version of this artifact that is already on disk. This is the answer to
# a wrong version, which is the most common way to call this.
available_versions() {
  [[ -d "$ARTIFACT_ROOT" ]] || return 1
  find "$ARTIFACT_ROOT" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null \
    | grep -v '^\.' | sort -V
}

report_versions() {
  local list
  list=$(available_versions)
  if [[ -n "$list" ]]; then
    err "maven-lib-source: ${GROUP}:${ARTIFACT}:${VERSION} is not in ${M2}."
    err "Versions of ${GROUP}:${ARTIFACT} that are:"
    printf '%s\n' "$list" | while IFS= read -r v; do err "  ${v}"; done
    err "hint: let the build decide instead of picking from this list — add --from-project <dir> and drop the version."
  else
    err "maven-lib-source: ${GROUP}:${ARTIFACT} is not in ${M2} at any version."
    err "hint: mvn dependency:get -Dartifact=${GROUP}:${ARTIFACT}:${VERSION}"
  fi
}

# --- the artifact ------------------------------------------------------------

if [[ ! -f "$JAR" && ! -f "$SRC_JAR" ]]; then
  if ! mvn_get "${GROUP}:${ARTIFACT}:${VERSION}"; then
    report_versions
    exit 3
  fi
fi

list_jar() {
  local out
  if out=$(unzip -Z1 "$1" 2>/dev/null); then
    printf '%s\n' "$out"
  else
    unzip -l "$1" 2>/dev/null | awk 'NF>=4 {print $4}'
  fi
}

# --- the class name ----------------------------------------------------------

# A nested class lives in the file of the class that encloses it, so the source
# to look for is always the outer one.
CLASSNAME="${CLASSNAME%%\$*}"

FQN=""
if [[ "$CLASSNAME" == *.* ]]; then
  FQN="$CLASSNAME"
else
  [[ -f "$JAR" ]] || { err "maven-lib-source: a simple class name needs the binary jar, and ${JAR} is not there."; err "hint: call it again with the fully qualified class name."; exit 4; }
  MATCHES=$(list_jar "$JAR" | grep -E "(^|/)${CLASSNAME}\.class$" | sed 's:/:.:g; s:\.class$::' | sort)
  N_MATCHES=$(printf '%s' "$MATCHES" | grep -c .)
  if [[ "$N_MATCHES" -eq 0 ]]; then
    err "maven-lib-source: no class named ${CLASSNAME} in ${GROUP}:${ARTIFACT}:${VERSION}."
    err "hint: find where it actually lives — maven-lib-source.sh find ${CLASSNAME} --group-prefix ${GROUP}"
    exit 4
  elif [[ "$N_MATCHES" -gt 1 ]]; then
    err "maven-lib-source: ${CLASSNAME} is ambiguous in ${GROUP}:${ARTIFACT}:${VERSION}."
    err "hint: call it again with one of:"
    printf '%s\n' "$MATCHES" | while IFS= read -r c; do err "  ${c}"; done
    exit 5
  fi
  FQN="$MATCHES"
fi

CLASS_PATH="${FQN//.//}"
SIMPLE="${FQN##*.}"
ORIGIN_FILE="${CACHE_DIR}/${FQN}.origin"

# --- reading Java text -------------------------------------------------------

# Java text, whether it came from a sources jar or from the decompiler, is cut
# by brace balance rather than parsed. Strings, character literals and comments
# are blanked first so that a brace inside one of them does not count. A
# declaration is told from a call by what stands in front of the name and by
# what closes the statement. Both readers below share that pass.
read -r -d '' AWK_COMMON <<'AWK'
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

function blank(   i, line, out, j, L, c, c2, c3, d, q) {
  inblk = 0; intxt = 0
  for (i = 1; i <= n; i++) {
    line = raw[i]; out = ""; j = 1; L = length(line)
    while (j <= L) {
      c = substr(line, j, 1); c2 = substr(line, j, 2); c3 = substr(line, j, 3)
      if (inblk) {
        if (c2 == "*/") { inblk = 0; out = out "  "; j += 2 } else { out = out " "; j++ }
        continue
      }
      # A text block runs over lines and holds whatever it likes — braces, //,
      # /* — so it is blanked before any of those are looked for.
      if (intxt) {
        if (c3 == "\"\"\"") { intxt = 0; out = out "   "; j += 3 } else { out = out " "; j++ }
        continue
      }
      if (c3 == "\"\"\"") { intxt = 1; out = out "   "; j += 3; continue }
      if (c2 == "//") { while (j <= L) { out = out " "; j++ }; continue }
      if (c2 == "/*") { inblk = 1; out = out "  "; j += 2; continue }
      if (c == "\"" || c == "'") {
        q = c; out = out " "; j++
        while (j <= L) {
          d = substr(line, j, 1)
          if (d == "\\") { out = out "  "; j += 2; continue }
          out = out " "; j++
          if (d == q) break
        }
        continue
      }
      out = out c; j++
    }
    clean[i] = out
  }
}

# Walks from the parenthesis at clean[li] position ci to the one that closes it.
# Leaves the result in cl_line and cl_col; returns 0 when there is no match.
function close_paren(li, ci,   depth, L, ch) {
  depth = 0
  while (li <= n) {
    L = length(clean[li])
    while (ci <= L) {
      ch = substr(clean[li], ci, 1)
      if (ch == "(") depth++
      else if (ch == ")") { depth--; if (depth == 0) { cl_line = li; cl_col = ci; return 1 } }
      ci++
    }
    li++; ci = 1
  }
  return 0
}

# Given the line and column of the closing parenthesis, decides whether what
# follows makes this a declaration. Sets term to "{" or ";" and term_line to the
# line carrying it. A throws clause may run over several lines, so the text
# between is collected across all of them.
function declares(li, ci,   tail, tl, acc, bt) {
  tail = substr(clean[li], ci + 1); tl = li; term = ""; acc = ""
  while (tl <= n) {
    if (match(tail, /[{;]/)) { acc = acc " " substr(tail, 1, RSTART - 1); term = substr(tail, RSTART, 1); break }
    acc = acc " " tail
    if (trim(acc) != "" && trim(acc) !~ /^throws([ \t]|$)/ && trim(acc) !~ /^default([ \t]|$)/) break
    tl++
    if (tl > n) break
    tail = clean[tl]
  }
  if (term == "") return 0
  bt = trim(acc)
  if (bt != "" && bt !~ /^throws[ \t]+[A-Za-z0-9_$.,<> \t]*$/ && bt !~ /^default([ \t]|$)/) return 0
  term_line = tl
  return 1
}

# The line where the body opened, counting braces to the one that closes it.
function body_end(tl,   bl, bc, d, L, ch) {
  bl = tl; bc = index(clean[tl], "{"); d = 0
  while (bl <= n) {
    L = length(clean[bl])
    while (bc <= L) {
      ch = substr(clean[bl], bc, 1)
      if (ch == "{") d++
      else if (ch == "}") { d--; if (d == 0) return bl }
      bc++
    }
    bl++; bc = 1
  }
  return 0
}

# The javadoc and the annotations that sit directly above line i.
function lead(i,   start, k, t) {
  start = i
  for (k = i - 1; k >= 1; k--) {
    t = trim(raw[k])
    if (t ~ /^@/ || t ~ /^\*/ || t ~ /^\/\*/ || t ~ /^\/\//) start = k
    else break
  }
  return start
}
AWK

read -r -d '' AWK_METHOD <<'AWK'
{ raw[NR] = $0 }

END {
  n = NR
  blank()
  decl = "(^|[^A-Za-z0-9_$.])" name "[ \t]*\\("
  found = 0

  for (i = 1; i <= n; i++) {
    if (!match(clean[i], decl)) continue
    p = RSTART + RLENGTH - 1
    pre = substr(clean[i], 1, RSTART)
    if (pre ~ /[=;]/) continue
    if (pre ~ /(^|[^A-Za-z0-9_$])(return|new|throw|if|while|for|switch|catch)[ \t]*$/) continue
    if (!close_paren(i, p)) continue
    if (!declares(cl_line, cl_col)) continue
    if (term == ";" && trim(pre) == "") continue          # a bare call, not a declaration

    if (term == ";") end = term_line
    else { end = body_end(term_line); if (!end) continue }

    if (found) print ""
    for (k = lead(i); k <= end; k++) print raw[k]
    found++
    i = end
  }

  exit(found ? 0 : 1)
}
AWK

# An index of what the file declares, with the line each declaration starts on.
# It is what makes the returned path usable: the caller reads the range it
# needs instead of the whole file.
#
# Three things are indexed — the types, their members, and the fields. A class
# that is nothing but fields is a very common thing to ask about, and an index
# that skipped them answered such a class with its own name and nothing else.
#
# Nothing inside a method body is indexed, and that is enforced rather than
# hoped for: a recognised body is skipped over to its closing brace, so the
# local variables, the local classes and the anonymous ones stay out.
read -r -d '' AWK_INDEX <<'AWK'
{ raw[NR] = $0 }

END {
  n = NR
  blank()
  depth = 0
  mbody = 0             # the last line of the body being skipped over
  pending_type = 0      # a type has been declared; its brace has not opened yet
  pending_enum = 0

  for (i = 1; i <= n; i++) {
    line = clean[i]
    shown = 0
    inside = (i <= mbody)

    if (!inside && depth <= 2 && match(line, /(^|[^A-Za-z0-9_$])(class|interface|enum|record|@interface)[ \t]+[A-Za-z0-9_$]+/)) {
      kw = substr(line, RSTART, RLENGTH)
      t = trim(raw[i]); sub(/[ \t]*\{[ \t]*$/, "", t)
      printf "%6d  %s\n", i, t
      pending_type = 1
      pending_enum = (kw ~ /(^|[^A-Za-z0-9_$])enum[ \t]/) ? 1 : 0
      shown = 1
    }

    # Members, and only at the depth of a type body.
    if (!shown && !inside && depth >= 1 && depth <= 3 && match(line, /[A-Za-z0-9_$]+[ \t]*\(/)) {
      p = RSTART + RLENGTH - 1
      pre = substr(line, 1, RSTART - 1)
      nm = substr(line, RSTART, RLENGTH); sub(/[ \t]*\($/, "", nm)
      prev = RSTART > 1 ? substr(line, RSTART - 1, 1) : ""
      if (prev != "." && nm !~ /^(return|new|throw|if|while|for|switch|catch|do|else|synchronized|assert|instanceof|case|yield|this|super)$/ \
          && pre !~ /[=;]/ && pre !~ /(^|[^A-Za-z0-9_$])(return|new|throw|if|while|for|switch|catch)[ \t]*$/) {
        if (close_paren(i, p) && declares(cl_line, cl_col)) {
          if (!(term == ";" && trim(pre) == "")) {
            t = trim(raw[i]); sub(/[ \t]*\{[ \t]*$/, "", t)
            gsub(/[ \t]+/, " ", t)
            printf "%6d  %s\n", i, t
            shown = 1
            if (term == "{") { e = body_end(term_line); if (e > mbody) mbody = e }
          }
        }
      }
    }

    # An enum's constants: the bare names at the top of an enum body, up to the
    # semicolon that ends the list. Which body is an enum's is remembered rather
    # than guessed at from the shape of the name, so a one-letter constant and a
    # mixed-case one are as visible as a shouted one.
    if (!shown && !inside && (depth in is_enum) && is_enum[depth] && !const_done[depth] \
        && match(raw[i], /^[ \t]*[A-Za-z_$][A-Za-z0-9_$]*[ \t]*([({,;]|$)/)) {
      t = trim(raw[i]); sub(/[ \t]*[,;][ \t]*$/, "", t)
      printf "%6d  %s\n", i, t
      shown = 1
    }

    # Fields. A declaration is two names in a row before the "=" or the ";",
    # with no parenthesis in front of it — which is what tells "String name;"
    # from "name = other;" and from a call.
    if (!shown && !inside && depth >= 1 && depth <= 3 && match(line, /[=;]/)) {
      lhs = substr(line, 1, RSTART - 1)
      if (lhs !~ /[()]/ \
          && lhs ~ /[]A-Za-z0-9_$>,][ \t]+[A-Za-z_$][A-Za-z0-9_$]*[ \t]*$/ \
          && lhs !~ /(^|[^A-Za-z0-9_$])(return|throw|new|case|default|else|do|assert|yield|break|continue|import|package|extends|implements|permits|throws)([^A-Za-z0-9_$]|$)/) {
        t = trim(raw[i]); sub(/[ \t]*=.*$/, "", t); sub(/[ \t]*;[ \t]*$/, "", t)
        gsub(/[ \t]+/, " ", t)
        printf "%6d  %s\n", i, t
        shown = 1
        # An initialiser that opens a brace is a body like any other.
        if (index(line, "{") > 0) { e = body_end(i); if (e > mbody) mbody = e }
      }
    }

    # An initialiser block declares nothing, and what it holds is statements.
    if (!shown && !inside && depth >= 1 && line ~ /^[ \t]*(static[ \t]*)?\{[ \t]*$/) {
      e = body_end(i); if (e > mbody) mbody = e
    }

    L = length(line)
    for (j = 1; j <= L; j++) {
      ch = substr(line, j, 1)
      if (ch == "{") {
        depth++
        is_enum[depth] = pending_type ? pending_enum : 0
        const_done[depth] = 0
        pending_type = 0
      }
      else if (ch == "}") {
        if (depth >= 1) { is_enum[depth] = 0; const_done[depth] = 0 }
        depth--
      }
    }
    if (depth < 0) depth = 0
    if (!pending_type && (depth in is_enum) && is_enum[depth] && index(line, ";") > 0)
      const_done[depth] = 1
  }
}
AWK

# --- who reads the Java ------------------------------------------------------
#
# javac's own parser, where there is one. It cannot be wrong about what a file
# declares, which the readers above can: they follow the shape of the text, and
# a shape nobody thought of is a declaration silently missing from an answer.
#
# The awk readers stay, and stay the fallback: a machine with no JDK, a source
# newer than the runtime, and Kotlin — none of which the parser can do anything
# with — are all still answered.

JAVA_READER_DIR=""
JAVA_READER_PROBED=0

java_reader() {
  # Prints the directory holding the compiled reader. Compiling it costs half a
  # second and is done once per version of it, so it is kept beside the caches.
  if [[ $JAVA_READER_PROBED -eq 0 ]]; then
    JAVA_READER_PROBED=1
    local srcf="${SELF_DIR}/MavenLibSource.java" key dir
    # MAVEN_LIB_SOURCE_READER=text puts the fallback in front, which is how it is
    # tested on a machine that has a JDK.
    [[ "${MAVEN_LIB_SOURCE_READER:-}" == "text" ]] && return 1
    if [[ $HAVE_JAVA -eq 1 && -r "$srcf" ]] && need javac; then
      key=$(cksum < "$srcf" | tr -d ' ')
      dir="${TOOL_ROOT}/${key}"
      if [[ ! -s "${dir}/MavenLibSource.class" ]]; then
        err "maven-lib-source: compiling the source reader. This is done once."
        mkdir -p "$dir" 2>/dev/null
        javac -d "$dir" "$srcf" >/dev/null 2>&1 || rm -rf "$dir"
      fi
      [[ -s "${dir}/MavenLibSource.class" ]] && JAVA_READER_DIR="$dir"
    fi
  fi
  [[ -n "$JAVA_READER_DIR" ]] || return 1
  printf '%s' "$JAVA_READER_DIR"
}

extract_method() {
  # $1 the file, $2 the method name.
  local dir out
  if [[ "$1" == *.java ]] && dir="$(java_reader)"; then
    out="${SCRATCH}/cut.txt"
    if java -cp "$dir" MavenLibSource method "$1" "$2" > "$out" 2>/dev/null && [[ -s "$out" ]]; then
      cat "$out"; return 0
    fi
  fi
  awk -v name="$2" "$AWK_COMMON
$AWK_METHOD" "$1"
}

build_class_index() {
  # $1 the file. The answer is kept under the checksum of the file it came from,
  # so a class read twice is parsed once — which is what makes the parser the
  # cheaper of the two readers rather than the dearer one.
  local file="$1" dir key cache tmp="${SCRATCH}/declared.txt"
  key=$(cksum < "$file" | tr -d ' ')
  if [[ "$file" == *.java ]] && dir="$(java_reader)"; then key="${key}-p"; else key="${key}-t"; fi
  cache="${DECL_ROOT}/${key}.idx"
  if [[ $NOCACHE -eq 0 && -s "$cache" ]]; then cat "$cache"; return 0; fi

  : > "$tmp"
  [[ -n "$dir" ]] && java -cp "$dir" MavenLibSource index "$file" > "$tmp" 2>/dev/null
  [[ -s "$tmp" ]] || awk "$AWK_COMMON
$AWK_INDEX" "$file" > "$tmp"
  mkdir -p "$DECL_ROOT" 2>/dev/null && cp "$tmp" "$cache" 2>/dev/null
  cat "$tmp"
}

# --- output ------------------------------------------------------------------

warning_for() {
  case "$1" in
    decompiled*) printf '%s' "decompiled bytecode: no javadoc or comments, parameter names may read var1, var2, and lambdas appear as synthetic methods" ;;
    javap)       printf '%s' "signatures only: no method bodies, no javadoc" ;;
    *)           printf '%s' "" ;;
  esac
}

json_escape() {
  awk 'BEGIN{ORS=""} {
    gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,"\\r")
    if(NR>1) printf "\\n"
    printf "%s", $0
  }'
}

emit_header() {
  local origin="$1" warn
  warn="$(warning_for "$origin")"
  printf 'artifact: %s:%s:%s\n' "$GROUP" "$ARTIFACT" "$VERSION"
  [[ -n "$FROM_PROJECT" ]] && printf 'version from: %s%s\n' "$FROM_PROJECT" "${MODULE:+ (module ${MODULE})}"
  printf 'class: %s\n' "$FQN"
  [[ -n "$METHOD" && $N_METHODS -gt 0 ]] && printf 'method: %s\n' "$METHOD"
  printf 'source: %s\n' "$origin"
  [[ -n "$warn" ]] && printf 'warning: %s\n' "$warn"
}

emit_body() {
  local warn; warn="$(warning_for "$2")"
  if [[ $JSON -eq 1 ]]; then
    printf '{"artifact":"%s:%s:%s","class":"%s","method":"%s","source":"%s","warning":"%s","body":"' \
      "$GROUP" "$ARTIFACT" "$VERSION" "$FQN" "$METHOD" "$2" "$warn"
    json_escape < "$1"
    printf '"}\n'
  else
    emit_header "$2"
    printf -- '---\n'
    cat "$1"
  fi
}

emit_path() {
  local file="$1" origin="$2" lines idx warn total kept label
  lines=$(awk 'END{print NR}' "$file")
  idx=$(build_class_index "$file")
  warn="$(warning_for "$origin")"
  label="index:"

  # A fat class declares hundreds of things, and a caller who named what it is
  # after wants those and pays for the rest. The count of what was dropped stays,
  # so an empty answer reads as a pattern that missed rather than a class that
  # declares nothing.
  if [[ -n "$MEMBERS" ]]; then
    total=$(printf '%s\n' "$idx" | grep -c . )
    idx=$(printf '%s\n' "$idx" | grep -iE -- "$MEMBERS")
    kept=$(printf '%s\n' "$idx" | grep -c . )
    label="index: ${kept} of ${total} declarations matching ${MEMBERS}"
    [[ "$kept" -eq 0 ]] && err "maven-lib-source: nothing in ${FQN} matches ${MEMBERS}; call it again without --members for all ${total}."
  fi

  if [[ $JSON -eq 1 ]]; then
    printf '{"artifact":"%s:%s:%s","class":"%s","source":"%s","warning":"%s","file":"%s","lines":%s,"index":"' \
      "$GROUP" "$ARTIFACT" "$VERSION" "$FQN" "$origin" "$warn" "$file" "$lines"
    printf '%s\n' "$idx" | json_escape
    printf '"}\n'
  else
    emit_header "$origin"
    printf 'file: %s\n' "$file"
    printf 'lines: %s\n' "$lines"
    printf '%s\n' "$label"
    printf '%s\n' "$idx"
  fi
}

deliver() {
  # $1 file holding the whole class, $2 origin. Never returns.
  local file="$1" origin="$2" out base

  if [[ -n "$OUTDIR" ]]; then
    mkdir -p "$OUTDIR" 2>/dev/null
    base="${file##*/}"
    if cp "$file" "${OUTDIR%/}/${base}" 2>/dev/null; then file="${OUTDIR%/}/${base}"; fi
  fi

  if [[ $N_METHODS -eq 0 ]]; then
    # javap output is a signature listing already, and small. A path to it would
    # cost a read for nothing.
    if [[ "$origin" == "javap" || $PRINT -eq 1 ]]; then emit_body "$file" "$origin"; else emit_path "$file" "$origin"; fi
    exit 0
  fi

  # Several methods of one class are cut in one pass over the file: the class is
  # already open, and the caller wanting two of them is the common case.
  out="${SCRATCH}/method.txt"
  one="${SCRATCH}/one-method.txt"
  : > "$out"
  local m cut=0 missing=() uncut=()
  for m in "${METHODS[@]}"; do
    if [[ "$origin" == "javap" ]]; then
      grep -E "(^|[^A-Za-z0-9_$.])${m}[[:space:]]*\(" "$file" > "$one"
    else
      extract_method "$file" "$m" > "$one"
    fi
    if [[ -s "$one" ]]; then
      [[ $cut -gt 0 ]] && printf '\n' >> "$out"
      [[ $N_METHODS -gt 1 ]] && printf -- '// %s\n' "$m" >> "$out"
      cat "$one" >> "$out"
      cut=$(( cut + 1 ))
    elif grep -qE "(^|[^A-Za-z0-9_$.])${m}[[:space:]]*\(" "$file"; then
      uncut+=("$m")
    else
      missing+=("$m")
    fi
  done

  if [[ $cut -eq 0 ]]; then
    if [[ ${#uncut[@]} -gt 0 ]]; then
      # The name is in the file but the cut failed. The path plus the index is a
      # worse answer than the method, and a much better one than nothing.
      err "maven-lib-source: could not cut ${METHOD} out of ${FQN}; the file and its index were returned instead."
      METHOD=""; N_METHODS=0
      emit_path "$file" "$origin"
      exit 0
    fi
    err "maven-lib-source: no method named ${METHOD} in ${FQN} (source: ${origin})."
    err "hint: the methods this class declares are listed by calling it again without --method."
    exit 6
  fi

  [[ ${#missing[@]} -gt 0 ]] && err "maven-lib-source: ${FQN} declares no ${missing[*]}; the rest was returned."
  [[ ${#uncut[@]} -gt 0 ]] && err "maven-lib-source: could not cut ${uncut[*]} out of ${FQN}; the rest was returned."

  emit_body "$out" "$origin"
  exit 0
}

# --- steps 1 to 3: the sources tree, the sources jar, the download -----------

# The tree is unpacked whole: one unzip costs what extracting a single file
# costs, and leaves the rest of the library open to grep.
unpack_sources() {
  [[ -f "$SRC_JAR" ]] || return 1
  rm -rf "$SRC_DIR" "$SRC_MARK"
  mkdir -p "$SRC_DIR" || return 1
  unzip -q -o -d "$SRC_DIR" "$SRC_JAR" >/dev/null 2>&1 || return 1
  : > "$SRC_MARK"
  return 0
}

serve_sources() {
  local ext
  for ext in java kt; do
    [[ -s "${SRC_DIR}/${CLASS_PATH}.${ext}" ]] && deliver "${SRC_DIR}/${CLASS_PATH}.${ext}" "$1"
  done
  return 1
}

if [[ $NOCACHE -eq 1 ]]; then
  rm -rf "$SRC_DIR" "$SRC_MARK"
  rm -f "${CACHE_DIR}/${FQN}.java" "${CACHE_DIR}/${FQN}.javap" "$ORIGIN_FILE"
fi

# An unpacked tree that does not hold the class is the answer that the sources
# jar does not hold it either. Unpacking it again to learn the same thing costs
# the whole unzip, and throws away the tree the caller was about to grep.
if [[ -f "$SRC_MARK" && ( ! -f "$SRC_JAR" || "$SRC_MARK" -nt "$SRC_JAR" ) ]]; then
  serve_sources "sources"
elif [[ -f "$SRC_JAR" ]]; then
  unpack_sources && serve_sources "sources"
elif mvn_get "${GROUP}:${ARTIFACT}:${VERSION}:jar:sources"; then
  unpack_sources && serve_sources "sources-downloaded"
fi

# --- everything below reads the binary jar -----------------------------------

if [[ ! -f "$JAR" ]]; then
  if ! mvn_get "${GROUP}:${ARTIFACT}:${VERSION}"; then
    err "maven-lib-source: no sources jar and no binary jar for ${GROUP}:${ARTIFACT}:${VERSION}."
    err "hint: with the network up, run: mvn dependency:get -Dartifact=${GROUP}:${ARTIFACT}:${VERSION}:jar:sources"
    exit 3
  fi
fi

if ! list_jar "$JAR" | grep -qx "${CLASS_PATH}.class"; then
  err "maven-lib-source: ${FQN} is not in ${GROUP}:${ARTIFACT}:${VERSION}."
  err "hint: find where it actually lives — maven-lib-source.sh find ${SIMPLE} --group-prefix ${GROUP}"
  exit 4
fi

# --- step 4: decompilation ---------------------------------------------------

CACHED_JAVA="${CACHE_DIR}/${FQN}.java"
if [[ -s "$CACHED_JAVA" && -r "$ORIGIN_FILE" ]]; then
  # A decompilation made by another version of the decompiler is not this one.
  [[ "$(cat "$ORIGIN_FILE")" == "$VF_ORIGIN" ]] && deliver "$CACHED_JAVA" "$VF_ORIGIN"
fi

VF_JAR="${M2}/org/vineflower/vineflower/${VF_VERSION}/vineflower-${VF_VERSION}.jar"

if [[ $HAVE_JAVA -eq 1 ]]; then
  [[ -f "$VF_JAR" ]] || mvn_get "$VF_GAV" >/dev/null 2>&1
  if [[ -f "$VF_JAR" ]]; then
    IN="${SCRATCH}/in"; OUT="${SCRATCH}/out"
    mkdir -p "$IN" "$OUT"
    # The nested classes come too: the decompiler folds them back into the file
    # of the class that encloses them.
    unzip -j -o "$JAR" "${CLASS_PATH}.class" "${CLASS_PATH}\$*.class" -d "$IN" >/dev/null 2>&1
    if [[ -f "${IN}/${SIMPLE}.class" ]]; then
      if ! java -jar "$VF_JAR" -dgs=true -e="$JAR" "$IN" "$OUT" >/dev/null 2>&1; then
        java -cp "$VF_JAR" org.jetbrains.java.decompiler.main.decompiler.ConsoleDecompiler \
          -dgs=true -e="$JAR" "$IN" "$OUT" >/dev/null 2>&1
      fi
      DECOMPILED=$(find "$OUT" -name "${SIMPLE}.java" -print -quit 2>/dev/null)
      if [[ -n "$DECOMPILED" && -s "$DECOMPILED" ]]; then
        mkdir -p "$CACHE_DIR" 2>/dev/null
        if cp "$DECOMPILED" "$CACHED_JAVA" 2>/dev/null; then
          printf '%s\n' "$VF_ORIGIN" > "$ORIGIN_FILE" 2>/dev/null
          deliver "$CACHED_JAVA" "$VF_ORIGIN"
        fi
        deliver "$DECOMPILED" "$VF_ORIGIN"
      fi
    fi
  fi
fi

# --- step 5: javap -----------------------------------------------------------

CACHED_JAVAP="${CACHE_DIR}/${FQN}.javap"
[[ -s "$CACHED_JAVAP" ]] && deliver "$CACHED_JAVAP" "javap"

if [[ $HAVE_JAVA -eq 1 ]] && need javap; then
  mkdir -p "$CACHE_DIR" 2>/dev/null
  if javap -p -cp "$JAR" "$FQN" > "$CACHED_JAVAP" 2>/dev/null && [[ -s "$CACHED_JAVAP" ]]; then
    printf '%s\n' "javap" > "$ORIGIN_FILE" 2>/dev/null
    deliver "$CACHED_JAVAP" "javap"
  fi
  rm -f "$CACHED_JAVAP"
fi

# --- nothing left ------------------------------------------------------------

err "maven-lib-source: could not produce the source of ${FQN} from ${GROUP}:${ARTIFACT}:${VERSION}."
if [[ $OFFLINE -eq 1 || $HAVE_MVN -eq 0 ]]; then
  err "hint: nothing was downloadable on this run. With the network up:"
  err "  mvn dependency:get -Dartifact=${GROUP}:${ARTIFACT}:${VERSION}:jar:sources"
  err "  mvn dependency:get -Dartifact=${VF_GAV}"
fi
if [[ -r "$POM" ]]; then
  SCM=$(tr -d '\n' < "$POM" | sed -n 's:.*<scm>.*<url>[[:space:]]*\([^<]*\)[[:space:]]*</url>.*</scm>.*:\1:p' | head -1)
  [[ -n "$SCM" ]] && err "The pom points upstream at: ${SCM}"
fi
exit 7
