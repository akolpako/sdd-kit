---
name: java-springboot
description: 'Spring Boot practices: project setup, dependency injection, proxies, configuration, web layer, services and transactions, repositories, migrations, async work, outgoing calls, health and metrics, integration testing, security. Use when writing or reviewing Spring Boot code.'
---

# Spring Boot

## Project Setup

- **Versions come from the Boot BOM.** A managed library is declared without a version. Pinning one by hand creates conflicts instead of solving them.
- **Package by feature**, not by layer: `com.example.app.order`, not `com.example.app.service`.

## Dependency Injection

- **Constructor injection** for required dependencies. No `@Autowired` on fields.
- **Fields are `private final`.**
- **A bean is one instance shared by every request thread.** Mutable state on a controller, service, filter or component is a race.
- **A circular dependency means a responsibility sits in the wrong class.** Move it. Do not reach for `@Lazy`.

## Proxies

Spring applies `@Transactional`, `@Async`, `@Cacheable`, `@Retryable` and `@PreAuthorize` through a proxy.

- **A call from inside the same class does nothing** — no transaction, no cache, no retry, no check, and no error either. Move the method to another bean.
- **A final class or a final method cannot be proxied.** The annotation is silently dead.

## Configuration

- **`application.yml`** holds settings; **`@ConfigurationProperties`** binds them to a typed object.

## Web Layer

- **DTOs in and out.** Never a persistence entity.
- **Validate the DTO** with `@Valid` and Bean Validation annotations.
- **One `@ControllerAdvice`** maps exceptions to responses.

## Service Layer

- **`@Transactional` on the service method that owns the unit of work.** Never on a controller.
- **`readOnly = true`** on a method that only reads: an ORM then skips dirty checking.
- **Test the rollback**, not only the happy path.

## Repositories

These rules hold for every Spring Data store. The repository interface of a given store, and the query language it speaks, are that store's own skill.

- **Paginate every query over a collection that grows.** Take `Pageable`, return `Page` or `Slice`. A method that returns everything works on test data and dies on production data.
- **A derived method name until it stops being readable**, then `@Query`.

## Migrations

For a relational database. A store without a schema still versions its documents, in that store's own skill.

- **Every schema change ships as a migration script**, ordered and idempotent.
- **An applied migration is never edited.** A correction ships as a new script.

## Async and Scheduled Work

- **Nothing propagates into `@Async` or `@Scheduled`** — no transaction, no security context, no request scope. Pass what the work needs as arguments.
- **Handle failure where it runs.** Nobody reads the return value.
- **Bound the executor.** The default starts a thread per call.
- **A scheduled job needs a lock** when more than one instance runs.

## Calls Out of the Process

- **A connect timeout and a read timeout on every client**, and on the connection pool. Waiting forever is how one slow dependency exhausts the threads.
- **Retry only idempotent calls**, with a limit on attempts.

## Health and Metrics

- **Readiness and liveness answer different questions.** Readiness fails while a dependency is down; liveness only when the process itself is broken. Wiring them together restarts a healthy instance because the database blinked.
- **A custom `HealthIndicator` checks a dependency the service cannot work without**, and does it with a timeout.
- **Micrometer for metrics.** Tag values stay a small fixed set: a user id in a tag creates one time series per user.

## Integration Testing

Unit tests belong to the `java-junit` skill. These are the tests it excludes.

- **`@SpringBootTest`** when the whole context is needed.
- **Slices otherwise:** `@WebMvcTest` for controllers, `@DataJpaTest` for repositories.
- **Testcontainers** for a real database or broker.

## Security

- **BCrypt or stronger** for passwords.
- **Never log a secret, a token, or personal data.**
