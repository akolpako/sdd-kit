---
title: Custom AssertJ Asserts for repeated domain checks
description: Use when creating or extending a <Type>Assert class, or when the same assertion chain repeats across tests
keywords: custom assert, AbstractAssert, AbstractIterableAssert, AbstractObjectAssert, assertThat, domain assertion, assertion helper, reuse, navigation, composition, toAssert, singleElement, recursive comparison, comparator, failWithMessage
---

# Custom AssertJ Asserts for repeated domain checks

> **Default style.** Apply it whenever the project does **not** already define its own way of sharing assertion logic.
> The [AssertJ rules](junit-rule-assertj-only.md) still hold inside an Assert: most specific assertion, no JUnit-native ones.

A `<Type>Assert` is the Assert-side counterpart of a [Fixture](junit-rule-fixtures.md): one place that knows how to check a domain type, so a test reads in domain terms and a change to the type touches one class.

## Decision flow

```
Need to check a domain type in a test?
│
├─ An Assert already exists for it?
│      → Use it. Missing check → add a method to that Assert.
│
├─ The check is a one-off, or repeats only inside one test class?
│      → Plain AssertJ in the test; a private helper for the repeats.
│
└─ The same chain repeats in 2+ test classes, or the check is non-trivial
   (recursive-comparison config, custom comparator, extracting into tuples,
    filtering a collection down to one element)?
       → Create or extend <Type>Assert.
```

## Hard rules

