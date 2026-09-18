#!/usr/bin/env bash
# The tests of the maven-lib-source skill: builds a Maven repository of its own
# out of javac and jar, points the script at it, and checks what comes back.
#
# It runs on its own — `tests/lib-source/run.sh` — and from `tests/run.sh`,
# which calls it as one of its jobs and folds the verdict below into its own
# count. Nothing here reaches the network: every case passes --offline, so what
# is checked is the part that has to hold on any machine. The download of a
# sources jar, the decompiler and --from-project need the network, a 1.8 MB jar
# and Maven, and are not exercised here.
#
# The repository, the cache and the unpacked sources all live under one
# temporary directory, HOME included, so a run writes nothing a person owns.
#
# Exit codes: 0 — every check passed, or the run was skipped for want of a JDK;
#             2 — a check failed.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$SCRIPT_DIR/../.."

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sdd-lib-source.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd)" || exit 1
cleanup() { [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

# The script under test writes a cache under $HOME and a sources tree under
# $TMPDIR. Both are moved here, so the run leaves the machine as it found it.
export HOME="$TMP/home"
mkdir -p "$HOME" || exit 1

PASSED=0
FAILED=0
pass() { PASSED=$(( PASSED + 1 )); }
fail() { FAILED=$(( FAILED + 1 )); }

prop_check() {
  local group="$1" label="$2" ok="$3" why="$4"
  if (( ok == 0 )); then
    pass
  else
    fail
    printf '  FAILED   %s %s — %s\n' "$group" "$label" "$why"
  fi
}

# The reader of a class in a Maven artifact. Its subject is a local repository,
# so the fixture is one: two artifacts built here with javac and jar, and
# MAVEN_REPO_LOCAL pointed at them. Every case runs --offline, so nothing
# reaches the network and nothing depends on what the machine happens to have
# cached — what is checked is the part that has to hold anywhere: which of the
# four sources answered, what the index of a class holds and what it must not,
# where a method is cut, and which exit code a wrong call gets. The download of
# a sources jar, the decompiler and --from-project need the network, a 1.8 MB
# jar and Maven, so they are not here.
# Whether a run's --json output parses. A parser is not a dependency of the
# engine, so where python3 is missing this passes and the grep assertions beside
# it carry the case on their own.
libsrc_json_valid() {
  command -v python3 >/dev/null 2>&1 || return 0
  printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1
}

libsrc_run() {
  out="$(MAVEN_REPO_LOCAL="$LIBSRC_REPO" TMPDIR="$LIBSRC_TMP" "$LIBSRC" "$@" 2>"$LIBSRC_ERR")"
  rc=$?
  err="$(cat "$LIBSRC_ERR")"
}

check_lib_source() {
  local work="$TMP/lib-source" src="$TMP/lib-source/src" src2="$TMP/lib-source/src2"
  local out rc err ok want bad n spilled
  LIBSRC="$ENGINE/.sdd/skills/maven-lib-source/scripts/maven-lib-source.sh"
  LIBSRC_REPO="$work/m2"
  LIBSRC_TMP="$work/tmp"
  LIBSRC_ERR="$work/err.txt"

  printf 'lib-source\n'

  if ! command -v javac >/dev/null 2>&1 || ! command -v jar >/dev/null 2>&1 \
     || ! command -v javap >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
    printf '  skipped  needs javac, jar, javap and unzip on PATH\n'
    return 0
  fi

  rm -rf "$work" || exit 1
  mkdir -p "$src/com/example/other" "$src2/com/example" "$LIBSRC_TMP" \
           "$LIBSRC_REPO/com/example/demo/1.0.0" "$LIBSRC_REPO/com/example/demo/0.9.0" \
           "$LIBSRC_REPO/com/example/quiet/2.0.0" || exit 1

  # Every shape the readers have to survive is in this one class: javadoc and an
  # annotation above a method, two overloads, a throws clause over three lines,
  # a nested class, and four lines that look like declarations and are not.
  cat > "$src/com/example/Demo.java" <<'EOF'
package com.example;

/** A class the tests read. */
public class Demo {

    private final String name;

    /**
     * Makes one.
     *
     * @param name what to call it
     */
    public Demo(String name) {
        this.name = name;
    }

    /** Gives the name back. */
    @Deprecated
    public String getName() {
        return (name);
    }

    public String join(String other) {
        return join(other, ", ");
    }

    public String join(String other, String sep)
            throws IllegalStateException,
            IllegalArgumentException {
        if (other == null) {
            throw new IllegalArgumentException("no");
        }
        String s = String.valueOf(sep);
        s.trim();
        return name + s + other;
    }

    void helper() {
    }

    public static class Inner {
        public int size() {
            return 0;
        }
    }
}
EOF

  cat > "$src/com/example/Status.java" <<'EOF'
package com.example;

/** Two states. */
public enum Status {

    OPEN,
    CLOSED;

    public boolean isOpen() {
        return this == OPEN;
    }
}
EOF

  # A class that is nothing but fields, which is what a DTO and a holder of
  # constants are, plus the three places a declaration can hide: a method body,
  # an initialiser block, and the body of an anonymous class.
  cat > "$src/com/example/Fields.java" <<'EOF'
package com.example;

public final class Fields {

    public static final String NAME = "name";
    static final int MAX = 10;
    private final java.util.List<String> items;
    protected String label, other;
    int[] sizes;

    static final Runnable HOOK = new Runnable() {
        public void run() {
            int anonLocal = 1;
        }

        public void anonMember() {
        }
    };

    static {
        int blockLocal = 2;
    }

    public Fields() {
        this.items = null;
        String methodLocal = "not a field";
        class MethodClass {
            int methodClassMember() {
                return 0;
            }
        }
    }
}
EOF

  # Enum constants that the shape of the name alone would not find: one letter,
  # mixed case, and a list whose semicolon is on a line of its own.
  cat > "$src/com/example/Grade.java" <<'EOF'
package com.example;

public enum Grade {

    A,
    Bee,
    cee
    ;

    public boolean top() {
        return this == A;
    }
}
EOF

  cat > "$src/com/example/SuffixDemo.java" <<'EOF'
package com.example;

public class SuffixDemo {
}
EOF

  cat > "$src/com/example/Twin.java" <<'EOF'
package com.example;

public class Twin {
}
EOF

  cat > "$src/com/example/other/Twin.java" <<'EOF'
package com.example.other;

public class Twin {
}
EOF

  cat > "$src2/com/example/Quiet.java" <<'EOF'
package com.example;

public class Quiet {
    public int answer() {
        return 42;
    }
}
EOF

  javac -nowarn -d "$work/classes" $(find "$src" -name '*.java') 2>/dev/null || {
    printf '  skipped  javac could not build the fixture\n'; return 0; }
  javac -nowarn -d "$work/classes2" "$src2/com/example/Quiet.java" 2>/dev/null || {
    printf '  skipped  javac could not build the fixture\n'; return 0; }
  ( cd "$work/classes"  && jar cf "$LIBSRC_REPO/com/example/demo/1.0.0/demo-1.0.0.jar" . ) || exit 1
  ( cd "$src"           && jar cf "$LIBSRC_REPO/com/example/demo/1.0.0/demo-1.0.0-sources.jar" . ) || exit 1
  ( cd "$work/classes2" && jar cf "$LIBSRC_REPO/com/example/quiet/2.0.0/quiet-2.0.0.jar" . ) || exit 1

  # A second version of the same artifact. The repository holds many of these,
  # and a search that reported each of them separately reported one class
  # twenty times and then refused to read any of them.
  cp "$LIBSRC_REPO/com/example/demo/1.0.0/demo-1.0.0.jar" \
     "$LIBSRC_REPO/com/example/demo/0.9.0/demo-0.9.0.jar" || exit 1

  # An artifact whose sources jar carries one of its classes and not the other.
  # Reading the one it does not carry must not cost the whole jar being unpacked
  # again, every time, to learn that it is still not there.
  mkdir -p "$LIBSRC_REPO/com/example/partial/1.0.0" \
           "$work/partialsrc/com/example" "$work/partialpub/com/example" || exit 1
  cat > "$work/partialsrc/com/example/Whole.java" <<'EOF'
package com.example;

public class Whole {
    public int whole() {
        return 1;
    }
}
EOF
  cat > "$work/partialsrc/com/example/Half.java" <<'EOF'
package com.example;

public class Half {
    public int half() {
        return 2;
    }
}
EOF
  javac -nowarn -d "$work/partialcls" "$work/partialsrc/com/example/"*.java 2>/dev/null || {
    printf '  skipped  javac could not build the fixture\n'; return 0; }
  cp "$work/partialsrc/com/example/Whole.java" "$work/partialpub/com/example/" || exit 1
  ( cd "$work/partialcls" && jar cf "$LIBSRC_REPO/com/example/partial/1.0.0/partial-1.0.0.jar" . ) || exit 1
  ( cd "$work/partialpub" && jar cf "$LIBSRC_REPO/com/example/partial/1.0.0/partial-1.0.0-sources.jar" . ) || exit 1

  # A sources jar answers, and the file it names is the unpacked tree.
  libsrc_run com.example demo 1.0.0 com.example.Demo --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^source: sources$' || ok=1
  printf '%s\n' "$out" | grep -q '^file: .*/sources/com/example/Demo\.java$' || ok=1
  printf '%s\n' "$out" | grep -q '^lines: [0-9]' || ok=1
  prop_check lib-source "sources" "$ok" \
    "expected a sources answer naming the unpacked file; exit=$rc, got: $(printf '%s' "$out" | head -4 | tr '\n' '|')"

  # The index carries every declaration the class makes, nested class included.
  ok=0
  for want in 'public class Demo' 'public Demo(String name)' 'public String getName()' \
              'public String join(String other)' 'public String join(String other, String sep)' \
              'void helper()' 'public static class Inner' 'public int size()'; do
    printf '%s\n' "$out" | grep -qF "  $want" || { ok=1; bad="$want"; }
  done
  prop_check lib-source "index holds declarations" "$ok" "the index is missing: ${bad:-<none>}"

  # And nothing that only looks like one: a return, a condition, a call on a
  # field, a call on the right of an assignment.
  ok=0
  for bad in 'return (name)' 'if (other == null)' 's.trim()' 'String.valueOf'; do
    printf '%s\n' "$out" | grep -qF "$bad" && { ok=1; want="$bad"; }
  done
  prop_check lib-source "index excludes statements" "$ok" "the index carries a statement: ${want:-<none>}"

  # Both overloads, and a throws clause that runs over three lines.
  libsrc_run com.example demo 1.0.0 com.example.Demo --method join --offline
  n="$(printf '%s\n' "$out" | grep -c 'public String join')"
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  [[ "${n:-0}" == "2" ]] || ok=1
  printf '%s\n' "$out" | grep -q 'IllegalArgumentException {' || ok=1
  prop_check lib-source "overloads" "$ok" \
    "expected two overloads and a multi-line throws; exit=$rc, matches=${n:-0}"

  # The javadoc and the annotations above a method come with it.
  libsrc_run com.example demo 1.0.0 com.example.Demo --method getName --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q 'Gives the name back' || ok=1
  printf '%s\n' "$out" | grep -q '@Deprecated' || ok=1
  prop_check lib-source "javadoc and annotation" "$ok" \
    "expected the javadoc and @Deprecated above getName; exit=$rc"

  # A constructor is a method named after its class.
  libsrc_run com.example demo 1.0.0 com.example.Demo --method Demo --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q 'public Demo(String name)' || ok=1
  prop_check lib-source "constructor" "$ok" "expected the constructor; exit=$rc"

  # A name that is not there is exit 6, and says what to do instead.
  libsrc_run com.example demo 1.0.0 com.example.Demo --method nosuch --offline
  ok=0
  [[ $rc -eq 6 ]] || ok=1
  printf '%s\n' "$err" | grep -q '^hint: ' || ok=1
  prop_check lib-source "no such method" "$ok" "expected exit 6 and a hint; exit=$rc"

  # A simple name that is in one package resolves; one that is in two does not,
  # and the candidates are printed rather than guessed between.
  libsrc_run com.example demo 1.0.0 Status --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^class: com\.example\.Status$' || ok=1
  prop_check lib-source "simple name" "$ok" "expected com.example.Status; exit=$rc"

  libsrc_run com.example demo 1.0.0 Twin --offline
  ok=0
  [[ $rc -eq 5 ]] || ok=1
  printf '%s\n' "$err" | grep -q 'com\.example\.Twin' || ok=1
  printf '%s\n' "$err" | grep -q 'com\.example\.other\.Twin' || ok=1
  prop_check lib-source "ambiguous name" "$ok" "expected exit 5 and both candidates; exit=$rc"

  # An enum's constants are what is usually being asked for, so they are indexed.
  libsrc_run com.example demo 1.0.0 com.example.Status --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  for want in 'public enum Status' 'OPEN' 'CLOSED' 'public boolean isOpen()'; do
    printf '%s\n' "$out" | grep -qF "  $want" || { ok=1; bad="$want"; }
  done
  prop_check lib-source "enum constants" "$ok" "the index is missing: ${bad:-<none>}; exit=$rc"

  # No sources jar, no decompiler, no network: signatures, printed rather than
  # pointed at, and labelled as signatures.
  libsrc_run com.example quiet 2.0.0 com.example.Quiet --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^source: javap$' || ok=1
  printf '%s\n' "$out" | grep -q '^warning: signatures only' || ok=1
  printf '%s\n' "$out" | grep -q 'public int answer()' || ok=1
  prop_check lib-source "javap fallback" "$ok" \
    "expected a javap answer carrying the signature; exit=$rc"

  # A class the artifact does not hold, and a version the repository does not.
  libsrc_run com.example demo 1.0.0 com.example.Nope --offline
  ok=0
  [[ $rc -eq 4 ]] || ok=1
  prop_check lib-source "no such class" "$ok" "expected exit 4; exit=$rc"

  libsrc_run com.example demo 9.9.9 com.example.Demo --offline
  ok=0
  [[ $rc -eq 3 ]] || ok=1
  printf '%s\n' "$err" | grep -q '0\.9\.0' || ok=1
  printf '%s\n' "$err" | grep -q '1\.0\.0' || ok=1
  prop_check lib-source "wrong version" "$ok" \
    "expected exit 3 and the versions that are on disk; exit=$rc"

  # A search matches a whole name. SuffixDemo is not Demo, and the two Twins are
  # two answers rather than a choice made for the caller.
  libsrc_run find Demo --group-prefix com.example
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^artifact: com\.example:demo:1\.0\.0$' || ok=1
  printf '%s\n' "$out" | grep -q '^class: com\.example\.Demo$' || ok=1
  printf '%s\n' "$out" | grep -q 'SuffixDemo' && ok=1
  prop_check lib-source "find matches a whole name" "$ok" \
    "expected one hit and no SuffixDemo; exit=$rc, got: $(printf '%s' "$out" | tr '\n' '|')"

  libsrc_run find Twin --group-prefix com.example
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^found: 2$' || ok=1
  prop_check lib-source "find reports every hit" "$ok" "expected two hits; exit=$rc"

  # A scan and a lookup in the index answer the same thing.
  libsrc_run find Twin --group-prefix com.example
  want="$out"
  libsrc_run index com.example
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  libsrc_run find Twin --group-prefix com.example
  [[ "$out" == "$want" ]] || ok=1
  prop_check lib-source "index answers as a scan does" "$ok" \
    "the index gave a different answer than the scan"

  # One hit is read, not merely reported: the search answers the question it was
  # a step towards, and the two calls it used to take become one.
  # One hit is the class itself and nothing above it: the read already names the
  # artifact, so a list of one would say the same thing twice.
  libsrc_run find Demo --group-prefix com.example --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^found: ' && ok=1
  printf '%s\n' "$out" | grep -q '^artifact: com\.example:demo:1\.0\.0$' || ok=1
  printf '%s\n' "$out" | grep -q '^file: .*/sources/com/example/Demo\.java$' || ok=1
  printf '%s\n' "$out" | grep -qF '  public String getName()' || ok=1
  prop_check lib-source "a search reads its one hit" "$ok" \
    "expected the class alone; exit=$rc, got: $(printf '%s' "$out" | tr '\n' '|')"

  # Two hits are a choice for the caller, so nothing is read.
  libsrc_run find Twin --group-prefix com.example --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^found: 2$' || ok=1
  printf '%s\n' "$out" | grep -q '^file: ' && ok=1
  printf '%s\n' "$out" | grep -q '^hint: read one of them' || ok=1
  prop_check lib-source "a search reads no ambiguous hit" "$ok" \
    "expected two hits, a hint and no read; exit=$rc"

  # --list stops at the list.
  libsrc_run find Demo --group-prefix com.example --offline --list
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^found: 1$' || ok=1
  printf '%s\n' "$out" | grep -q '^artifact: ' && ok=1
  prop_check lib-source "--list" "$ok" "expected the list alone; exit=$rc"

  # An option about what to print reaches the read the search does.
  libsrc_run find Demo --group-prefix com.example --offline --method getName
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^method: getName$' || ok=1
  printf '%s\n' "$out" | grep -q 'Gives the name back' || ok=1
  prop_check lib-source "a search passes --method on" "$ok" \
    "expected getName cut out of the hit; exit=$rc"

  # Several names cost one scan and come back as several blocks.
  libsrc_run find Demo Status --group-prefix com.example --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^class: com\.example\.Demo$' || ok=1
  printf '%s\n' "$out" | grep -q '^class: com\.example\.Status$' || ok=1
  n="$(printf '%s\n' "$out" | grep -c '^artifact: com\.example:demo:1\.0\.0$')"
  [[ "${n:-0}" == "2" ]] || ok=1
  prop_check lib-source "a search takes several names" "$ok" \
    "expected both names found and read; exit=$rc, blocks=${n:-0}"

  # One name of several missing is reported without costing the others.
  libsrc_run find Demo Nowhere --group-prefix com.example --offline
  ok=0
  [[ $rc -eq 4 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^class: com\.example\.Demo$' || ok=1
  printf '%s\n' "$err" | grep -q 'Nowhere' || ok=1
  prop_check lib-source "a search reports the name it missed" "$ok" \
    "expected exit 4, Demo read and Nowhere named; exit=$rc"

  # --method is repeatable: two methods of one class in one call, each labelled.
  libsrc_run com.example demo 1.0.0 com.example.Demo --method getName --method helper --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^method: getName, helper$' || ok=1
  printf '%s\n' "$out" | grep -q '^// getName$' || ok=1
  printf '%s\n' "$out" | grep -q '^// helper$' || ok=1
  printf '%s\n' "$out" | grep -q 'public String getName()' || ok=1
  printf '%s\n' "$out" | grep -q 'void helper()' || ok=1
  prop_check lib-source "several methods" "$ok" \
    "expected both methods, each labelled; exit=$rc, got: $(printf '%s' "$out" | tr '\n' '|')"

  # A name that is not there does not cost the ones that are.
  libsrc_run com.example demo 1.0.0 com.example.Demo --method getName --method nosuch --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q 'public String getName()' || ok=1
  printf '%s\n' "$err" | grep -q 'nosuch' || ok=1
  prop_check lib-source "several methods, one missing" "$ok" \
    "expected getName returned and nosuch named on stderr; exit=$rc"

  # A class in no index and with nothing to narrow the search is not a licence
  # to walk the whole repository.
  libsrc_run find Nowhere
  ok=0
  [[ $rc -eq 4 ]] || ok=1
  printf '%s\n' "$err" | grep -q '^hint: ' || ok=1
  prop_check lib-source "find refuses to guess" "$ok" "expected exit 4 and a hint; exit=$rc"

  # A guessed package is the common way a fully qualified name misses, and the
  # class it names is usually there one package over. The simple name is tried
  # before the miss is reported, so the caller gets the class rather than a dead
  # end — and is told on stderr that what came back is not what was asked for.
  libsrc_run find com.guessed.Demo --group-prefix com.example --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^class: com\.example\.Demo$' || ok=1
  printf '%s\n' "$err" | grep -q 'com\.guessed\.Demo' || ok=1
  prop_check lib-source "a guessed package still finds the class" "$ok" \
    "expected com.example.Demo read and the asked name named on stderr; exit=$rc"

  # Where the simple name is ambiguous the fallback lists rather than picks, and
  # the list is headed by the name that actually matched.
  libsrc_run find com.guessed.Twin --group-prefix com.example --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^class: Twin$' || ok=1
  printf '%s\n' "$out" | grep -q '^found: 2$' || ok=1
  prop_check lib-source "a guessed package with two hits lists them" "$ok" \
    "expected the two Twin hits under the simple name; exit=$rc"

  # A class that is nowhere stays a miss: the fallback answers a wrong package,
  # not a wrong class.
  libsrc_run find com.guessed.Nowhere --group-prefix com.example --offline
  ok=0
  [[ $rc -eq 4 ]] || ok=1
  printf '%s\n' "$err" | grep -q 'no class matching com\.guessed\.Nowhere' || ok=1
  prop_check lib-source "the fallback does not invent a hit" "$ok" \
    "expected exit 4 for a name nothing is called; exit=$rc"

  # A long answer is filed and its head returned, so a reader pays for the head
  # and fetches the rest only if it needs it. --spill always forces the path a
  # long answer takes, whatever the threshold is.
  libsrc_run find Demo --group-prefix com.example --offline --spill always
  ok=0
  spilled="$(printf '%s\n' "$out" | sed -n 's/^answer: [0-9]* lines, the first [0-9]* above\. file: //p')"
  [[ $rc -eq 0 ]] || ok=1
  [[ -n "$spilled" && -s "$spilled" ]] || ok=1
  printf '%s\n' "$out" | grep -q '^hint: read the rest of it' || ok=1
  grep -q '^artifact: com\.example:demo:1\.0\.0$' "$spilled" 2>/dev/null || ok=1
  prop_check lib-source "a long answer comes back as a file" "$ok" \
    "expected a head, an answer line and a file holding the whole answer; exit=$rc, file=${spilled:-none}"

  # The same call twice writes the same file rather than a new one each time.
  libsrc_run find Demo --group-prefix com.example --offline --spill always
  ok=0
  [[ "$(printf '%s\n' "$out" | sed -n 's/^answer: [0-9]* lines, the first [0-9]* above\. file: //p')" == "$spilled" ]] || ok=1
  prop_check lib-source "the same call spills to the same file" "$ok" \
    "expected the path of the first run back"

  # --spill never is the old behaviour: everything on stdout, however long.
  libsrc_run com.example demo 1.0.0 com.example.Demo --offline --print --spill never
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^package com\.example;$' || ok=1
  printf '%s\n' "$out" | grep -q '^answer: ' && ok=1
  prop_check lib-source "--spill never" "$ok" "expected the whole text and no answer line; exit=$rc"

  # Filing the answer does not swallow what the run was going to exit with.
  libsrc_run find Demo Nowhere --group-prefix com.example --offline --spill always
  ok=0
  [[ $rc -eq 4 ]] || ok=1
  prop_check lib-source "a spilled answer keeps its exit code" "$ok" "expected exit 4; exit=$rc"

  # A mode this does not have is a usage error, not a silent default.
  libsrc_run find Demo --group-prefix com.example --offline --spill sometimes
  ok=0
  [[ $rc -eq 2 ]] || ok=1
  prop_check lib-source "--spill takes three values" "$ok" "expected exit 2; exit=$rc"

  # --print puts the class where the path would have been.
  libsrc_run com.example demo 1.0.0 com.example.Demo --offline --print
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^package com\.example;$' || ok=1
  printf '%s\n' "$out" | grep -q '^file: ' && ok=1
  prop_check lib-source "--print" "$ok" "expected the class text and no file line; exit=$rc"

  # --out puts the file where a caller can read it.
  libsrc_run com.example demo 1.0.0 com.example.Demo --offline --out "$work/handed"
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q "^file: $work/handed/Demo\.java$" || ok=1
  [[ -s "$work/handed/Demo.java" ]] || ok=1
  prop_check lib-source "--out" "$ok" "expected the file under $work/handed; exit=$rc"

  # --no-cache is a rebuild, not a refusal to answer.
  libsrc_run com.example demo 1.0.0 com.example.Demo --offline --no-cache
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^source: sources$' || ok=1
  prop_check lib-source "--no-cache" "$ok" "expected a rebuilt sources answer; exit=$rc"

  # The arity of a read call says whether the version is given or resolved, and
  # the two cannot both be true.
  libsrc_run com.example demo com.example.Demo --offline
  ok=0; [[ $rc -eq 2 ]] || ok=1
  prop_check lib-source "three arguments without --from-project" "$ok" "expected exit 2; exit=$rc"

  libsrc_run com.example demo 1.0.0 com.example.Demo --from-project "$work" --offline
  ok=0; [[ $rc -eq 2 ]] || ok=1
  prop_check lib-source "four arguments with --from-project" "$ok" "expected exit 2; exit=$rc"

  libsrc_run com.example demo 1.0.0 com.example.Demo --nonsense
  ok=0; [[ $rc -eq 2 ]] || ok=1
  prop_check lib-source "unknown option" "$ok" "expected exit 2; exit=$rc"

  # Two artifacts that are a sources jar and nothing else. A read by fully
  # qualified name never opens the binary jar, so these need no compiler — which
  # is the point: a record and a sealed interface would otherwise tie the suite
  # to the JDK that happens to be installed, and Kotlin to a compiler that is
  # not there at all.
  mkdir -p "$work/ktsrc/com/example" "$work/shapesrc/com/example" \
           "$LIBSRC_REPO/com/example/kt/1.0.0" "$LIBSRC_REPO/com/example/shapes/1.0.0" || exit 1

  cat > "$work/ktsrc/com/example/Kt.kt" <<'EOF'
package com.example

class Kt {
    fun answer(): Int = 42
}
EOF

  cat > "$work/shapesrc/com/example/Shape.java" <<'EOF'
package com.example;

/** Shapes. */
public sealed interface Shape permits Shape.Circle, Shape.Square {

    double area();

    record Circle(double radius) implements Shape {
        public double area() {
            return 3.14 * radius * radius;
        }
    }

    record Square(double side) implements Shape {
        public double area() {
            return side * side;
        }
    }

    @interface Marker {
    }
}
EOF

  # A text block holds braces, quotes and slashes that are not code. It needs a
  # JDK of 15 or later to compile, which is exactly why it is here.
  cat > "$work/shapesrc/com/example/Text.java" <<'EOF'
package com.example;

public class Text {

    static final String Q = """
            unbalanced {{{ "quoted" // not a comment
            """;

    public int after() {
        return 1;
    }
}
EOF

  ( cd "$work/ktsrc"     && jar cf "$LIBSRC_REPO/com/example/kt/1.0.0/kt-1.0.0-sources.jar" . ) || exit 1
  ( cd "$work/shapesrc"  && jar cf "$LIBSRC_REPO/com/example/shapes/1.0.0/shapes-1.0.0-sources.jar" . ) || exit 1

  # A nested class is read through the class that encloses it, whichever way it
  # is spelled.
  for want in 'com.example.Demo$Inner' 'Demo$Inner'; do
    libsrc_run com.example demo 1.0.0 "$want" --offline
    ok=0
    [[ $rc -eq 0 ]] || ok=1
    printf '%s\n' "$out" | grep -q '^class: com\.example\.Demo$' || ok=1
    printf '%s\n' "$out" | grep -qF '  public static class Inner' || ok=1
    prop_check lib-source "nested class as $want" "$ok" \
      "expected the enclosing class and its index; exit=$rc"
  done

  # A sources jar that holds Kotlin is still the source of that class.
  libsrc_run com.example kt 1.0.0 com.example.Kt --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^source: sources$' || ok=1
  printf '%s\n' "$out" | grep -q '^file: .*/sources/com/example/Kt\.kt$' || ok=1
  prop_check lib-source "kotlin source" "$ok" "expected the .kt file; exit=$rc"

  # The declarations Java has grown since classes and interfaces.
  libsrc_run com.example shapes 1.0.0 com.example.Shape --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  for want in 'public sealed interface Shape permits Shape.Circle, Shape.Square' \
              'double area()' 'record Circle(double radius) implements Shape' \
              'record Square(double side) implements Shape' '@interface Marker'; do
    printf '%s\n' "$out" | grep -qF "  $want" || { ok=1; bad="$want"; }
  done
  prop_check lib-source "record, sealed and @interface" "$ok" \
    "the index is missing: ${bad:-<none>}; exit=$rc"

  # javap answers --method too, by the signature rather than by the body.
  libsrc_run com.example quiet 2.0.0 com.example.Quiet --method answer --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^source: javap$' || ok=1
  printf '%s\n' "$out" | grep -q 'int answer()' || ok=1
  prop_check lib-source "javap and --method" "$ok" "expected the signature; exit=$rc"

  libsrc_run com.example quiet 2.0.0 com.example.Quiet --method nosuch --offline
  ok=0; [[ $rc -eq 6 ]] || ok=1
  prop_check lib-source "javap and a missing method" "$ok" "expected exit 6; exit=$rc"

  # --json is one object on one line in all three of its shapes. One line is the
  # assertion that matters: the escaping is hand-written, and a class body that
  # leaked its newlines through would break every reader of it.
  libsrc_run com.example demo 1.0.0 com.example.Demo --offline --json
  n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  [[ "${n:-0}" == "1" ]] || ok=1
  printf '%s' "$out" | grep -q '"source":"sources"' || ok=1
  printf '%s' "$out" | grep -q '"file":"[^"]*Demo\.java"' || ok=1
  printf '%s' "$out" | grep -q '"lines":[0-9]' || ok=1
  printf '%s' "$out" | grep -q '"index":"' || ok=1
  libsrc_json_valid "$out" || ok=1
  prop_check lib-source "--json for a class" "$ok" \
    "expected one valid object carrying file, lines and index; exit=$rc, lines=${n:-0}"

  libsrc_run com.example demo 1.0.0 com.example.Demo --method join --offline --json
  n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  [[ "${n:-0}" == "1" ]] || ok=1
  printf '%s' "$out" | grep -q '"method":"join"' || ok=1
  printf '%s' "$out" | grep -q '"body":"' || ok=1
  printf '%s' "$out" | grep -q '\\n' || ok=1
  libsrc_json_valid "$out" || ok=1
  prop_check lib-source "--json for a method" "$ok" \
    "expected one valid object whose body carries escaped newlines; exit=$rc, lines=${n:-0}"

  libsrc_run find Twin --group-prefix com.example --json
  n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  [[ "${n:-0}" == "1" ]] || ok=1
  printf '%s' "$out" | grep -q '"found":2' || ok=1
  printf '%s' "$out" | grep -q '"hits":\[' || ok=1
  libsrc_json_valid "$out" || ok=1
  prop_check lib-source "--json for a search" "$ok" \
    "expected one valid object carrying two hits; exit=$rc, lines=${n:-0}"

  # A class that is nothing but fields is the common shape of a DTO and of a
  # holder of constants, and an index without them answered it with its own name.
  libsrc_run com.example demo 1.0.0 com.example.Fields --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  for want in 'public static final String NAME' 'static final int MAX' \
              'private final java.util.List<String> items' \
              'protected String label, other' 'int[] sizes' \
              'static final Runnable HOOK' 'public Fields()'; do
    printf '%s\n' "$out" | grep -qF "  $want" || { ok=1; bad="$want"; }
  done
  prop_check lib-source "index holds fields" "$ok" "the index is missing: ${bad:-<none>}; exit=$rc"

  # And nothing a body holds: a local variable, a local class, a member of an
  # anonymous one, a variable of an initialiser block.
  ok=0
  for bad in 'methodLocal' 'anonLocal' 'blockLocal' 'MethodClass' \
             'methodClassMember' 'anonMember' 'public void run()'; do
    printf '%s\n' "$out" | grep -qF "$bad" && { ok=1; want="$bad"; }
  done
  prop_check lib-source "index excludes bodies" "$ok" \
    "the index reaches inside a body: ${want:-<none>}"

  # Which body is an enum's is remembered, not guessed from the shape of the
  # name, so a one-letter constant and a mixed-case one are as visible as a
  # shouted one, and the semicolon may stand on a line of its own.
  libsrc_run com.example demo 1.0.0 com.example.Grade --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  for want in 'public enum Grade' 'A' 'Bee' 'cee' 'public boolean top()'; do
    printf '%s\n' "$out" | grep -qF "  $want" || { ok=1; bad="$want"; }
  done
  prop_check lib-source "enum constants of any shape" "$ok" \
    "the index is missing: ${bad:-<none>}; exit=$rc"

  # A text block is text: its braces, quotes and slashes are not code, and a
  # reader that counted them lost every declaration after it.
  libsrc_run com.example shapes 1.0.0 com.example.Text --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  for want in 'public class Text' 'static final String Q' 'public int after()'; do
    printf '%s\n' "$out" | grep -qF "  $want" || { ok=1; bad="$want"; }
  done
  prop_check lib-source "a text block is not code" "$ok" \
    "the index is missing: ${bad:-<none>}; exit=$rc"

  # --members keeps the part of a fat class that was asked about, and says how
  # much it dropped, so nothing reads as a class that declares nothing.
  libsrc_run com.example demo 1.0.0 com.example.Demo --offline --members join
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^index: 2 of [0-9]* declarations matching join$' || ok=1
  printf '%s\n' "$out" | grep -qF '  public String join(String other)' || ok=1
  printf '%s\n' "$out" | grep -qF 'getName' && ok=1
  prop_check lib-source "--members" "$ok" \
    "expected the two joins and the count; exit=$rc, got: $(printf '%s' "$out" | tr '\n' '|')"

  libsrc_run com.example demo 1.0.0 com.example.Demo --offline --members zzzz
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^index: 0 of [0-9]* declarations matching zzzz$' || ok=1
  printf '%s\n' "$err" | grep -q 'matches zzzz' || ok=1
  prop_check lib-source "--members that matches nothing" "$ok" \
    "expected a count of zero and a word about it; exit=$rc"

  # The same name asked for twice is one method, not two.
  libsrc_run com.example demo 1.0.0 com.example.Demo --method getName --method getName --offline
  n="$(printf '%s\n' "$out" | grep -c 'public String getName()')"
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^method: getName$' || ok=1
  [[ "${n:-0}" == "1" ]] || ok=1
  prop_check lib-source "a method named twice is cut once" "$ok" \
    "expected one cut; exit=$rc, matches=${n:-0}"

  # Versions of one artifact are one answer. Twenty of them in the repository
  # were twenty hits, which is a list to choose from rather than a class read.
  libsrc_run find Demo --group-prefix com.example --offline --no-cache
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^artifact: com\.example:demo:1\.0\.0$' || ok=1
  printf '%s\n' "$out" | grep -q '0\.9\.0' && ok=1
  printf '%s\n' "$err" | grep -q '2 versions' || ok=1
  prop_check lib-source "versions collapse to the newest" "$ok" \
    "expected 1.0.0 read and 0.9.0 counted, not listed; exit=$rc"

  # A single hit under --json is the read, as it is without it.
  libsrc_run find Status --group-prefix com.example --offline --json
  n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  [[ "${n:-0}" == "1" ]] || ok=1
  printf '%s' "$out" | grep -q '"class":"com\.example\.Status"' || ok=1
  printf '%s' "$out" | grep -q '"file":"' || ok=1
  libsrc_json_valid "$out" || ok=1
  prop_check lib-source "--json reads its one hit" "$ok" \
    "expected one valid object carrying the file; exit=$rc, lines=${n:-0}"

  # An unpacked tree that does not hold the class is the answer that the jar
  # does not hold it either. Unpacking it again to learn the same thing cost the
  # whole unzip and threw away the tree the caller was about to grep.
  libsrc_run com.example partial 1.0.0 com.example.Whole --offline
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^source: sources$' || ok=1
  PTREE="$LIBSRC_TMP/maven-lib-source/com.example/partial/1.0.0/sources"
  [[ -d "$PTREE" ]] || ok=1
  : > "$PTREE/canary" 2>/dev/null
  libsrc_run com.example partial 1.0.0 com.example.Half --offline
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^source: javap$' || ok=1
  [[ -f "$PTREE/canary" ]] || ok=1
  libsrc_run com.example partial 1.0.0 com.example.Half --offline
  [[ -f "$PTREE/canary" ]] || ok=1
  prop_check lib-source "the sources tree is unpacked once" "$ok" \
    "expected the tree to survive a class the sources jar does not carry; exit=$rc"

  # An artifact that ships sources and no binary jar still holds classes.
  libsrc_run find Kt --group-prefix com.example --offline --refresh
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -q '^artifact: com\.example:kt:1\.0\.0$' || ok=1
  printf '%s\n' "$out" | grep -q '^file: .*/sources/com/example/Kt\.kt$' || ok=1
  prop_check lib-source "find reaches a sources-only artifact" "$ok" \
    "expected the class from the sources jar; exit=$rc, got: $(printf '%s' "$out" | tr '\n' '|')"

  # javac's own parser answers where there is one, and it is not guessing from
  # the shape of the text: a signature that runs over three lines comes back
  # whole, which is the one thing the reader below it cannot do.
  libsrc_run com.example demo 1.0.0 com.example.Demo --offline --no-cache
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -qF '  public String join(String other, String sep) throws IllegalStateException, IllegalArgumentException' || ok=1
  prop_check lib-source "the parser reads a whole signature" "$ok" \
    "expected the throws clause in the index; exit=$rc"

  # And where there is none — no JDK, or Kotlin — the text reader answers, with
  # the same declarations in the same order.
  want="$(printf '%s\n' "$out" | sed -n '/^index:/,$p')"
  out="$(MAVEN_REPO_LOCAL="$LIBSRC_REPO" TMPDIR="$LIBSRC_TMP" MAVEN_LIB_SOURCE_READER=text \
         "$LIBSRC" com.example demo 1.0.0 com.example.Demo --offline --no-cache 2>/dev/null)"
  rc=$?
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  for w in 'public class Demo' 'private final String name' 'public Demo(String name)' \
           'public String getName()' 'void helper()' 'public static class Inner'; do
    printf '%s\n' "$out" | grep -qF "  $w" || { ok=1; bad="$w"; }
  done
  n="$(printf '%s\n' "$out" | sed -n '/^index:/,$p' | grep -c .)"
  [[ "${n:-0}" == "$(printf '%s\n' "$want" | grep -c .)" ]] || ok=1
  prop_check lib-source "the text reader is the fallback" "$ok" \
    "expected the same declarations without the parser: missing ${bad:-<none>}; exit=$rc, lines=${n:-0}"

  # A method is cut by both of them.
  out="$(MAVEN_REPO_LOCAL="$LIBSRC_REPO" TMPDIR="$LIBSRC_TMP" MAVEN_LIB_SOURCE_READER=text \
         "$LIBSRC" com.example demo 1.0.0 com.example.Demo --method join --offline 2>/dev/null)"
  rc=$?
  n="$(printf '%s\n' "$out" | grep -c 'public String join')"
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  [[ "${n:-0}" == "2" ]] || ok=1
  prop_check lib-source "the text reader cuts a method" "$ok" \
    "expected two overloads without the parser; exit=$rc, matches=${n:-0}"

  # The parser refuses a file it cannot parse rather than answering from half a
  # tree, and the text reader picks it up.
  mkdir -p "$work/brokensrc/com/example" "$LIBSRC_REPO/com/example/broken/1.0.0" || exit 1
  cat > "$work/brokensrc/com/example/Broken.java" <<'EOF'
package com.example;

public class Broken {
    public int ok() {
        return 1;
    }
    public int bad( {
}
EOF
  ( cd "$work/brokensrc" && jar cf "$LIBSRC_REPO/com/example/broken/1.0.0/broken-1.0.0-sources.jar" . ) || exit 1
  libsrc_run com.example broken 1.0.0 com.example.Broken --offline --no-cache
  ok=0
  [[ $rc -eq 0 ]] || ok=1
  printf '%s\n' "$out" | grep -qF '  public class Broken' || ok=1
  printf '%s\n' "$out" | grep -qF '  public int ok()' || ok=1
  prop_check lib-source "a file that does not parse falls back" "$ok" \
    "expected the text reader to answer; exit=$rc, got: $(printf '%s' "$out" | tr '\n' '|')"

  # Called with nothing at all.
  libsrc_run
  ok=0; [[ $rc -eq 2 ]] || ok=1
  prop_check lib-source "no arguments" "$ok" "expected exit 2; exit=$rc"
}

check_lib_source

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
(( FAILED > 0 )) && exit 2
exit 0
