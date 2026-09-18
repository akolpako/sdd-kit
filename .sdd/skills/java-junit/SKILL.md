---
name: java-junit
description: 'Unit-test rules for JUnit 5, Mockito and AssertJ. Use when writing, reviewing or refactoring unit tests under src/test/java — never for Spring slice or Testcontainers tests.'
---

# Java JUnit Guidelines

> **Scope:** Unit tests only. Do **not** apply these rules to integration tests — `@SpringBootTest`, `@DataJpaTest`, `@WebMvcTest`, `@WebFluxTest`, `@JsonTest`, `@RestClientTest`, any other Spring slice annotation, or files using Testcontainers.

> **Precedence:** 🤝 marks a stylistic default that an **established** project convention overrides — established meaning recorded in `_docs/code-style.md`, not incidental code that violates the rule. Every other rule applies unconditionally; existing violations are refactoring targets, not precedent.

⛔ marks a rule that is **not** summarized here: read the linked file before writing that code. Every other rule is complete as stated; its link holds extra examples only. `✗ x → y` lines are anti-pattern and replacement.

## Foundations

**[F.I.R.S.T.][first]** — fast (no out-of-process resources), independent (order-independent), repeatable (no ambient state), self-validating (always asserts).
✗ `@SpringBootTest` / real DB / network / disk → mock the boundary, move to the integration suite; `LocalDate.now()` / `new Random()` / default `Locale` in the tested path → inject `Clock`, seed the RNG, pass explicit values; static mutable state between tests → fresh `@BeforeEach`; `@TestMethodOrder` / `@Order` → order-independent tests; a `@Test` that asserts nothing → every test asserts and can fail.

**Test through the public API** — private members are tested via public behavior; unreachable logic means an extraction is missing.
✗ `ReflectionTestUtils.setField` / `setAccessible(true)` / widened visibility → constructor injection, assert public behavior.

## Test Structure

**[Arrange / Act / Assert][aaa]** — three blank-line-separated sections, one call in Act; only `assertThatThrownBy` may combine Act and Assert.
✗ assertions interleaved with setup, or several Act calls → three sections, one Act call.

**[One logical concept per test][one-concept]** — one behavior per test; multiple inputs are parameterized, not repeated in one test.
✗ "save and then delete" in one test → one test per behavior.

**[No control flow in test methods][no-control-flow]** — no `if`/`switch`/`for`/`while`/`try` in a `@Test` body; different conditions are parameterized tests.
✗ loop driving assertions over elements → AssertJ collection assertion (`allSatisfy`, `containsExactly`).

## Test Organization

**Test naming** 🤝 — project convention first, otherwise `methodName_state_expected` (`findById_unknownId_returnsEmpty`); inside `@Nested` the state lives in the class name; class is `<ClassUnderTest>Test`.
✗ `testXxx` / `shouldXxx` / `test1` → the pattern.

**[Group related tests with @Nested][nested]** 🤝 — group scenarios in `@Nested` classes (≥ 5 tests, natural grouping).
✗ `// --- when X cases ---` comment banners → `@Nested` inner classes.

**Package-private visibility** 🤝 — test classes, `@Test` / `@ParameterizedTest` methods and lifecycle methods need no `public` in JUnit 5.
✗ `public class FooTest` / `public void test()` → package-private.

**Self-explanatory code, no comments** — refactor, extract or rename instead of explaining.
✗ explanatory comment / `// Arrange` marker → extract a helper or rename.

## Test Data

**[Use real instances for data carriers][real-data]** — never `mock(...)` a DTO, POJO or entity.
✗ `mock(Dto.class)` + `when(dto.getX())`, or `RETURNS_DEEP_STUBS` → real instance, real object graph.

**Fixture style for test data** 🤝 — ⛔ **read [junit-rule-fixtures.md][fixtures] before creating a Fixture class**: class shape, factory / `withXxx()` conventions and nested-Fixture composition are not summarized here. Using an existing Fixture needs no read — use it, never mutate after `build()`. Trivial types (1–2 args, domain factory) are constructed directly.
✗ `new` / builder for a type that has a Fixture → `<Type>Fixture` + `withXxx()`; `setXxx(...)` after `build()` → add `withXxx()` to the Fixture.

## Test Doubles

**Prefer a Fake over a Mock** 🤝 — ⛔ **read [junit-rule-fakes.md][fakes] before writing a Fake or a contract test**: Fake structure, the interface requirement and contract-test setup are not summarized here. Choosing: stateful collaborator (repository, cache, queue) → Fake; stateless or pure-interaction → Mock.
✗ several `when(...)` stubs on one collaborator wired to agree (`save` + `findById`) → a Fake that stores and returns; a Fake built only to `verify` one `void` call → Mock + `verify`.

**[Stub only what the test uses][stubbing]** — strict stubbing stays on; `lenient()` is forbidden; concrete argument values over `any()` when the value matters.
✗ unused `when(...)` stub, or `lenient()` silencing `UnnecessaryStubbingException` → delete the stub; `f(any(), "x")` → `f(any(), eq("x"))`.

## Reducing Duplication

**[Extract named setup helpers][setup-helpers]** — extract an Arrange helper only when its name describes a precondition.
✗ one-line helper renaming a single `when(...)` → inline it.

**[Parameterized tests for data variation][parameterized]** — tests differing only in input and expected values become `@ParameterizedTest`; not when logic or setup differs.

## Assertions & Verification

**[Use AssertJ exclusively][assertj]** 🤝 — every assertion through `assertThat(...)`, always the most specific one; JUnit-native assertions, Hamcrest and Truth are forbidden.
✗ `assertEquals` / `assertTrue` / `assertNull` / `assertThrows` / `assertAll` → AssertJ equivalent; `assertThat(list.size()).isEqualTo(3)` → `hasSize` (likewise `containsEntry`, `isPresent`).

**[State-based over interaction verification][state-based]** — assert the returned value or observable state; `verify(...)` is the exception, mainly for void side effects.
✗ `verify(...)` mirroring a state-based assertion → remove it; `verifyNoMoreInteractions(...)` → remove unless that exact contract is the test's purpose; `argThat(...)` for a non-trivial check → `ArgumentCaptor` + AssertJ on the captured value.

**[Expected values are literals][literals]** — hardcode the known-good value; never re-derive it with the SUT's own logic.

## Asynchronous Testing

**Never Thread.sleep; use Awaitility** — ⛔ **read [junit-rule-async-awaitility.md][awaitility] before writing an async assertion.** That `Thread.sleep(...)` is forbidden needs no read.
✗ `Thread.sleep(...)` / `TimeUnit.SECONDS.sleep(...)`, any unit, in test code → `await().untilAsserted(...)` or inject the sleep abstraction.

[first]: references/junit-rule-first.md
[aaa]: references/junit-rule-arrange-act-assert.md
[one-concept]: references/junit-rule-one-concept-per-test.md
[no-control-flow]: references/junit-rule-no-control-flow.md
[nested]: references/junit-rule-nested-grouping.md
[real-data]: references/junit-rule-real-data-carriers.md
[fixtures]: references/junit-rule-fixtures.md
[fakes]: references/junit-rule-fakes.md
[stubbing]: references/junit-rule-mockito-stubbing.md
[setup-helpers]: references/junit-rule-named-setup-helpers.md
[parameterized]: references/junit-rule-parameterized-tests.md
[assertj]: references/junit-rule-assertj-only.md
[state-based]: references/junit-rule-state-based-assertions.md
[literals]: references/junit-rule-literal-expected-values.md
[awaitility]: references/junit-rule-async-awaitility.md
