# Protocol: the format of `_docs/`

*Addressed to any role that writes a file under `_docs/`. It names no command and no agent.*

Every file under `_docs/` is Obsidian Flavored Markdown. This protocol says which of its syntax the specs use, and where. An Obsidian Markdown skill installed in the project carries the rest; where the two differ, this protocol wins — it is written against a repository that is read in Obsidian, in an editor, and on a repository page, and the skill is written for a vault alone.

## Links: Markdown, never wikilinks

**Do not write `[[wikilinks]]` and do not write `![[embeds]]`,** though Obsidian offers both. A spec is read in three places, and a wikilink resolves in only one of them: outside Obsidian it stays on the page as literal brackets. Every link is a Markdown link with a relative path:

```markdown
See [REQ-014](../requirements.md#^req-014).
See [the API section](../architecture/06-api-spec.md).
```

- **The path is relative to the file the link is written in**, so it resolves for a reader in Obsidian and for one on a repository page alike.
- **The link text carries the identifier**, never a bare "here" or "this section": `[REQ-014](…)`, `[API Spec](…)`. A reader with no vault open still reads what the link points at.
- **An anchor to a requirement is its block id** — `#^req-014`, the id in lower case. Obsidian resolves it to the line; every other reader lands on the file, which is the right file. An anchor to a heading is `#The Heading`, and it is worth less: rename the heading and the link is silently dead.
- **A path in prose is not a link.** `.sdd/protocols/…` and the paths an assignment names stay plain code spans: they are addressed to a role, which opens them by path.

## Properties

Every file opens with YAML frontmatter. What each type carries is fixed by its template, and the templates are the reference — a file is scaffolded with its properties already in place, and a role fills in values rather than inventing keys.

| File | Properties |
|------|-----------|
| `raw.md` | `type: raw`, `feature`, `tags` |
| `new-requirements.md` | `type: requirements`, `feature`, `status`, `tags` |
| `design.md` | `type: design`, `feature`, `status`, `tags` |
| `tasks.md` | `type: tasks`, `feature`, `status`, `tags` |
| `review.md` | `type: review`, `feature`, `reviewed`, `base`, `root`, `verdict`, `tags` |
| `requirements.md` | `type: requirements-compilation`, `tags` |
| `code-style.md` | `type: code-style`, `tags` |
| the architecture baseline | `type: architecture` or `architecture-section`, `tags` |
| `architecture.index.md` | `type: architecture-index`, `tags` — written whole by `spec-edit.sh arch-index`, never by hand |

Three rules hold for every one of them:

- **`status` and `verdict` are the engine's fields.** The engine reads them, and `spec-edit.sh` writes them. A role writes `status: draft` when it creates a file and never promotes one to `ready` — that is `/sdd-spec-review`'s, through the script.
- **A value carrying a colon is quoted.** `verdict: "BLOCKED: no tests"` — unquoted, YAML reads the first colon as the end of the key and the property is lost.
- **A property is never invented.** A fact worth recording that no property holds belongs in the body of the document, where a reader will find it.

## Callouts

A callout is for a thing a reader must not scroll past. Used everywhere it stops meaning anything, so the specs use it in three places and nowhere else:

- **A finding in `review.md`**, its type carrying the severity: `> [!danger]` Critical, `> [!warning]` Major, `> [!note]` Minor, `> [!tip]` Suggestion.
- **A warning about what the reader is about to act on** — a decision that costs something either way, a contract that breaks a caller, a step that cannot be undone: `> [!warning]`, with the cost in it.
- **An example that is long enough to lose the thread of the section** — a request and response pair, a worked case: `> [!example]-`, folded.

Not for section intros, not for restating a heading, and never nested more than one deep.

## The rest of the syntax

- **`==highlight==` marks a term where it is defined**, once, in the document that defines it. Everywhere after it is plain text. Highlighting for emphasis makes the definition unfindable.
- **HTML comments, never `%%`.** `<!-- Next free number: REQ-014 -->`, `<!-- REVIEW: … -->` and the hint comments of the templates are read by the engine's scripts, which know `<!-- -->` and nothing else. Obsidian hides both.
- **Mermaid as the templates already use it** — `mermaid C4Context`, `erDiagram`, `sequenceDiagram`, `graph TD`. Obsidian renders these natively; no plugin is assumed and no other diagram syntax is introduced.
- **Tags are the ones the templates carry.** The `sdd/…` set is what makes a vault-wide search find every design or every review; a tag invented per feature makes that search miss one.
- **Tasks are `- [ ]` and `- [x]`**, the format `tasks.md` fixes. Obsidian renders them as checkboxes, and the engine counts them — neither tolerates a variation.
- **No footnotes and no math** in a spec. Both render, and neither has said anything a sentence could not.
