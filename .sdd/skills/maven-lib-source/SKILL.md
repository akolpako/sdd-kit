---
name: maven-lib-source
description: 'Reads a class from a Maven dependency jar — the sources jar, a decompilation, or signatures, labelled with which one. Use before stating what a class or method from a dependency does, and instead of reaching into ~/.m2 with find, unzip, jar or javap.'
---

# Maven library source

Read a library class rather than recall it. This replaces reading `~/.m2` by hand: do not use `find`, `unzip`, `jar` or `javap` for it.

Script: `scripts/maven-lib-source.sh`.

What a class declares is read by javac's own parser, so it cannot be wrong about it. Where there is no JDK, or the file is Kotlin, a text reader answers instead — it follows the shape of the source, and a shape it does not know is a declaration missing from the index. Both are cached under the checksum of the file, so a class is parsed once.

## Which classes this is for

Classes that arrive on the classpath from a jar. A class the repository under work declares is not one of them — grep the sources for it instead.

The import tells them apart: a package outside the project's own groupId comes from a dependency. Where that is not obvious, grep first and call this when the grep finds nothing:

```bash
rg -l 'class Foo|interface Foo|enum Foo|record Foo' --glob '**/src/**/*.java'
```

## Which call

| Question | Call |
|---|---|
| What is this class? | `find <Class> --from-project <dir>` — one call: it names the dependency and reads the class |
| Several classes | `find <A> <B> <C> --from-project <dir>` — one scan answers all of them |
| Which dependency holds it? | the same call; `--list` to stop at the list |
| Which version do we use? | pass `--from-project <dir>`, leave the version out |
| What does this method do? | `--method <name>` — prints the code, every overload |
| Two methods of one class | `--method <a> --method <b>` — repeatable, one call |
| What does the class declare? | no flag — prints the path, the line count, an index of the types, methods, fields and constants |
| What are the enum's constants? | no flag — they are in the index |
| Only the part of a fat class I asked about | `--members <pattern>` — keeps the declarations matching it |
| The whole text | `--print` |

```bash
scripts/maven-lib-source.sh find <Class> [<Class> ...] --from-project <dir> [--module <path>]
scripts/maven-lib-source.sh find <Class> --method <a> --method <b> --from-project <dir>
scripts/maven-lib-source.sh <groupId> <artifactId> <className> --from-project <dir> [--module <path>]
scripts/maven-lib-source.sh <groupId> <artifactId> <version> <className> [--method <name>]
scripts/maven-lib-source.sh index <group-prefix>
```

**Pass the simple class name.** `find PaymentTransaction`, not `find com.example.payment.servicemodel.PaymentTransaction`. The package is the part that gets remembered wrong, and the search does not need it: it reports the package the class actually has. A fully qualified name is for one job only — picking one of two classes a search reported under the same simple name.

A qualified name whose package is wrong is not a dead end either: the simple name is tried before the miss is reported, and what it matched is read, or listed where several classes carry that name. Stderr says the asked name is not what came back, and the header names the package the class really has.

Options: `--method <name>` (repeatable), `--members <pattern>`, `--list`, `--print`, `--out <dir>`, `--spill auto|never|always`, `--from-project <dir>`, `--module <path>`, `--group-prefix <p>`, `--all`, `--refresh`, `--offline`, `--no-cache`, `--json`, `--help`.

`find` is the call to reach for: it resolves the coordinates and reads the class in one go. The three- and four-argument forms are for a class whose artifact is already known, or a name that matched more than once.

## Rules

