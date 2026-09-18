---
type: review
feature: <FeatureName>
reviewed: <YYYY-MM-DD>
base: <base ref, or "none — uncommitted changes only">
root: <the commit the reviewed diff was taken against>
verdict: <APPROVED | APPROVED WITH MINOR ISSUES | BLOCKED>
tags:
  - sdd/review
---

# Code Review — <FeatureName>

<!-- The report of one code review: a snapshot of the working tree as it was on
the `reviewed` date above, never a ledger of what has since been fixed.

The four header fields are the properties above, in that order. `verdict` also
takes `stale — fixes applied <YYYY-MM-DD>`. A value carrying a colon is quoted,
or YAML reads the colon as the end of the key. -->

## Review set

<!-- One line for the class of the set — the diff, the untracked files, and
what the class means for what this report may claim. Then, when they apply:
what was excluded (generated files, binaries), what was truncated, and the
tasks left blocked, which are unfinished by design rather than missing. -->

## Findings

<!-- Sorted by severity, worst first, numbered `F-01` upward in that order. The
numbers are stable within a report.

### F-01 — Critical — Security

> [!danger] Where: `src/main/java/.../CartController.java:42`
> **What:** <the defect, one or two sentences>
>
> **Recommendation:** <what to do about it>

Severity is one of Critical, Major, Minor, Suggestion; category is one of
Security, Performance, Quality, Spec Deviation, Style. The callout type carries
the severity, so a reader sees it before reading a word:

| Severity | Callout |
|----------|---------|
| Critical | `> [!danger]` |
| Major | `> [!warning]` |
| Minor | `> [!note]` |
| Suggestion | `> [!tip]` |

When the review found more than the report holds, the section ends with the one
line saying how many are below the threshold. -->

## Requirement coverage

<!--
| Requirement | Implemented in | Tested by | Conditions covered |
|-------------|----------------|-----------|--------------------|
| `REQ-001` | `CartService.java` | `CartServiceTest.java` | 3/3 |
| `REQ-002` | `PromoCodeValidator.java` | — | 0/2 |

A dash is an answer; an unrelated file stretched into a cell is not. -->

### Gaps

<!-- Listed separately, because they are what the table is read for:
requirements with no code, requirements with no test, and conditions of
satisfaction no test covers. This reports; it does not block. -->

## Older TODO Code Review markers

<!-- The `TODO Code Review:` markers already in the code, with their file, line
and date — what earlier reviews decided to defer. Reported, never removed, and
never raised again as new findings. -->
