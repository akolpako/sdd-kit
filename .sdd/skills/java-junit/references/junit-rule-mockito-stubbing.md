---
title: Stub only what the test uses
description: Use when writing when(...) stubs
keywords: mockito, stub, when, lenient, UnnecessaryStubbingException, strict stubbing, any, eq, argument matcher, MockitoExtension, MockedStatic, static mock, thenReturn, doReturn, thenThrow, doThrow, mockStatic, spy
---

# Stub only what the test uses

`@ExtendWith(MockitoExtension.class)` runs with strict stubbing — keep it that way.

- Every `when(...)` must be consumed by the tested path. On
  `UnnecessaryStubbingException`, delete the stub — it is dead setup or a
  matcher typo, and both are bugs in the test.
- `lenient()` / `@MockitoSettings(strictness = LENIENT)` are forbidden as a fix
  for that exception.
- Stub with concrete argument values when the value matters to the behavior;
  `any()` only when it genuinely doesn't.
- Never mix a matcher and a raw value in one stub:
  `when(service.f(any(), "x"))` → `when(service.f(any(), eq("x")))`.
- `MockedStatic` / mockito-inline is a last resort — prefer injecting a seam
  (`Clock`, factory, wrapper). A static mock must be closed via try-with-resources.
