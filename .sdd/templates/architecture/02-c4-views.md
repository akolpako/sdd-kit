---
type: architecture-section
tags:
  - sdd/architecture
---

# C4 Views

<!-- The system drawn at the levels that carry information for this project. A
level that would say nothing beyond the one above it is dropped, not left with
an empty diagram. Every box and every arrow is something a reader can point at
in the code or the deployment. -->

## Level 1 — System Context

<!-- The system as one box: who uses it, and which external systems it talks
to, with the protocol on each arrow. -->

```mermaid
C4Context
```

## Level 2 — Container

<!-- The deployable and runnable parts inside the system boundary — services,
front ends, data stores — with the technology of each. -->

```mermaid
C4Container
```

## Level 3 — Component

<!-- Only for a container whose internals are not obvious from
module-structure.md. Dropped otherwise. -->

```mermaid
C4Component
```
