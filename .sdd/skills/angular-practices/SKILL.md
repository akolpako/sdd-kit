---
name: angular-practices
description: 'Project gates for Angular that the framework does not enforce: change detection, state ownership, subscription lifetime, template bindings, route-level code splitting. Use when writing or reviewing Angular components, services and routes.'
---

# Angular Practices

Rules this project holds Angular code to. The framework reference — components, signals,
forms, DI, routing, testing, CLI — is an installed Angular skill, if the project has one;
nothing here repeats it.

## Change Detection

- **`ChangeDetectionStrategy.OnPush` on every component.** The CLI does not add it, so it is
  added by hand. It is also the prerequisite for running zoneless.
- **Under `OnPush`, a value that changes in place does not render.** Pushing into an array or
  assigning a field of an object leaves the reference untouched, and the view keeps the old
  value with no error anywhere. Hold that state in a `signal` and `set` a new value.

## State Ownership

- **State lives with the thing that uses it.** A service given `providedIn: 'root'` is one
  instance for the whole application. That is the right default for *where a service is
  provided*; it is not a reason to make a piece of state application-wide. Passing a value
  from a parent to a child is an input, not a store.
- **Application-wide state outlives the screen.** Navigation does not reset it, so the second
  visit to a feature opens on the values the first visit left behind — a filter still applied,
  a half-filled form, a stale id. State that belongs to one screen is provided on that route
  or that component, where destroying the screen destroys the state.

## Subscription Lifetime

- **A subscription that outlives its component is a leak** — the callback keeps firing against
  a destroyed view, and the component is never collected. Nothing warns about it.
- **Prefer no subscription at all.** `httpResource` for a request, `toSignal` for a stream
  someone else owns. Neither needs unsubscribing.
- **When a subscription is unavoidable, end it with the injection context:**
  `.pipe(takeUntilDestroyed())` in a field initializer or constructor, or
  `takeUntilDestroyed(inject(DestroyRef))` anywhere else.
- **`async` in a template is already safe.** It unsubscribes on destroy.

## Template Bindings

- **No plain method call in a binding.** `{{ computeTotal() }}` re-runs on every change
  detection pass and cannot be cached. Derive it once with `computed()` and read the signal:
  `{{ total() }}`. The two look alike in a template — a signal read is cheap, a method is not.
- **Keep logic out of the template.** A condition worth a comment belongs in a `computed()`
  the template reads by name.

## Routes

- **Split at the feature boundary.** A feature route is loaded with `loadComponent` or
  `loadChildren`, so its code and its dependencies stay out of the initial bundle.
- **A heavy dependency behind an eager route is the failure this prevents** — a charting or
  editor library reachable from one screen is downloaded by every visitor.
