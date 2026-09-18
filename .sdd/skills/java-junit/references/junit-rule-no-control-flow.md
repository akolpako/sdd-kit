---
title: No control flow in test methods
description: Use always when writing a test body
keywords: control flow, if, else, for, while, loop, try catch, switch, forEach, linear test, conditional, branching
---

# No control flow in test methods

Test methods are linear. Forbidden in a `@Test` body: `if`/`else`/`switch`, `for`/`while`, `try`/`catch`, free-standing `forEach`/stream pipelines that drive assertions.
For different conditions, use separate or [parameterized tests](junit-rule-parameterized-tests.md).

Permitted lambdas: `assertThatThrownBy(() -> ...)`, `assertThatCode(() -> ...).doesNotThrowAnyException()`,
AssertJ chains (`.allSatisfy`, `.anySatisfy`, `.satisfies`, `.extracting`), `@MethodSource` suppliers.
