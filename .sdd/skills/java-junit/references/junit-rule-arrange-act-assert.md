---
title: Arrange / Act / Assert
description: Use always when structuring a test body
keywords: arrange act assert, AAA, test structure, test body, assertThatThrownBy, given when then, unit test, test
---

# Arrange / Act / Assert

Three sections separated by blank lines: 
**Arrange** (data, stubs, preconditions), 
**Act** (one call to the unit), 
**Assert** (assertions on result or observable state). 
Don't interleave assertions with setup or extra act calls.

Exception: `assertThatThrownBy(() -> ...)` combines Act and Assert — the only accepted one.

```java
@Test
void findActive_mixedUsers_returnsActiveOnly() {
    User active = anActiveUser();
    User inactive = anInactiveUser();
    when(repository.findAll()).thenReturn(List.of(active, inactive));

    List<User> result = service.findActive();

    assertThat(result).containsExactly(active);
}
```
