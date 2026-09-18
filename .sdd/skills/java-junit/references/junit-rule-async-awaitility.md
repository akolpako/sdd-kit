---
title: Never use Thread.sleep; use Awaitility for async
description: Use when testing asynchronous outcomes
keywords: async, awaitility, await, until, untilAsserted, Thread.sleep, sleep, polling, flaky, timeout, atMost, CompletableFuture, concurrency
---

# Never use `Thread.sleep`; use Awaitility for async

`Thread.sleep(...)` / `TimeUnit.SECONDS.sleep(...)` (any `TimeUnit`) are forbidden in tests — they are slow, flaky, and hide the awaited condition.
For an asynchronous outcome, poll with a bounded timeout:

- Prefer `untilAsserted` over `until` — it surfaces the AssertJ diagnostic on failure instead of a generic timeout.
- Always set `atMost(...)` explicitly (smallest duration safe on a loaded CI machine); don't rely on the 10s default. Leave `pollInterval` at default; use `pollDelay(ZERO)` when the condition can hold immediately.
- Don't wrap _synchronous_ calls in `await` to mask flakiness — fix the cause.
- If the SUT sleeps internally (retry/backoff), inject the timing (`Clock` / `Sleeper` / `Duration`) and stub it — a real sleep in a unit test means a wrong test or a wrong design.

```java
await().atMost(ofSeconds(2))
        .untilAsserted(() -> assertThat(handler.getProcessed()).containsExactly(event));
```
