# Tasks — Cart

<!-- > Status: draft -->
> Status: ready

## Overview

Cart storage, totals, and the REST endpoints over them.

## Tasks

<!-- Task format:
- [ ] **TASK-000** — <title>
  - **Requires:** REQ-###
  - **Type:** backend|frontend
-->

- [x] **TASK-001** — Cart table and entity
  - **Requires:** REQ-002
  - **Type:** backend
  - **Description:** The cart table, its entity, and the repository over it.

- [x] **TASK-002** — Add and remove items
  - **Requires:** REQ-002
  - **Type:** backend
  - **Description:** The service methods behind the two endpoints.

- [ ] **TASK-003** — Cart totals <!-- split off TASK-002 -->
  - **Requires:** REQ-003
  - **Type:** backend
  - **Description:** The sum of the items, refreshed on every change.

- [ ] **TASK-004** — Cart REST endpoints
  - **Requires:** REQ-002, REQ-003
  - **Type:** backend
  - **Description:** The controller over the service methods.
