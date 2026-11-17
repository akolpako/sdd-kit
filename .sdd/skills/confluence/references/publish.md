# Confluence — publishing

Part of the `confluence` skill; `scripts/` paths are relative to the skill's directory, and the config (`--tokens`) is taken as `SKILL.md` says.

```bash
scripts/confluence-publish.sh create --space <KEY|link> [--parent '<page>'] [--title <text>] <file.md>
scripts/confluence-publish.sh create --parent '<page link>' [--title <text>] <file.md>
scripts/confluence-publish.sh update '<page link or id>' [<file.md>] [--title <text>] [--base-version <n>] [--message <text>]
scripts/confluence-publish.sh attach '<page link or id>' <file>...
# each takes [--tokens <file>]... and, to actually write, --yes
```

**Every publish is two calls.** The first, without `--yes`, sends nothing: it reads what it needs from Confluence, checks it, and reports what would be done. Show the user that report — the action, the page, what changes (`DIFF=`), the files to upload, the `NOTES:` — and ask. Only when the user says yes, make the same call again with `--yes`. Never pass `--yes` on a first call, never on your own judgement, and never again after something changed without showing the new dry run.

- **The Markdown file.** A leading `# Title` is the page title, not part of the body: `create` takes the title from it unless `--title` is given; `update` changes the title only with `--title`. A file `confluence-fetch.sh` wrote can be edited and published back as it is — its header (the title, the page link, the line of space, path and version) is recognised and left out. HTML comments are dropped.
- **Images and files** the Markdown shows or links by a relative path — `![diagram](attachments/flow.png)`, `[spec](spec.pdf)` — are uploaded and referred to by name. They must lie in the Markdown file's folder or below it: an absolute path, `~` or `..` is refused. A file whose name and size match an attachment already on the page is not uploaded again; under a name that is taken, it becomes that attachment's next version.
- **`update`** replaces the body with the file, and/or the title with `--title`. With `--yes` it needs `--base-version`: the version the edit is based on — `FILE_VERSION=` when the dry run prints it (the version named in the header of a file `confluence-fetch.sh` wrote), else the `VERSION=` of the dry run. If the page moved on since, the update is refused (exit 5). Then read the page again, carry the edit over, and start over with a dry run. `--message` sets the version comment.
- **A page edited meanwhile.** The user may change the page between turns. When `FILE_VERSION=` is older than `VERSION=`, the first note says so and who changed the page last: publishing the file would take their change back. Tell the user, read the page again, carry the edit over, and dry-run again — there is no need to re-read the page before every edit, the dry run checks.
- **What changes.** The dry run of an `update` with a file writes `DIFF=`: a unified diff of the page as it is now, read as Markdown the way `confluence-fetch.sh` reads it, against the file. On a file `confluence-fetch.sh` wrote, it is exactly the edit — plus anything changed on the page since. Read it and show the user the change from it, rather than diffing by hand.
- **No text change.** Without `DIFF=`, a note says why. *Its macros differ* names a change the text does not show — a link that becomes a Jira macro, say: the page's macros against the file's. *Publishing changes nothing* means the same text, the same macros, no new title or file: publishing would only make an empty version. Say so to the user and do not publish, unless another note names something on the page that is meant to go.
- **Macros.** `MACROS=` counts the macros the body Confluence gets will hold, by name — `jira 7, code 2, date 1` (a date is the date macro). Check against it that the links, dates and diagrams meant as macros became them, rather than searching `PREVIEW=` by hand.
- **Tables.** The dry run compares the page's tables with the file's and names a table that has merged cells (publishing splits them), one whose rows or columns change, and one whose rows on the page are narrower than the table. Pass these on; a table that changes shape although the edit did not touch it is a reason to stop.
- **`create`** puts the page in `--space`, or under `--parent` (in the parent's space). A title the space already has is refused (exit 5) — update that page instead.
- **`attach`** uploads the files as they are, from any path the user named.
- `--convert-only` converts the file and stops, with no config and no request: `PREVIEW=` names the storage-format body, `MACROS=` counts its macros.

The report of a dry run:

```
CONFLUENCE=dry-run
ACTION=update
ID=123456
TITLE=Payments — design
SPACE=PAY
VERSION=9
FILE_VERSION=7
URL=https://confluence.example.com/spaces/PAY/pages/123456/Payments+design
PREVIEW=/tmp/confluence-publish/123456/body.xml
DIFF=/tmp/confluence-publish/123456/body.diff
MACROS=jira 7, code 2, date 1, toc 1

ATTACHMENTS:
/work/docs/attachments/flow.png

NOTES:
The file was read at version 7; the page is at version 9 now, last changed by Jane Roe, 2026-11-13. Publishing the file takes back whatever changed since: read the page again, carry the edit over, and dry-run again.
The page holds macros the Markdown cannot: jira, toc. Publishing replaces each with what the file says in its place, which is at best its rendered text.
Table 2 of the page (Type | Field | Getter) has merged cells, which Markdown cannot hold: publishing splits them, and the cells they covered stay empty.
Publishing changes the page: 4 line(s) in, 2 out. DIFF= shows them against the page as it is now.
```

After `--yes`, `CONFLUENCE=published`, `ID=`, `VERSION=`, `URL=` and `MACROS=` name the page as it now is, and `ATTACHMENTS:` lists what was uploaded. `CONFLUENCE=partial` (exit 6) means something was written before a later step failed: the report says what — pass it on, and do not simply run the call again.

How Markdown becomes the storage format: headings, nested lists, task lists (`- [ ]`, `- [x]`), tables, fenced code as the code macro with its language (a ```` ```plantuml ```` block as the PlantUML macro), quotes, GitHub alerts (`> [!NOTE]` → info, `[!TIP]` → tip, `[!WARNING]` → note, `[!CAUTION]` → warning), links, images, bold, italic, strikethrough, inline code. A line break inside a paragraph stays a line break. A code block or table inside a list item stays inside it.

**Jira issues** become the Jira issue macro — the key, summary and status as Confluence draws them — when the link shows nothing but the issue: `[PAY-42](https://jira.example.com/browse/PAY-42)` with the key as its text, or the bare link. Write an issue meant to be shown that way like this. A link with text of its own (`[the refunds](…/browse/PAY-42)`) stays a link. The macro names the Jira by Confluence's link to it, which publishing looks up (`/rest/jiraanywhere/1.0/servers`); a link to a Jira Confluence is not linked to stays a link, and `NOTES:` says so, as it does when the list cannot be read. `--convert-only` makes no request, so its preview keeps such links as links.

**A table of contents** is `[TOC]` on a line of its own, with the macro's settings as `name=value` or `name="value with spaces"`: `[TOC maxLevel=3]`. `[TOC]` inside a line of text stays text.

**Dates** written `<time>2026-11-16</time>` (or `<time datetime="2026-11-16">…</time>`) become the date macro, which Confluence draws as a calendar chip in each reader's locale. Use it for a date the page states — "Valid as of", a deadline, a release day. A date in plain text, or in any other form, stays text.

**Diagrams are PlantUML only.** A ```` ```mermaid ```` block (and ```` ```dot ````, ```` ```graphviz ````, ```` ```d2 ````) has no macro here: it is published as a code block, so the page shows the diagram's source as text, and `NOTES:` says so. Write a diagram meant for Confluence as ```` ```plantuml ````; when a file to publish holds Mermaid, tell the user before the dry run is confirmed and offer to rewrite those diagrams as PlantUML.
