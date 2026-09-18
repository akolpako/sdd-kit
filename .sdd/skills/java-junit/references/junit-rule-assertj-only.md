---
title: Use AssertJ exclusively
description: Use when choosing assertions
keywords: assert, assertj, assertThat, assertEquals, assertTrue, assertFalse, assertNull, assertNotNull, assertThrows, assertAll, assertions, hamcrest, truth, isEqualTo, hasSize, extracting, SoftAssertions
---

# Use AssertJ exclusively

All assertions use AssertJ (`assertThat(...)`). JUnit-native assertion methods are forbidden, as is any other assertion library (Hamcrest, Truth).
`assertAll(...)` is JUnit-native and forbidden like the rest; its AssertJ counterpart (`SoftAssertions` / `assertSoftly`) is rarely warranted — in a test verifying [one logical concept](junit-rule-one-concept-per-test.md), fail-fast `assertThat(...)` calls or one chained assertion suffice.

Use the most specific assertion, not a generic one on a derived value —
it reads better and fails with a diagnostic instead of `expected: true but was: false`:

| ❌ Generic on derived value             | ✅ Dedicated                                   |
| --------------------------------------- | ---------------------------------------------- |
| `assertThat(list.size()).isEqualTo(3)`  | `assertThat(list).hasSize(3)`                  |
| `assertThat(list.isEmpty()).isTrue()`   | `assertThat(list).isEmpty()`                   |
| `assertThat(opt.isPresent()).isTrue()`  | `assertThat(opt).isPresent()` / `.contains(x)` |
| `assertThat(opt.get()).isEqualTo(x)`    | `assertThat(opt).contains(x)`                  |
| `assertThat(s.contains("x")).isTrue()`  | `assertThat(s).contains("x")`                  |
| `assertThat(a.equals(b)).isTrue()`      | `assertThat(a).isEqualTo(b)`                   |
| `assertThat(map.get("k")).isEqualTo(v)` | `assertThat(map).containsEntry("k", v)`        |

Prefer one chained or `.extracting(...)` assertion over many separate `assertThat(...)` calls on the same object.
