---
name: java-jpa
description: 'JPA and Hibernate rules: entity design, relationships, fetching and N+1, projections, locking, caching, schema, diagnosing slow persistence. Use when writing or reviewing JPA entities, queries, or the relational schema.'
---

# JPA and Hibernate

Rules for entities and the persistence context. Repositories, transactions and migrations are in the `java-springboot` skill.

## Entities

- **`equals` and `hashCode` on a stable business key**, or not overridden at all. Never on a generated id: it is null until the first flush.
- **The transaction is the lifetime of the persistence context.** Inside it, a loaded entity is
  tracked and a changed field is written back without a save call. Outside it, the same object is
  detached: changes go nowhere and a lazy association throws.
- **Build the DTO inside the transaction**, before the entities detach.
- **Auditing through `@CreatedDate` and `@LastModifiedDate`** and their `@...By` pairs, not by setting fields by hand.

## Relationships

- **`@ManyToOne` and `@OneToOne` are eager by default.** Set `FetchType.LAZY` on both.
- **Lazy on a `@OneToOne` only holds on the owning side, and only with `optional = false`.** On the `mappedBy` side Hibernate has to query to learn whether the association is null, so it loads it whatever the mapping says. Map the pair as `@ManyToOne`, or expect that query.
- **`CascadeType.REMOVE` and `orphanRemoval` only for real ownership** — a child that cannot exist without its parent.
- **Never cascade towards a shared entity.** Deleting an order must not delete the customer.
- **Inheritance is a deliberate choice.** `SINGLE_TABLE` is fast but forces nullable columns; `JOINED` keeps constraints but adds a join.

## Fetching

- **N+1 is the default failure.** A lazy association touched once per row runs one query per row.
- **Fix it with a fetch join, an `EntityGraph`, or `@BatchSize`** — never by making the mapping eager.
- **`spring.jpa.open-in-view` stays off.** It hides N+1 and lazy errors by keeping the session open until the response is written.

## Queries and Projections

- **An interface or record projection instead of a whole entity** on a read-only path.
- **A `Stream` result is a cursor.** Consume it inside `try-with-resources` and inside the transaction.
- **Bulk changes are one statement.** Loading a million rows to flip a flag is not an option.

## Locking

- **`@Version` on anything two users can edit at once.**
- **Pessimistic locks stay short and ordered.** Take them in the same order everywhere, or two transactions deadlock.

## Caching

- **The second-level cache is opt-in per entity**, for data read often and changed rarely.
- **Never cache what another system writes.** The copy goes stale with no way to notice.

## Schema

- **`ddl-auto` past `validate` runs on a local machine only.** Production schema comes from migrations.

## Diagnosing

- **Count the queries, do not guess.** Turn on statement logging and read one request end to end.
- **`LazyInitializationException` names the association touched too late.** Fetch it in the query, or return a projection.
