---
title: Extract setup helpers only when they name a domain concept
description: Use when deciding whether to extract an Arrange helper
keywords: helper, setup, arrange, given, precondition, mockX, stubX, duplication, when, mock, stub
---

# Extract setup helpers only when they name a domain concept

Use a private Arrange helper when its name describes a _precondition_ or _scenario_ the reader cares about — not when it merely relabels a mock signature. 
The number of `when(...)` calls inside is irrelevant.

Identical bodies; the difference is whether the name survives a refactor. 
If `findById` becomes a cache lookup, `givenUserExists` stays accurate while `mockFindById` becomes a lie.

| Justified when | Not justified when |
|---|---|
| Name describes a domain precondition or scenario | Name mirrors the mock signature (`mockX`, `stubY`) |
| Name survives a change in how the precondition is implemented | Name would break if the mocked method were renamed |
| Collapses non-trivial matchers (`argThat`, `ArgumentCaptor`) into a meaningful call | The specific stubbed values are central to what the test verifies |
| Same precondition appears in 2+ tests | Setup is unique to one test and its values carry the meaning |

```java
// ✅ Good — name is a domain precondition
private void givenUserExists(long id, User user) {
    when(userRepository.findById(id)).thenReturn(Optional.of(user));
}

// ❌ Bad — name just relabels the mock signature
private void mockFindById(long id, User user) {
    when(userRepository.findById(id)).thenReturn(Optional.of(user));
}
```
