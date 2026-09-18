---
type: raw
feature: <FeatureName>
tags:
  - sdd/raw
---

# <FeatureName>

<!-- The human's description of the feature, and the only input everything else
is derived from. Prose is fine — this is not a form to satisfy, it is the place
to say what you already know. What you leave out gets asked about later, or
assumed. -->

## Problem

<!-- What hurts today. The situation without this feature: who is blocked, what
they do instead, what it costs. State the problem, not the solution — "orders
cannot be cancelled after checkout, support does it by hand in the database",
not "add a cancel button". -->

## Users

<!-- Who this is for and what they are trying to get done. Name the roles that
already exist in the product where you can; a new role is worth calling out as
new. If different users see the feature differently, say so — that difference
usually turns into separate requirements. -->

## What the feature does

<!-- The behaviour you want, in the words of the person using it. Enough for
someone who has never seen the feature to picture the result. Known error
situations belong here too — what should happen when it goes wrong is part of
what the feature does. -->

## Out of scope

<!-- What this feature explicitly does NOT include, especially the things a
reader would reasonably assume it does. This is the cheapest section in the
file: every line here is work that will not be specified, built, or argued
about later. -->

## Known constraints

<!-- Anything that limits the solution and is not negotiable: deadlines,
external systems to integrate with, data that cannot move, compatibility to
keep, legal or security rules, expected load. Architectural constraints that
hold for the whole project belong in the architecture baseline instead — put here
only what is specific to this feature. -->

## Open questions

<!-- What you know you do not know yet, one line each, with who could answer it
if you know. This section is read directly: a question written here is a
question the engine does not have to discover, and an answer it will not
invent. Leaving it empty claims everything is settled. -->
