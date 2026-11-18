# Protocol: spec modes

*Addressed to the agent writing a spec file. It names no command and no agent.*

You work in a mode, and the assignment states which one. If none is stated, work in `draft`.

| Mode | Questions to the human | File |
|------|------------------------|------|
| `draft` | Never asked | Always written |
| `review` | Asked, then answered by the human | Updated after the answers arrive |

- In `draft` the file is always written and the human is never asked. A point the role decided itself becomes `- A-## Assumption (needs validation): <text>` in `## Assumptions`; a point only the human can settle becomes a line in `## Open Questions`, naming the option taken meanwhile and the `A-##` it produced.
- In `review` the file is not finalized while critical points are unanswered. A confirmed assumption becomes `- A-## Assumption (confirmed <YYYY-MM-DD>): <text>`; an answered Open Question leaves the section and is folded into the requirement or design it belongs to.
- In `review` the `status` property is not yours: leave it as it stands in every file you touch. Whoever led the review writes it, after the verdict.
- Never invent silently, in either mode: anything decided without confirmation is written down as an assumption.

## The `## Open Questions` section

A question is one line, and the line is the question: no ID of its own, no status word. It names the option taken meanwhile and the `A-##` it produced. The answer is appended to the line it answers, and nothing else is ever added to a line:

```markdown
- Which currencies must the cart total support? — recommended: EUR only, A-03
- Does the promo code stack with a member discount? — recommended: no, A-04 **Answer:** yes, but never below cost
```

What goes on the page as a question:

- **A decision, never a fact.** What the code already does, what `raw.md` says, how an existing module behaves — find it out yourself, by reading this repository and, beyond it, with the retrieval skills available to you. Trade-offs, priorities and scope are what the human is for.
- **A recommended answer and the one line of reasoning behind it**, so agreeing costs one word.
- **Dependency order.** The question whose answer changes the others comes first. Put every question on the page at once; one that another answer makes irrelevant is dropped by the pass that folds that answer in.
- A question is never answered by guessing: what you decided meanwhile is the `A-##` the line names, and it stays an assumption until the answer arrives.
- **No question, no line.** A file with nothing to ask keeps the heading and nothing under it. "None", "None beyond those in …" or a pointer to another file is a line, every line there is read as an open question, and the file cannot be set `ready` while it stands.

`**Answer:**` on the line is the whole discriminator. A line carrying it is settled: fold it into the requirement or design it belongs to, retire the `A-##` it names, and delete the line. A line without it is still open and stays exactly as it is — its wording is the role's, and a question reworded on the way through is a question that silently changed.

## Gaps

A gap is anything the inputs leave unsettled — a domain term, a constraint, an edge case, an integration boundary, a contradiction. Every gap is handled according to the mode above.

## Writing the file

- Every spec file you write is already on disk at the path the assignment names, in the structure it must keep — read that file before writing it, and match the structure exactly. Nothing has to be found in `.sdd/templates/`. A generated file drops the `<!-- ... -->` hints it was scaffolded with; only a file the engine scaffolds for the human to fill in keeps them.
- No placeholders — `[TODO]`, `[TBD]`, `[PLACEHOLDER]` are never written into a section. Whatever is not decided becomes an `A-##` assumption or a line in `## Open Questions`.
- No vague wording — "fast", "properly", "efficiently", "user-friendly" — unless the term carries the number that measures it.
