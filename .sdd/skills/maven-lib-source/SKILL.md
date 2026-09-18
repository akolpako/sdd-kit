---
name: maven-lib-source
description: 'Reads the real source of a class from Maven dependencies, in the version the build uses. Use before stating what a dependency class or method does or whether it exists in the project''s version, and instead of digging through ~/.m2 with find, unzip, jar or javap. Maven only.'
---

# Maven library source

When an AI agent needs to know what a library class does, it either answers from memory — often about a different version than yours — or digs through `~/.m2` by hand: `find`, `unzip`, `javap`, then reads a 9,000-line file into context. The first gives wrong answers; the second is slow and burns tokens.

This skill gives the agent one script call instead. It finds the class in your Maven dependencies, picks the version your build actually uses, and returns only what was asked — a method, a filtered index of declarations, or line ranges — instead of whole files. No sources jar? It decompiles or falls back to signatures, and labels which.

Maven only (not Gradle); needs bash and unzip.

Read the class from the jar; do not use `find`, `unzip`, `jar` or `javap` on `~/.m2` by hand.

Script: `scripts/maven-lib-source.sh`, relative to this skill's directory.

## Which classes

Only classes from dependency jars. For a class the project itself declares, grep the sources; when unsure, grep first:

```bash
rg -l 'class Foo|interface Foo|enum Foo|record Foo' --glob '**/src/**/*.java'
```

## Which call

| Question | Call |
|---|---|
| What is this class? | `find <Class> --from-project <dir>` — names the dependency and reads the class |
| Several classes | `find <A> <B> <C> --from-project <dir>` — one scan |
| Which dependency holds it? | `find <Class> --from-project <dir> --list` |
| Is it in our version / will it compile? | `find <Class> --from-project <dir> [--module <path>]` — exit `4` means not on the classpath, whatever other versions on disk hold |
| What does this method do? | `--method <name>` — every overload, nested classes included; repeatable |
| What does the class declare? | no flag — path, line count, index of types, methods, fields, constants |
| Part of a fat class | `--members <regex>` — case-insensitive, matched against the whole declaration line, parameters included |
| The whole text | `--print` |

```bash
scripts/maven-lib-source.sh find <Class> [<Class> ...] --from-project <dir> [--module <path>] [--method <m> ...]
scripts/maven-lib-source.sh <groupId> <artifactId> <className> --from-project <dir> [--module <path>]
scripts/maven-lib-source.sh <groupId> <artifactId> <version> <className>
```

The coordinate form is for an artifact already known, or for a name `find` matched more than once. All options: `--help`.

## Rules

- **Simple class name**, not qualified: the package is what gets remembered wrong. A wrong package still resolves by simple name; the header shows the real one. A qualified name only to pick one of several hits.
- **Version from the build:** pass `--from-project`, never a remembered version; without it `find` reads the newest version on disk. In a multi-module project add `--module` (as Maven's `-pl`) for the module being worked in — without it the classpath is an arbitrary module's.
- **Offline:** `--offline` — nothing is downloaded; works with `find` and `--from-project`.
- **Search scope:** `--from-project` or `--group-prefix`; with neither, only existing indexes are searched (`--all` scans the whole repository).
- **Batch what you know:** every class and method already known goes into one call; call again only for a class the answer led to.
- **Don't pipe** through `head`, `tail` or `grep` — the header (`artifact:`, `class:`, `source:`) gets cut. Narrow with `--method`, `--members`, `--list`.
- **Long answers** (over 120 lines) are written to a file; the last lines printed give the `sed` command for the rest.
- **Read ranges, not files:** `sed -n '<from>,<to>p' <file>` using the index line numbers. The whole library is unpacked beside it — grep there for subclasses and usages.
- **Cite** `groupId:artifactId:version`, the class and `source:` — never the `file:` path, it is a local cache.
- **`--out <dir>`** copies the file into the workspace when its path cannot be read.

## Trust by `source:`

- `sources`, `sources-downloaded` — the real file with javadoc.
- `decompiled(vineflower <v>)` — logic reliable; comments and parameter names (`var1`) are not the library's, never quote them.
- `javap` — signatures only: which overloads exist and what they throw, nothing about behaviour.

## Output

One hit — the class is read:

```
artifact: org.apache.commons:commons-lang3:3.20.0
class: org.apache.commons.lang3.StringUtils
source: sources
file: /var/folders/…/sources/org/apache/commons/lang3/StringUtils.java
lines: 9216
index:
   125  public class StringUtils
   236  public static String abbreviate(final String str, final int maxWidth)
```

Several hits — listed, none read; pick one and call again with its coordinates:

```
class: StringUtils
found: 2
  org.apache.commons:commons-exec:1.6.0  org.apache.commons.exec.util.StringUtils  (newest of 5 in the repository)
  org.apache.commons:commons-lang3:3.20.0  org.apache.commons.lang3.StringUtils  (newest of 17 in the repository)
```

## Exit codes

`0` ok (including several hits) · `2` usage · `3` artifact missing or not on the classpath · `4` class not found · `5` a coordinate read whose simple name matches several classes in the artifact · `6` method not found · `7` offline dead end · `8` missing tool.

With several names or methods, what was found is printed and what was missed is named on stderr. Every failure prints a `hint:` with the fixing command — run it. On `7`, record an assumption and carry on.

## Requirements

- **Required:** `bash`, `unzip`.
- **Optional:** JDK — exact parsing, decompilation, `javap`; without it, sources jars only. `mvn` — `--from-project` and downloads.
- **Network:** unless `--offline`, missing jars, sources jars and the Vineflower decompiler are fetched with `mvn dependency:get`; Vineflower and a helper built from `scripts/MavenLibSource.java` run under local `java`. `--from-project` runs `mvn dependency:build-classpath`.
- **Disk:** cache in `~/.cache/maven-lib-source`, unpacked sources under the system temp directory.

## Limits

- Maven artifacts only; JDK classes are not in `~/.m2`.
- Nested classes are read through their outer class; search matches outer classes only.
- Without a JDK (or for Kotlin) a text reader is used: it may truncate multi-line signatures.
- Indexes are snapshots: `--refresh` after installing an artifact.
