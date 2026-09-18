---
title: Prefer a Fake over a Mock for stateful collaborators
description: Use when choosing a test double for a collaborator that holds state
keywords: fake, mock, test double, stateful collaborator, in-memory, contract test, repository, cache, queue, stub, verify
---

# Prefer a Fake over a Mock for stateful collaborators

> **Scope.** Choosing a test double for a *stateful* collaborator. Data carriers (DTOs, value objects, entities) are [never mocked — use a real instance](junit-rule-real-data-carriers.md).

## Core principle

For a collaborator that holds state, a **Fake** — a lightweight working implementation — is required and a Mock is the exception ([narrow cases below](#when-a-mock-is-still-right)). A Fake behaves like the real thing, so the test exercises real state transitions instead of a hand-stubbed script of return values.

## Choosing a test double

```
What is the collaborator?
│
├─ A data carrier (DTO, value object, entity, POJO)?
│      → Do not Fake it — use a real instance.
│
├─ Stateful — its answer to one call depends on previous calls?
│      → Use a Fake (requires an interface to implement).
│
└─ Stateless / pure interaction — one canned return, only asserting a call happened, or no interface?
       → Mock + verify, or a simple stub.
```

Stateful collaborators: repositories/DAOs, caches, registries, session/context holders, ID/sequence generators, queues/buffers/outboxes, feature-flag stores toggled during the test.

## Why mocking a stateful collaborator is brittle

Hand-scripted stubs encode the implementation's exact call sequence and are wired to agree with each other regardless of what the code under test actually does — the test verifies the stubs, not the code.

```java
// ❌ Don't — the two stubs are wired to agree; the test passes even if register() never persists
@Test
void register_newUser_becomesFindable() {
    User user = aUser();
    when(repository.save(user)).thenReturn(user);
    when(repository.findById(user.getId())).thenReturn(Optional.of(user));

    service.register(user);
    User found = service.find(user.getId());

    assertThat(found).isEqualTo(user);
}
```

```java
// ✅ Do — the Fake actually stores on save and returns on find, so the round-trip is real
@Test
void register_newUser_becomesFindable() {
    FakeUserRepository repository = new FakeUserRepository();
    UserService service = new UserService(repository);
    User user = aUser();

    service.register(user);
    User found = service.find(user.getId());

    assertThat(found).isEqualTo(user);
}
```

## Writing a Fake

A Fake is a real implementation of the collaborator's interface, backed by a simple in-memory structure (e.g. `FakeUserRepository implements UserRepository` over a `Map<Long, User>`).

Rules for a Fake:

1. **Requires an interface** (or abstract type). No interface → do not subclass-and-override a pseudo-Fake; fall back to a Mock.
2. **Substitutable, not a lookalike** — could stand in for the real implementation anywhere.
3. **Simple in-memory state** (`Map`/`List`), deterministic — no randomness, I/O, sleeping, or background threads.
4. **Honors the real contract** — same not-found/duplicate/null semantics and exceptions; no extra behavior, no missing behavior the code under test relies on.
5. **No test-only shortcuts** that diverge from production behavior; inspect state through the interface where possible.

### Conventions

| Element | Rule |
|---|---|
| Name | `Fake<Type>` (e.g. `FakeUserRepository`) by default — a project's existing convention wins |
| Implements | the real collaborator's interface |
| Backing | in-memory (`Map`/`List`), deterministic |
| Placement | a `fake` subpackage alongside the tests by default — a project's existing convention wins |
| Visibility | `public` when shared across packages/modules; package-private otherwise |
| Sharing | if needed by several modules, publish it as a reusable test artifact (a test JAR) — do not copy it |

## Keep reused Fakes honest: contract tests

A Fake used by **more than one test class** (or shared across modules) must be covered by a **contract test**: an abstract test defining the behavior every implementation of the interface must satisfy. Both the real implementation and the Fake extend it — a drifting Fake fails its contract. A single-use Fake local to one test class needs none; the tests using it are its safety net.

```java
// The contract — observable behavior every UserRepository must satisfy
abstract class UserRepositoryContract {

    protected abstract UserRepository repository();

    @Test
    void findById_savedUser_returnsIt() {
        UserRepository repository = repository();
        User user = aUser();

        repository.save(user);

        assertThat(repository.findById(user.getId())).contains(user);
    }

    @Test
    void findById_unknownId_returnsEmpty() {
        assertThat(repository().findById(999L)).isEmpty();
    }
}
```

```java
// Each implementation runs the same contract
class FakeUserRepositoryContractTest extends UserRepositoryContract {
    @Override
    protected UserRepository repository() {
        return new FakeUserRepository();
    }
}
// JpaUserRepositoryContractTest does the same with real wiring (test DB, Testcontainers) — slower is fine there.
```

- The contract captures **behavior, not storage internals** — assert through the interface, never on private fields.
- A new contract rule ("save rejects a duplicate id") forces every implementation, including the Fake, to keep up.

## When a Mock is still right

A Mock (or a simple stub) is the **exception**, appropriate when:

- The collaborator is **stateless** and you only need a canned return for a single call (a pure, function-like dependency).
- The contract under test **is the interaction itself** — a `void` side effect you assert with [`verify`](junit-rule-state-based-assertions.md) (event published, email sent, audit logged); do not build a Fake merely to count a call.
- The collaborator is **external and awkward to fake**, and the test only cares that it was invoked.

The moment a test wires **multiple stubs on one collaborator that must agree with each other**, you are modeling state with a Mock — switch to a Fake.
