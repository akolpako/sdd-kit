---
type: requirements-compilation
tags:
  - sdd/requirements
---

# Requirements Compilation

<!-- Next free number: REQ-001 -->

All application requirements of the project, one line each.

## Requirements

<!-- Entry format:
- **REQ-001** — <short title>. <one-sentence description>. *(Source: <FeatureName>)* ^req-001

The `^req-001` at the end is the entry's anchor, the id in lower case. It is
written by `spec-edit.sh compile-entry` and is what another document links to:
`[REQ-001](requirements.md#^req-001)`.

A project may group its requirements by domain — `REQ-ACC-003` beside
`REQ-AUTH-001`. A domain is uppercase, starts with a letter, and is a sequence
of its own: its own numbers, and its own `Next free number:` marker above,
written by /sdd-actualize when the domain's first entry is compiled. The
ids carrying no domain are one such sequence too — the one a project that never
groups anything uses throughout.

An entry with no status suffix is active. The two suffixes, after the source:
- **REQ-014** — Cart discounts. A cart applies at most one promo code. *(Source: Cart, draft)*
- **REQ-012** — Guest checkout. A guest can order without an account. *(Source: Cart, superseded by REQ-031)*
-->
