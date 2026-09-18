---
title: Group related tests with @Nested
description: Use when organizing many tests or replacing comment-banner groupings
keywords: nested, @Nested, grouping, inner class, scenario, comment banner, organization
---

# Group related tests with `@Nested`, not comments

Group distinct scenarios in `@Nested` inner classes; comment banners (`// --- ID found cases ---`) are forbidden. 
Each nested class has a scenario-describing name, contains only that scenario's tests, and may have its own `@BeforeEach`. 
Use `@Nested` only at **≥ 5 tests** with a natural grouping; below that, keep tests flat.

```java
class IdProcessorTest {

    @Nested
    class WhenIdIsFound {
        @Test void returnsAdvertisingResponse() { ... }
        @Test void doesNotCallFallback() { ... }
    }

    @Nested
    class WhenIdIsNotFound {
        @Test void returnsErrorResponse() { ... }
        @Test void logsMissingIdWarning() { ... }
        @Test void doesNotCallAdvertisingService() { ... }
    }
}
```
