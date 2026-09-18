---
type: architecture-section
tags:
  - sdd/architecture
---

# Business Logic

<!-- The workflows that carry the domain rules, one `## ` block each: what the
workflow does, the sequence it runs through, and the rules that decide its
outcome. A workflow that is a straight pass-through with no rule of its own is
not one — leave it out.

This describes how the project works today, not how one feature changes it. -->

## <workflow-name>

<!-- What it does and what triggers it. -->

```mermaid
sequenceDiagram
```

**Rules:**

<!-- The decisions the workflow makes and the conditions behind them. -->

## Error Handling

<!-- How failures are classified, what is retried and what is not, and what
the caller sees. -->

| Failure | Classification | Retry | Recovery |
|---------|----------------|-------|----------|
