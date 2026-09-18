---
title: Expected values are literals, not recomputed
description: Use when choosing the expected value in an assertion
keywords: expected value, expected, literal, hardcode, recompute, recomputed, assertion value, assertThat, assertion, magic number
---

# Expected values are literals, not recomputed

The Assert section must not re-derive the expected result with the same logic the unit under test uses — that passes even when the production formula is wrong. Hardcode the known-good value.

This is the scalar version of why [no control flow in test methods](junit-rule-no-control-flow.md) forbids loops: a loop that builds the expected collection is usually the same bug.

```java
// ❌ Don't — expectation mirrors the implementation
assertThat(calculator.gross(order))
        .isEqualByComparingTo(order.getNet().multiply(ONE.add(order.getVatRate())));

// ✅ Do — expectation is a constant
assertThat(calculator.gross(order)).isEqualByComparingTo("107.70");
```
