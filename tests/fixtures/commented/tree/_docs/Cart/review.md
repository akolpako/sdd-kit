# Code Review — Cart

> Reviewed: 2026-01-15
> Base: main
> Root: deadbeef
> Verdict:
> Verdict: BLOCKED

## Review set

The committed diff against `deadbeef`, no untracked files.

## Findings

### F-01 — Critical — Security
- **Where:** `src/main/java/com/example/CartService.java:12`
- **What:** The item count is read from the request and never bounded.
- **Recommendation:** Bound it at the service edge.

## Requirement coverage

| Requirement | Implemented in | Tested by | Conditions covered |
|-------------|----------------|-----------|--------------------|
| `REQ-002` | `CartService.java` | — | 0/1 |

### Gaps

`REQ-002` has no test.

## Older TODO Code Review markers

None.
