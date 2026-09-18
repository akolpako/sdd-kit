---
name: java-core
description: 'Java language rules independent of any framework: language level, null and Optional, time and money, exceptions, collections, streams, equality, concurrency, resources. Use when writing or reviewing Java code.'
---

# Java Core

Rules for the language itself. Framework, persistence and unit-test rules are in their own skills.

## Language Level

- **Check the level the build declares** before using a construct.
- **Sealed interfaces** for a closed set of subtypes. An exhaustive `switch` then needs no default branch.
- **`var`** only when the initializer already names the type.

## Null and Optional

- **`Optional` is a return type.** Never a field, a parameter, or an element in a collection.
- **`orElseThrow()`, never `get()`.**
- **Unboxing hides a null check.** `Integer` to `int`, or a `Boolean` in an `if`, throws an NPE with no message. Compare with `Objects.equals`.

## Time and Money

- **`Instant`** for a moment in time. **`LocalDate`** for a date without time. **`ZonedDateTime`** only when the zone carries meaning.
- **`LocalDateTime` has no zone**, so it is not a moment. Do not store it for something that happened.
- **Inject a `Clock`** instead of calling `Instant.now()` inside the logic, so a test can fix time.
- **`BigDecimal` for money.** Build it from a `String`, never from a `double`. State `RoundingMode` on every operation. Compare with `compareTo`: `equals` also compares scale.

## Exceptions

- **Rethrow with the cause:** `throw new OrderFailed("...", e)`. Dropping `e` deletes the stack trace.
- **The message says what failed**, not what the exception class is called.
- **An empty `catch` is a bug.** So is one that only logs and continues: the caller keeps running on state that was never produced.
- **Log or rethrow, not both.** Otherwise one failure is reported once per layer.
- **Nothing is thrown from `finally`.** It replaces the exception in flight, and the real failure is lost.
- **`InterruptedException`:** rethrow it, or call `Thread.currentThread().interrupt()` before returning.
- **`assert` is not validation.** Assertions are off at runtime by default, so the check never runs. Throw.

## Collections and Streams

- **Streams transform, they do not act.** A `forEach` that changes something outside the stream is a badly written loop. Write the loop.
- **Use a loop when it reads better.** A stream is not the goal.
- **`parallelStream()` never wraps IO or a blocking call.** It runs on one pool shared by the whole JVM.
- **Return a copy or an unmodifiable view** of internal state, never the field itself.
- **`computeIfAbsent`** instead of get-check-put.

## Equality

- **The fields `equals` and `hashCode` are built from do not change** while the object sits in a `HashSet` or serves as a `HashMap` key.
- **`compareTo` agrees with `equals`.** A `TreeSet` deduplicates by the comparator, so a mismatch silently drops elements.

## Concurrency

- **Every piece of mutable state has one named owner** — the thread that may touch it, or the lock that guards it. Write it down.

## Resources

- **`try-with-resources` for anything `AutoCloseable`** — streams, readers, connections, `Files.lines`.
- **Close a `Stream` a library hands over as a cursor.**
