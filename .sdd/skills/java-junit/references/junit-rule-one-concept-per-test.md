---
title: One logical concept per test
description: Use always when writing a test body
keywords: one concept, single behavior, one assertion, single responsibility, multiple inputs, save and delete, split test, parameterize, multiple assertions
---

# One logical concept per test

A test verifies one behavior.
Multiple assertions on fields of the **same** returned object are fine;
multiple invocations with different inputs are not — parameterize instead ([parameterized tests](junit-rule-parameterized-tests.md)).

| ❌ Don't                                                                         | ✅ Do                                                                        |
| -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Call the method twice with different inputs in one test                          | Two tests, or one parameterized test                                         |
| Test "save and then delete" together                                             | `save_validUser_persistsUser` + `delete_existingUser_removesUser` separately |
| Assert response **and** verify a side effect **and** check a second collaborator | Split: state-based test for the response, separate test per side effect      |