1. **If an Assert exists for the type, you must use it.** Never rebuild one of its checks with plain AssertJ in a test.
2. **An Assert never duplicates a check owned by another Assert.** It calls that Assert ([composition](#composing-asserts)).
3. **Check by delegating to AssertJ, not by hand.** A check method calls `isNotNull()`, then an AssertJ assertion described with `.as("<what> of %s", subject())` ([descriptions](#descriptions)), then returns `this`. Avoid `if (...) failWithMessage(...)`: you would have to write the diagnostic yourself, and AssertJ already writes a better one.
4. **No loops over elements.** Use `allSatisfy`, `extracting(...)`, `filteredOn(...)` and the element Assert.
5. **No expected values computed inside the Assert.** The test passes [literal expected values](junit-rule-literal-expected-values.md); the Assert only compares.
6. **Navigation returns an Assert, never the raw value.** `customer()` returns `CustomerAssert`, not `Customer`.
7. **No aliases.** One check, one method name.

## Composing Asserts

Asserts reuse each other in four ways. All four keep each check in exactly one class.

| Pattern | Shape | Use when |
|---|---|---|
| **Navigation** | `customer()` returns `CustomerAssert` with a description naming the parent | The test goes on to check the child |
| **Delegation** | `isPlacedBy(id)` calls `customer().hasId(id)` and returns `this` | The parent chain must continue after the child check |
| **Element Assert** | a collection Assert extends `AbstractIterableAssert` with `toAssert` returning the element Assert; `singleElement()`, `first()`, `element(i)` and `filteredOn(...)` then give typed element Asserts | Checks on a collection of a type that has an Assert |
| **Internal reuse** | `isPaid()` calls `hasStatus(PAID)` | A domain shortcut for a frequent parameter value |

Navigation is one-way: the chain goes on with the child Assert and cannot return to the parent. Order the chain so parent checks come first, or use delegation.

Comparison config (recursive-comparison settings, tolerant comparators for timestamps or money) belongs to the Assert of the type it compares. Other Asserts call that Assert's method, e.g. `hasSameStateAs(...)`; they never rebuild the config.

## Descriptions

A check that starts a fresh `Assertions.assertThat(...)` drops the description the Assert already carries: the one set by a navigation method, by `toAssert`, or by `.as(...)` in the test. A failure then no longer says which parent the object belongs to.

Every Assert therefore has a private `subject()` that names the object and appends the incoming description, and every check is described as `"<what> of %s", subject()`:

```java
private String subject() {
    String self = "customer " + actual.id();
    return descriptionText().isEmpty() ? self : self + " (" + descriptionText() + ")";
}
```

`OrderAssert.assertThat(order).customer().hasId(...)` then fails with `[id of customer 7 (customer of order 5)]` instead of `[id of customer]`.
Methods inherited from the AssertJ base class (`extracting`, `allSatisfy`, `filteredOn`, `singleElement`) keep the description on their own.

## Example

```java
public final class OrderAssert extends AbstractAssert<OrderAssert, Order> {

    private static final Comparator<BigDecimal> BY_VALUE = BigDecimal::compareTo;

    private OrderAssert(Order actual) {
        super(actual, OrderAssert.class);
    }

    public static OrderAssert assertThat(Order actual) {
        return new OrderAssert(actual);
    }

    public OrderAssert hasStatus(OrderStatus expected) {
        isNotNull();
        Assertions.assertThat(actual.status())
                .as("status of %s", subject())
                .isEqualTo(expected);
        return this;
    }

    public OrderAssert isPaid() {
        return hasStatus(OrderStatus.PAID);
    }

    public CustomerAssert customer() {
        isNotNull();
        return CustomerAssert.assertThat(actual.customer())
                .as("customer of %s", subject());
    }

    public OrderAssert isPlacedBy(CustomerId expected) {
        customer().hasId(expected);
        return this;
    }

    public OrderLinesAssert lines() {
        isNotNull();
        return OrderLinesAssert.assertThat(actual.lines())
                .as("lines of %s", subject());
    }

    public OrderAssert hasSameStateAs(Order expected) {
        isNotNull();
        Assertions.assertThat(actual)
                .as(subject())
                .usingRecursiveComparison()
                .ignoringCollectionOrder()
                .withComparatorForType(BY_VALUE, BigDecimal.class)
                .isEqualTo(expected);
        return this;
    }

    private String subject() {
        String self = "order " + actual.id();
        return descriptionText().isEmpty() ? self : self + " (" + descriptionText() + ")";
    }
}
```

```java
public final class OrderLinesAssert
        extends AbstractIterableAssert<OrderLinesAssert, Collection<OrderLine>, OrderLine, OrderLineAssert> {

    private OrderLinesAssert(Collection<OrderLine> actual) {
        super(actual, OrderLinesAssert.class);
    }

    public static OrderLinesAssert assertThat(Collection<OrderLine> actual) {
        return new OrderLinesAssert(actual);
    }

    @Override
    protected OrderLineAssert toAssert(OrderLine value, String description) {
        return OrderLineAssert.assertThat(value).as(description);
    }

    @Override
    protected OrderLinesAssert newAbstractIterableAssert(Iterable<? extends OrderLine> iterable) {
        List<OrderLine> lines = new ArrayList<>();
        iterable.forEach(lines::add);
        return assertThat(lines);
    }

    public OrderLinesAssert containsExactlySkus(Sku... expected) {
        isNotNull();
        extracting(OrderLine::sku).containsExactlyInAnyOrder(expected);
        return this;
    }

    public OrderLinesAssert areAllReserved() {
        isNotNull();
        allSatisfy(line -> OrderLineAssert.assertThat(line).isReserved());
        return this;
    }

    public OrderLineAssert line(Sku sku) {
        isNotNull();
        return filteredOn(line -> line.sku().equals(sku)).singleElement();
    }
}
```

`OrderLineAssert` (`hasQuantity`, `isReserved`) and `CustomerAssert` (`hasId`) have the same shape as `OrderAssert`, each with its own `subject()`.

Usage: parent checks first, then navigation:

```java
OrderAssert.assertThat(order)
        .isPaid()
        .isPlacedBy(new CustomerId(7L))
        .lines()
        .containsExactlySkus(new Sku("A-1"), new Sku("B-2"))
        .line(new Sku("A-1"))
        .hasQuantity(2);
```

## Anti-patterns

```java
// ❌ Don't — child check rebuilt in the parent
public OrderAssert isPlacedBy(CustomerId expected) {
    Assertions.assertThat(actual.customer().id()).isEqualTo(expected);
    return this;
}
// ✅ Do — reuse the child Assert
public OrderAssert isPlacedBy(CustomerId expected) {
    customer().hasId(expected);
    return this;
}

// ❌ Don't — hand-written check and loop
for (OrderLine line : actual.lines()) {
    if (!line.reserved()) {
        failWithMessage("Expected line <%s> to be reserved", line.sku());
    }
}
// ✅ Do — element Assert via the collection Assert
lines().areAllReserved();

// ❌ Don't — private void helper copied across test classes (one used by a single test class may stay)
private static void assertPaidBy(Order order, CustomerId customerId) { ... }
// ✅ Do — a method on OrderAssert

// ❌ Don't — navigation returning the raw value
public Customer customer() { return actual.customer(); }

// ❌ Don't — alias of an existing method
public OrderAssert hasPaidStatus() { return isPaid(); }
```

## Conventions

| Element | Rule |
|---|---|
| Class name | `<TargetType>Assert`; collection Assert named with the plural of the type (`OrderLinesAssert`, `AddressesAssert`) |
| Base class | `AbstractAssert<SELF, T>`; `AbstractIterableAssert<SELF, Collection<T>, T, TAssert>` for a collection of a type that has an Assert |
| Class modifier | `final`, private constructor |
| Entry point | `public static <Type>Assert assertThat(<Type> actual)`; in tests call it class-qualified (`OrderAssert.assertThat(...)`) so it does not clash with the static import of `Assertions.assertThat`. A project-wide entry point that extends `Assertions` may add `assertThat` overloads for single domain types only. An overload for a collection type does not compile: it clashes by erasure with `Assertions.assertThat(Collection)` and is ambiguous for a `List` argument. |
| Check method | `hasX(expected)` / `hasNoX()` / `isX()` / `hasExactlyX(...)` / `containsX(...)`, domain wording; returns `this` |
| Navigation method | Noun for the child (`customer()`, `lines()`, `line(sku)`); returns the child Assert with `.as("<child> of %s", subject())` |
| Description | Every delegated assertion carries `.as("<what> of %s", subject())`; `subject()` is the type, its identifier and the incoming description |
| Location | If no project rule for that, then an `assertion` subpackage next to the `fixture` one |

## Placement and sharing

Same as [Fixtures](junit-rule-fixtures.md#placement-and-sharing): follow the project's existing location for Asserts. Without one, keep each Assert in the module of the type it checks, under test sources. An Assert needed by several modules goes into the shared test-fixtures artifact (test JAR or test-utils module); it is never copied. Integration tests reuse the same Asserts.

An Assert with its own logic (tolerant comparator, filtering, recursive-comparison config) gets its own test, including a failing case: `assertThatExceptionOfType(AssertionError.class).isThrownBy(() -> OrderAssert.assertThat(order).hasSameStateAs(other))`.
