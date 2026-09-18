# Protocol: interview

*Addressed to the agent asking the questions. It names no command and no agent.*

How a spec-writing role asks the human: the role produces questions, the answers come back, the role updates its spec file. Transport is a property of the environment; how the questions are asked is fixed here.

**A question lives on the page, never in a context.** The role writes it into `## Open Questions` of its own file, in the shape `.sdd/protocols/spec-modes.md` fixes; it is asked from there and the answer is written back onto the same line. Nothing is carried between passes in anyone's memory, so a review interrupted after the answers arrive resumes from the file.

- **One question per message.** The next question goes out after the previous one is answered.
- **Every question carries a recommended answer** and the one line of reasoning behind it. Agreeing must cost one word.
- **Facts are the role's job; decisions are the human's.** What the code already does, what `raw.md` says, how an existing module behaves — the role finds that out itself and never spends a question on it — by searching and reading this repository, and beyond it with the retrieval skill available to it. Trade-offs, priorities, and scope are what the human is for.
- **Dependency order.** Write first the question whose answer changes the later ones, and ask them in that order. Nothing waits: the pass puts every question it has on the page at once, and a question another answer makes irrelevant is dropped by the pass that folds that answer in.
- **At most three rounds per spec file, per session.** What is still open after the third round is not asked a fourth time: it becomes an `A-##` assumption or a line in `## Open Questions`, and the verdict accounts for it. The count belongs to the run and the page carries no counter, so a review re-run after an interruption counts from zero: three rounds bound one run, never the feature.
- A role never answers its own question by guessing, and the review does not close until the human has confirmed the shared understanding of what is being built.
