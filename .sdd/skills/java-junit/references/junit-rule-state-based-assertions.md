---
title: Prefer state-based assertions over interaction verification
description: Use when writing verify(...)
keywords: verify, verifyNoMoreInteractions, ArgumentCaptor, argThat, state-based, interaction, mockito verify, side effect, capture, times, never
---

# Prefer state-based assertions over interaction verification

Default to asserting on the returned value or observable state.
**`verify(...)` is the exception, not the norm.**

Justified: a `void` method whose only observable effect is on a collaborator (event published, email sent, audit logged);
a delegating method whose contract _is_ forwarding the call.

Not justified: mirroring a state-based assertion; `verifyNoMoreInteractions(...)` unless that exact contract is the test's purpose; verifying mocks already exercised by a state assertion.

For a _stateful_ collaborator (its answer to one call depends on earlier calls), don't hand-script stubs at all — prefer a Fake over a Mock (see [Prefer a Fake over a Mock](junit-rule-fakes.md)).

```java
// ❌ Don't — over-verifying after a state assertion
User result = service.find(1L);
assertThat(result).isEqualTo(user);
verify(repository).findById(1L); // redundant
verifyNoMoreInteractions(repository); // unjustified

// ✅ Do — verify justified for a void side effect
service.register(user);
verify(eventPublisher).publish(new UserRegisteredEvent(user.getId()));
```

When you must verify and the argument matters, use `ArgumentCaptor` (not `argThat`), wrapped in a helper named for the domain action ([named setup helpers](junit-rule-named-setup-helpers.md)):

```java
UserRegisteredEvent event = capturePublishedEvent();
assertThat(event.getUserId()).isEqualTo(42L);

private UserRegisteredEvent capturePublishedEvent() {
    ArgumentCaptor<UserRegisteredEvent> captor = ArgumentCaptor.forClass(UserRegisteredEvent.class);
    verify(eventPublisher).publish(captor.capture());
    return captor.getValue();
}
```
