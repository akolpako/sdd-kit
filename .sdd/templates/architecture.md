---
type: architecture
tags:
  - sdd/architecture
---

# Constitution

## Overview

<!-- What the project is for, in a few sentences: the purpose and the users.
Then the boundary of the whole system in the table below — what it is
responsible for, and what it deliberately leaves to someone else. It is about
the project, not about a feature. -->

| In scope | Out of scope |
|----------|--------------|

## Technology Stack

<!-- One row per layer: language / runtime, build, backend framework, UI
framework, data store, testing, linting / formatting, container / deployment.
A layer the project does not have is dropped, not left blank. Versions are the
ones actually in the build files. -->

| Layer | Technologies | Version |
|-------|--------------|---------|

## Architecture Style

<!-- One line naming the style — Modular monolith / Microservices / Clean
Architecture / Hexagonal / Library — and one paragraph on why this project
is that and not the alternative it was weighed against. -->

## Module Structure

<!-- One `### <module-name>` block per module, each carrying Purpose (why it
exists, which problem it owns), Design rationale (the constraint that decided
its shape), Key responsibilities (what it owns, what it delegates and to whom)
and Tech (the stack rows it actually uses).

Then the dependency graph as a `mermaid graph TD` block — every arrow is a
dependency that exists in the code. An arrow nobody can point at in the source
is an assumption, and is marked as one in Key Architectural Decisions. -->

## Key Architectural Decisions

<!-- One row per decision: the pattern, the evidence — the file, class, or
configuration where the pattern is visible — and the rationale: why this one,
and what it rules out. A decision with no evidence in the code goes under the
table as an assumption instead (format in `.sdd/protocols/spec-modes.md`). -->

| Pattern | Evidence | Rationale |
|---------|----------|-----------|

## Data Model

<!-- The persisted entities, one row each: the entity, the store it lives in,
what it represents, and its lifecycle — the states a record moves through.
Then the relations between them as a `mermaid erDiagram` block. -->

| Entity | Store | Purpose | Lifecycle |
|--------|-------|---------|-----------|

## API Conventions

<!-- REST conventions, versioning strategy, the error format every endpoint
returns, pagination and filtering. -->

## Security

<!-- Authentication, authorization model, data protection, secrets handling. -->

## Observability

<!-- Logging, metrics, tracing: what is emitted, in what format, where it goes. -->

## Testing Strategy

<!-- One row per scope: Root verification, Unit tests, Integration tests, E2E
tests, Coverage threshold; a scope the project does not have is dropped.
`Approach` is what is tested at that scope and how — the framework, the level,
what is real and what is mocked.

No commands here. What verifies this project is the human's answer, in
`.sdd/sdd.conf`, as SDD_BUILD_ROOT / SDD_BUILD_BACKEND / SDD_BUILD_FRONTEND;
`/sdd-init` proposes one per stack and writes the answer. This table describes
the approach and nothing reads it as an instruction. -->

| Scope | Approach |
|-------|----------|

## Non-Functional Requirements

<!-- Each one carries the number that makes it checkable, and how it is
measured. "Fast" and "highly available" are not requirements. -->

### Performance

<!-- e.g. p95 request latency under 300 ms at 100 rps, measured at the API. -->

### Availability

<!-- e.g. 99.9% monthly, planned maintenance excluded. -->

### Scalability

<!-- e.g. horizontal to 8 API instances; the data volume the design holds for. -->

<!-- An axis this project deliberately does not constrain is written down as
such — "no availability target: internal tool, downtime is acceptable". -->

## Constraints

<!-- Known constraints: compliance, integration, infrastructure, licensing,
organisational. A constraint is something that cannot be changed by this
project — everything else is a decision and belongs above. -->

## Glossary

<!-- Domain terms whose meaning here is narrower than the everyday one: what
the word means in this domain, and what it does not. -->

| Term | Definition |
|------|------------|
