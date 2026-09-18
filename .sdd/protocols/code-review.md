# Protocol: code review

*Addressed to the agent reviewing the code. It names no command and no agent.*

How a change set is reviewed against its specification on this project. **Which** change set arrives with the assignment; this is what happens to it once it has arrived. The review is read-only: applying the fixes and re-verifying the build belong to whoever gave the assignment.

## 1. Input Collection

- Load every installed skill whose description matches what the diff touches. Report a finding only when the code violates the source that wins the precedence order.
- Read `new-requirements.md`, `design.md`, `tasks.md` from the feature's `_docs/` folder, and `code-style.md` and the architecture baseline from `_docs/`. The baseline is entered through the file the assignment names — `_docs/architecture.index.md`, whose table says which section file holds which topic, or `_docs/architecture.md`; read the sections this review touches, not all of them. It is the architectural yardstick the design does not repeat; a deviation from it is a finding.
- Use the review set handed over with the assignment — `BASE`, `ROOT`, the `DIFF` command, and the untracked files — never a detection of your own. Only if it was not handed over, run `.sdd/scripts/review-set.sh` and say in the report that the base was self-detected.
- Run the `DIFF` command and read its output; a large one is sliced through a pipe and re-run for a second look. Write no scratch file, and least of all outside the project.
- Read every untracked file in full — a new file appears in no diff.
- Stop and report if a spec file is missing or the review set is empty.

## 2. Classify the Review Set

Before a single pass of §3, decide which of these the review set is. The class decides where the attention goes and what the report may claim; it never lowers the bar. State it in one line at the top of the report.

| Review set | What the review does |
|------------|----------------------|
| **Empty or trivial** — whitespace, reformatting, comment reflow, version bumps with no behaviour behind them | Report "no substantive changes" and stop; never invent findings to fill a report. |
| **Large** — more than ~6000 changed lines | Business logic and security first, the rest as far as it goes. Say that the review was truncated by priority, and name what was left unreviewed. |
| **Binary or generated files** — lock files, build output, minified bundles, generated clients, snapshots | Excluded from the passes; list them so nobody assumes they were read. Review the generator's input instead when it is in the set. |
| **Deletions only** | What the deletion left behind: callers of the removed code, dead code it orphaned, tests still asserting behaviour that no longer exists, config and docs still naming it. |
| **Tests only** | The assertions themselves: do they assert the behaviour or only run it, are they isolated, are they deterministic. A test that passes for a reason the requirement does not name is a finding. |
| **Configuration only** | Secrets, parity between environments, feature-flag defaults, and the path where the new setting is absent. |
| **Renames or moves with no content change** | Check that references followed the move and nothing was silently dropped; do not re-review the moved body as if it were new. |
| **Merge noise** — the diff carries commits from the base branch, not from this feature | Say so and stop before reviewing another branch's work. Recommend rebasing onto the base, or re-running with an explicit base ref. |

A review set is often several of these at once; apply each class that fits.

## 3. Review Process

Six passes over the diff, in this order:

1. **Spec compliance** — the code implements what `new-requirements.md`, `design.md`, and `tasks.md` describe, and follows the architecture baseline wherever the design is silent.
2. **Code quality.**
3. **Security.**
4. **Performance.**
5. **Testing.**
6. **Style** — `code-style.md`.

Running the project's own tests is part of the testing pass — often the only way to tell a test that asserts an outcome from one that merely runs the code. Do not start the application: a server left running outlives the review and belongs to nobody.

## 4. Issue Reporting

Severity — Critical, Major, Minor, Suggestion — decides the sort order, the reporting cap, and the verdict of §6.

Report each issue with its **severity**, **category** (Security / Performance / Quality / Spec Deviation / Style), **location** (file and line), **description**, and **recommendation**.

**Bounded.** Sort the issues by severity, Critical first, and report at most 20. If the review found more, the list ends with one line: `N more findings below the reporting threshold — re-run the review after these are fixed.` The cap is on the report, never on the review.

## 5. Requirement Coverage

Alongside the issue list, return one row per `REQ-###` declared in `new-requirements.md`.

| Requirement | Implemented in | Tested by | Conditions covered |
|-------------|----------------|-----------|--------------------|
| `REQ-001` | `CartService.java`, `CartController.java` | `CartServiceTest.java` | 3/3 |
| `REQ-002` | `PromoCodeValidator.java` | — | 0/2 |

- **Implemented in** — the files a reader would open to check the requirement holds, not every file a task touched.
- **Tested by** — the test files that assert it. A test that runs the code without asserting the requirement's outcome does not count.
- **Conditions covered** — how many of the requirement's conditions of satisfaction are covered, out of how many it declares. A condition is **covered** when at least one test fails if that condition breaks, `Error:` and `Edge:` conditions included. A line percentage is not coverage.
- Never stretch an unrelated file into a cell to make a row look complete; a dash is the answer.

## 6. Verdict

The report closes with one verdict and one line naming what decided it. It follows from the findings mechanically:

| Verdict | When |
|---------|------|
| **APPROVED** | No Critical and no Major findings |
| **APPROVED WITH MINOR ISSUES** | No Critical findings; the Major ones are listed and named in the verdict line |
| **BLOCKED** | Any Critical finding, or a red build or red tests, or a secret in the code |

- The verdict describes the review set as it stands: `BLOCKED` says the code is not mergeable as it is.
- A truncated review (§2) says so in the verdict.

## 7. Delivery

Return the report in one piece: the class of the review set, the issue list within its cap, the coverage rows, and the verdict.
