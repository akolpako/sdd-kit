---
title: F.I.R.S.T. — fast, independent, repeatable, self-validating
description: Always use when writing a unit test.
keywords: FIRST, fast, independent, repeatable, self-validating, unit test, test, clock, instant, random seed, locale, zoneid, spring context, springboottest, datajpatest, webmvctest, integration test, beforeeach, testmethodorder, order, mockito, database, network, file system, flaky, deterministic, isolation
---

# F.I.R.S.T.: fast, independent, repeatable, self-validating

A unit test is Fast, Independent, Repeatable, and Self-Validating.

**Fast — no out-of-process resources.** No real database, network, file system, or message broker, and avoid Spring context.
A Spring-context test (`@SpringBootTest`, or a slice like `@DataJpaTest` / `@WebMvcTest`) is a valid integration test — not a unit test, so keep it in a separate suite, out of scope here.
Otherwise exercise the class with in-process collaborators and test doubles.

| ❌ Don't                                    | ✅ Do                                                                               |
| ------------------------------------------- | ----------------------------------------------------------------------------------- |
| `@SpringBootTest` to test one service       | `@ExtendWith(MockitoExtension.class)` or none                                       |
| Real repository / `JdbcTemplate` hitting DB | Mock the gateway at the boundary                                                    |
| Read a fixture file from disk               | Build the object in memory ([real data carriers](junit-rule-real-data-carriers.md)) |

**Independent — order-independent.** Same result regardless of execution order or which tests ran before.
Create fresh state in `@BeforeEach`; never share mutable static fields. `@TestMethodOrder` / `@Order` are forbidden.
A shared field must be re-initialized in `@BeforeEach` or be effectively immutable (constants, `@Mock` reset by `MockitoExtension`).

**Repeatable — no hidden dependency on ambient state.**

| Source of non-determinism                        | Fix                                                     |
| ------------------------------------------------ | ------------------------------------------------------- |
| `LocalDate.now()` / `Instant.now()` in the SUT   | Inject a `Clock`; stub a fixed instant                  |
| `new Random()` without a seed                    | Seed it, or inject the randomness source                |
| Default `Locale` / `ZoneId`                      | Pass an explicit value                                  |
| `HashMap` / `HashSet` iteration order in asserts | `containsExactlyInAnyOrder(...)` or ordered collections |

**Self-Validating — every test asserts and can fail.** No `System.out` as a "check"; "didn't throw" is not an outcome unless that _is_ the contract (`assertThatCode(...).doesNotThrowAnyException()`, [AssertJ only](junit-rule-assertj-only.md)).