- **The version comes from the build.** `--from-project` reads it off the module's classpath; a remembered version is not passed. `--module` takes what Maven's `-pl` takes — in a multi-module project, name the module being worked in, or the classpath that comes back is one module's rather than the one being asked about. The scan of that classpath is kept, so the first search of a project costs seconds and the rest cost none.
- **Versions of one artifact are one hit.** A repository that holds twenty of them still reports the class once, and the newest is what a single hit reads. `--from-project` is what makes it the version the build uses.
- **A search is narrowed** by `--from-project` (the module's classpath, exact) or `--group-prefix`. With neither, only the indexes that exist are consulted; the repository is not scanned.
- **Ask once.** Every name and every method wanted goes into the one call. Calling again for the second method of a class already read is a wasted turn, not a cheaper one.
- **Take the answer whole.** `| tail`, `| head` and `| grep` over this output cut the header — `artifact:`, `class:`, `source:` are printed first, and they are what says which class and which version answered. What is wanted from a long class is asked for instead: `--members`, `--method`, `--list`.
- **A long answer comes back as a file.** Over 120 lines, the head is printed and the whole answer is written where it can be read in parts; the last lines of that head name the file and the command that reads the rest. The path is stable, so calling the same thing again does not make a second file. `--spill never` prints it whole, `--spill always` files it whatever its length.
- **Narrow a fat class** with `--members <pattern>` — an extended regular expression, matched case insensitively against the declarations. A class of three hundred methods answers a question about six of them in six lines.
- **Read the range the index names**, not the file. `sed -n '<from>,<to>p' <file:>` on the path the answer printed; the library is unpacked whole beside it, so its neighbours grep for subclasses, usages and annotations. Reaching for `--print` and piping it into `grep` is the slow way round.
- **The `file:` path is read, never cited.** It is a cache on this machine, so it is a fine argument to `sed`, `grep` and `rg`, and never part of an answer. What is cited is `groupId:artifactId:version`, the class, and `source:`.
- **`--out <dir>`** when the path lies outside the workspace and cannot be read.

## What the answer is worth

`source:` says how far to trust it.

- **`sources`, `sources-downloaded`** — the real file, javadoc and parameter names intact.
- **`decompiled(vineflower <v>)`** — logic and control flow reliable; no comments, parameter names may read `var1`, lambdas appear as synthetic methods. Its comments and parameter names are never quoted as the library's.
- **`javap`** — signatures only, printed inline. Settles which overloads exist and what they throw, nothing about behaviour.

## Output

A search that found one class prints that class, whose header names the artifact
it came from:

```
artifact: org.apache.commons:commons-lang3:3.20.0
class: org.apache.commons.lang3.StringUtils
source: sources
file: /var/folders/…/sources/org/apache/commons/lang3/StringUtils.java
lines: 9216
index:
   125  public class StringUtils
   146  public static final String SPACE
   236  public static String abbreviate(final String str, final int maxWidth)
```

A search that found several prints them and reads none, for the caller to pick:

```
class: StringUtils
found: 2
  org.apache.commons:commons-exec:1.6.0  org.apache.commons.exec.util.StringUtils  (newest of 5 in the repository)
  org.apache.commons:commons-lang3:3.20.0  org.apache.commons.lang3.StringUtils  (newest of 17 in the repository)
```

A long answer is filed, and what comes back is its head and the way to the rest:

```
artifact: org.apache.commons:commons-lang3:3.20.0
class: org.apache.commons.lang3.StringUtils
source: sources
file: /var/folders/…/sources/org/apache/commons/lang3/StringUtils.java
lines: 9216
index:
   125  public class StringUtils
   146  public static final String SPACE

answer: 412 lines, the first 14 above. file: ~/.cache/.sdd/maven-lib-source/answers/StringUtils-2891740153-9216.txt
hint: read the rest of it — sed -n 15,412p ~/.cache/.sdd/maven-lib-source/answers/StringUtils-2891740153-9216.txt
```

## Exit codes

`0` ok · `2` usage · `3` artifact missing, or not on the classpath · `4` class not found · `5` ambiguous name · `6` method not found · `7` offline dead end · `8` missing tool.

A qualified name with the wrong package is not `4` where the simple name matches: the class is answered, and stderr says so.

A search that matched several classes is not an error: it exits `0` with the list. `5` is a read whose simple class name matched more than one package inside the one artifact.

A search for several names reports each on its own and exits `4` if any of them missed; the ones that were found are in the output regardless. A method that is not there is named on stderr while the rest are returned.

Every failure prints a `hint:` carrying the command that fixes it; run that rather than improvise. On exit `7`, record an assumption and carry on — it never blocks the work.

## Limits

- Maven artifacts only. JDK classes are not in `~/.m2`.
- A nested class is read through the class that encloses it, and the index lists it; a search matches outer classes only.
- The fallback reader cuts a method rather than parsing it, and truncates a signature that runs over several lines. Where it cannot follow the source at all it returns the file and its index instead, and says so on stderr. The parser does neither.
- An index is a snapshot: `index <prefix> --refresh` after an artifact is installed, or `--refresh` on the search itself.
- The decompiler version is pinned in the script.
