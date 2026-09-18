---
title: Use real instances for data carriers
description: Use when a test needs a DTO / entity / value object — real instance, never a mock
keywords: data carrier, mock, mock dto, fixture, object mother, test data, RETURNS_DEEP_STUBS, value object, entity, POJO, PO, deep stubs, record
---

# Use real instances for data carriers, built with a consistent style

**Don't mock data carriers.** Never `mock(...)` / `when(...)` types that only hold data — value objects, API request/response models, DTOs, POJOs, JPA entities, persistence objects (PO).
They have no behavior to stub; mocking is fragile, verbose, and obscures intent. Use a real instance.

| Review smell                                                      | Action                       |
| ----------------------------------------------------------------- | ---------------------------- |
| `mock(SomeDto.class)` followed only by `when(obj.getXxx())` stubs | Replace with a real instance |
| Mock with no behavioral stubs (only getters)                      | Replace with a real object   |
| `Mockito.RETURNS_DEEP_STUBS` on a data graph                      | Build the real object graph  |

**Construct real instances consistently.** _How_ depends on the project: if it defines a test-data style (object mothers, builders, `*TestData` factories), follow it — don't introduce a competing one.
Otherwise use the **[Fixture style](junit-rule-fixtures.md)**: a `<Type>Fixture` builder centralizing each type's construction and defaults.

Whichever style:

1. Centralize construction — a domain-type change is one edit, not a sweep across every test.
2. Keep test methods focused on assertions; push data wiring out of the `@Test` body.
3. Never mutate the produced object after construction (no setters, no reassignment) — configure state at construction.
4. Missing variation → extend the helper, don't work around it inline.
5. Keep assertion-relevant data visible in the test: set the value an assertion depends on in the test body, not buried in a fixture default (xUnit "Mystery Guest").

```java
// ❌ Don't — mocking a data carrier
Address address = mock(Address.class);
when(address.getStreet()).thenReturn("Bundesplatz");
when(address.getHouseNumber()).thenReturn("3");
when(address.getZipCode()).thenReturn("3001");

// ✅ Do — real instance
Address address = anAddress("Bundesplatz", "3", "3001");
```
