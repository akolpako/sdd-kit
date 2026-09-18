---
title: Fixture style for test data
description: Use when writing Fixture classes for test-data construction
keywords: fixture, test data builder, object mother, test data factory, withXxx, build, data carrier, DTO, entity, value object, composing fixtures, mock
---

# Fixture style for test data

> **Default style.** Apply this Fixture style whenever the project does **not** already define its own test-data preparation style.
> Data-carrier types (DTOs, value objects, entities) are [never mocked](junit-rule-real-data-carriers.md) regardless of style.

`Fixture` classes encapsulate test-data setup. They keep test methods focused on assertions and centralize a single point of change when a domain type evolves.

## Decision flow

```
Need an instance of a data-carrier type
(value object, API model, DTO, POJO, JPA/persistence entity)?
│
├─ A Fixture already exists for it?
│      → Use it.
│
├─ Trivial to construct (1–2 self-explanatory args, or a domain factory)?
│      → Construct directly: new ID(42), new Email("a@b.c"), Currency.of("CHF"), Status.active().
│
└─ Anything else (3+ fields, builder/setters, or reused across tests)?
       → Create a Fixture.
```

Note: `mock(...)` is **not** a factory method.

## Hard rules

1. **If a Fixture exists for the target type, you must use it.** Never call `new`, the builder, or setters directly in a test — even to "save a line" or because defaults are inconvenient.
2. **If no Fixture exists** and the type qualifies (decision flow above), create one before writing the test.
3. **Objects returned by `Fixture.build()` must not be mutated** — no setters, no field reassignment. Configure state via `withXxx()` before `build()`.
4. **If a needed customization is missing, add a new `withXxx()` to the Fixture.** Do not work around it.

## Standard Fixture (target has a builder)

```java
public final class EntityFixture {

    private final Entity.Builder builder;

    private EntityFixture() {
        this.builder = Entity.builder();
    }

    public static EntityFixture person() {
        return new EntityFixture()
                .withId(1L)
                .withLinkId(2L)
                .withDiscriminator("PERSON");
    }

    // company() — a second domain-distinct factory — same shape

    public EntityFixture withId(long id) { this.builder.id(id); return this; }
    public EntityFixture withLinkId(long linkId) { this.builder.linkId(linkId); return this; }
    public EntityFixture withDiscriminator(String d) { this.builder.discriminator(d); return this; }

    public Entity build() {
        return builder.build();
    }
}
```

A Fixture's `withXxx()` methods are driven by what tests need, not by the domain builder's shape: expose only the customizers tests actually use; a method may set several fields together, carry a scenario name (e.g. `expired()`, `withFullAddress(...)`), or differ from the underlying builder where that reads better in a test.

## Fixture for types without a builder

Same shape: the Fixture holds plain fields with sensible defaults, each `withXxx(...)` reassigns one, and `build()` constructs the target (e.g. `new Address(street, houseNumber, zipCode)`).

## Composing fixtures

When a Fixture builds an object that contains other data-carrier types, compose the *nested Fixtures* instead of inlining `new`/builder calls or holding an already-built instance.
Keep the nested Fixture as the field, default it to a sensible Fixture, and build it inside `build()`:

```java
public final class OrderFixture {

    private CustomerFixture customer = CustomerFixture.create();
    private AddressFixture shipTo = AddressFixture.create();

    private OrderFixture() {}

    public static OrderFixture create() {
        return new OrderFixture();
    }

    public OrderFixture withCustomer(CustomerFixture customer) { this.customer = customer; return this; }
    public OrderFixture shippingTo(AddressFixture shipTo) { this.shipTo = shipTo; return this; }

    public Order build() {
        return new Order(customer.build(), shipTo.build());
    }
}
```

This preserves the single-point-of-change guarantee across object graphs: when `Customer` changes shape, only `CustomerFixture` is touched — `OrderFixture` is unaffected.
Scope this to nested types that warrant a Fixture; trivial value objects still follow the decision flow (direct construction).
A `withCustomer(Customer)` overload is acceptable only when a test needs a specific pre-built instance (e.g. to assert on object identity); composing the Fixture is the default.

## Conventions

| Element | Rule |
|---|---|
| Class name | `<TargetType>Fixture` |
| Class modifier | `final`, private constructor |
| Factory methods | One per domain-distinct kind of object (`person()`, `company()`); `create()` when there is only one. Variants of the same kind that differ merely in field values use `withXxx()`, not another factory. |
| Customization | Fluent `withXxx(...)` per field, returning `this` |
| Build method | `build()` returns the target type |
| Location | If no project rule for that, then a dedicated `fixture` subpackage (e.g. `com.example.service.fixture`) |

## Placement and sharing

- **If the project already has Fixtures,** put new ones alongside the existing ones and follow the project's established location and naming. Do not introduce a parallel convention.
- **If there are none yet,** keep the Fixture in the same module as the type it builds, under that module's test sources. When the type is shared by several modules and its Fixture is needed in more than one of them, do not copy the Fixture — publish the module's test fixtures as a reusable test artifact (a test JAR) and let the consuming modules depend on it.

Visibility follows reach: a Fixture shared across modules is `public`; one used only within its own module may stay package-private.
