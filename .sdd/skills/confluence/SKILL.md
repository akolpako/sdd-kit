---
name: confluence
description: 'Reads, searches and writes Confluence Data Center pages. Reads a page into a Markdown file, with the images and attachments it shows downloaded beside it. Searches pages by text, title or CQL, in a space or everywhere. Publishes from Markdown: creates a page in a space or under a parent, replaces a page''s body or title, attaches files, always after a dry run the user has seen. Use whenever a Confluence page link (…/spaces/<SPACE>/pages/<id>/…, viewpage.action?pageId=, /display/, /x/) or page id has to be read, a page has to be found, or something has to be put into Confluence, instead of WebFetch or curl, which cannot sign in.'
---

# Confluence

A Confluence page sits behind a login, so WebFetch and plain curl get a login page instead of the content. This skill talks to the REST API with the user's personal access token, in Markdown both ways:

- **Read** — `scripts/confluence-fetch.sh` writes a page as Markdown. Headings, lists, tables, code blocks, info panels and links keep their structure. The images and files the page shows or links are downloaded next to it.
- **Search** — `scripts/confluence-search.sh` lists the pages a search finds: title, id, space, link, last change and a few words of the text.
- **Publish** — `scripts/confluence-publish.sh` creates a page, replaces a page's body, or attaches files. The body is written as Markdown and converted to the storage format; the local images and files it shows or links are uploaded as the page's attachments.

Scripts are relative to this skill's directory. They need `bash`, `curl` and `jq`; `xmllint`, when present, checks a converted body before it is sent.

Both take the config the same way. `--tokens <file>` names the file that holds `CONFLUENCE_URL` and `CONFLUENCE_TOKEN`. The scripts look for no file by themselves, so pass the one the user or the project's instructions (`CLAUDE.md`, `AGENTS.md`) name. It may be given more than once; a later file wins. What no file sets is taken from the environment. When no file is named and a call fails for want of a token, ask the user where the token is kept.

## Read

```bash
scripts/confluence-fetch.sh '<page link or id>' [--tokens <file>]... [--out <file>] [--no-attachments]
```

- Pass the link **as the user gave it**, quoted. Every page link works: `/spaces/<SPACE>/pages/<id>/<Title>`, `/pages/viewpage.action?pageId=<id>`, `/display/<SPACE>/<Title>`, `/x/<code>`. A bare id works too when `CONFLUENCE_URL` is set.
- One page per call. To read several pages, make one call per link, and batch the calls in parallel.
- `--out <file>` writes the Markdown there and the attachments to `attachments/` beside it. Without it, the file goes to `$TMPDIR/confluence-fetch/<id>/page.md`. Pass `--out` when the page should stay in the workspace, when it is to be edited and published back, or when the temp path cannot be read.
- `--no-attachments` keeps the links but downloads nothing. Use it when only the text matters.
- All options: `--help`.

The script prints a report. The page itself is in the file named by `OUT=`, so read that file, in ranges when `LINES` is large.

```
CONFLUENCE=ok
ID=123456
TITLE=Payments — design
SPACE=PAY
VERSION=7
URL=https://confluence.example.com/spaces/PAY/pages/123456/Payments+design
OUT=/tmp/confluence-fetch/123456/page.md
LINES=66

ATTACHMENTS:
/tmp/confluence-fetch/123456/attachments/flow diagram.png

NOTES:
A table has merged cells; they were split and the extra cells left empty.
```

The file starts with the title, the page URL, and a line with the space, the path of parent pages and the version. Then comes the body:
- **Images:** `![name](attachments/name)`. Open the downloaded file when the picture matters (a diagram, a screenshot).
- **Links:** links to other Confluence pages are absolute. To follow one, call the script again with that link.
- **Jira issue macros:** the issue's key as a link, `[PAY-42](https://jira.example.com/browse/PAY-42)`. The summary and status the macro shows are left out; read the issue with the `jira` skill when they matter. Published back, the link is the macro again.
- **PlantUML diagrams:** a ```` ```plantuml ```` block with the diagram's source, read from the page's storage format — the rendered image is not downloaded. A PlantUML macro that draws an attached file keeps its image link, which works only for a few minutes.
- **Dates** (the date macro, a calendar chip on the page): `<time>2026-11-16</time>` — the date itself, not the text the page shows in the reader's language. Published back, it is the macro again.
- **Table of contents:** `[TOC]` on a line of its own where the macro stands, with its settings: `[TOC maxLevel=2 exclude="Intro"]`. Published back, it is the macro again.
- **Info, tip, note and warning macros:** `> [!NOTE]`, `> [!TIP]`, `> [!WARNING]`, `> [!CAUTION]`.
- **Expand macros:** the content, opened up, after its title in bold. A section with no title of its own has no title line.
- **Other macros:** at most their rendered text. `NOTES:` names each macro the file has no form for, and each image a plugin draws under `/rest/<plugin>/` — that one keeps a link to its rendering, which may not last.
- **Tables:** Markdown tables. A line break inside a cell is written as `<br>`, and a list inside a cell as `•` items. Merged cells are split, the cells they covered left empty. A row with fewer cells than the table is wide is filled up at its end, and `NOTES:` names the table and the row: its cells may sit a column too far left. Before such a file is published back, compare that table with the page.

## Search

```bash
scripts/confluence-search.sh '<text>' [--space <KEY|link>]... [--title] [--type page|blogpost|all] [--limit <n>] [--start <n>] [--tokens <file>]...
scripts/confluence-search.sh --cql '<CQL>' [--limit <n>] [--start <n>] [--tokens <file>]...
```

- `<text>` is searched as the search box of Confluence searches it (`siteSearch ~`); a phrase in double quotes inside it is looked for as it is. `--title` looks in titles only.
- `--space` narrows the search to a space — a key, or a link into the space, which names the instance too, so `CONFLUENCE_URL` is not needed. Give it more than once for several spaces.
- `--type` is `page` (the default), `blogpost` or `all`.
- `--cql` takes a query as it is — labels, authors, dates, ancestors, ordering: `label = "adr" and space = PAY order by lastmodified desc`. It does not go with `<text>`, `--space`, `--type` or `--title`.
- `--limit` shows 1 to 50 results (default 10); `--start` skips the first n. `NEXT=` names the `--start` of the next results when there are more.

The report is the list itself:

```
CONFLUENCE=ok
CQL=siteSearch ~ "payments" and space = "PAY" and type = page
TOTAL=14
SHOWN=10
NEXT=--start 10

RESULTS:
1. Payments — design
   ID=123456 SPACE=PAY MODIFIED=2026-10-01
   https://confluence.example.com/spaces/PAY/pages/123456/Payments+design
   How payments flow: order, refund, ledger …
```

The text under a result is a few words of the page around the match, to tell the pages apart. To read a page, call `confluence-fetch.sh` with its link. `TOTAL=0` is a search that found nothing, not a failure. A CQL Confluence will not take fails with exit 3 and its reason.

## Publish

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

## Rules

- **Cite the page** by its `URL=` and `VERSION=`. The local path is a cache.
- **Don't pipe** a call through `head` or `grep`. The report is short; read the file instead.
- **A failure is reported, not worked around.** Don't retry with WebFetch or curl. Every failure prints `ERROR=` and a `hint:` line, so give both to the user. `NOTES:` lists what was simplified, not downloaded, or skipped; pass it on when it affects the answer.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| `0` | read; searched (`TOTAL=0` included); published; or the dry run found nothing in the way | read `OUT`; use `RESULTS:`; report `URL`; show the dry run and ask |
| `1` | no `curl`/`jq`, no token, or no `CONFLUENCE_URL` for a bare id, a key or a search without a space link | give the hint to the user: setup below |
| `2` | not a page link; a wrong argument or query option; a file that cannot be uploaded | fix the call, or ask the user |
| `3` | Confluence refused: token rejected, no permission, not found, SSO redirect (VPN down), a body or CQL it would not take | give the error to the user |
| `4` | the answer was not Confluence JSON, or the text did not convert | give the error to the user |
| `5` | publish: the page moved on since `--base-version`, or the title is taken | read it again and carry the edit over, or pick another title |
| `6` | publish: partly written | give the report and the error to the user |

## Setup (once, by the user)

1. In Confluence, open the profile menu → **Settings** → **Personal Access Tokens** (in Russian: «Личные маркеры доступа») → **Create token**.
2. Put it in a file of `KEY=value` lines, `chmod 600` that file, and tell the agent its path — in the request, or once in the project's `CLAUDE.md` / `AGENTS.md`:
   ```sh
   CONFLUENCE_URL=https://confluence.example.com   # needed only for bare page ids and space keys
   CONFLUENCE_TOKEN=<token>
   ```
   Other keys in the file are ignored, so an existing config file can hold these two. Exported `CONFLUENCE_URL` / `CONFLUENCE_TOKEN` work too, without any file.

The token is sent as `Authorization: Bearer` to the host in the link and nowhere else. Redirects are never followed. Publishing needs a token whose owner may edit the page or add pages to the space.

## Limits

- **Data Center / Server only** (7.9+, the release that added personal access tokens). Confluence Cloud is not supported.
- **What is read:** the page as Confluence renders it for export. Macros come out as their rendered content; `NOTES:` names the ones that have no form in Markdown. Dynamic ones (Jira queries, page trees) show what the server rendered at that moment.
- **Child pages are not read.** Call the script again with a child page's link.
- **Attachments read:** only the ones the page body shows or links are downloaded. Files from another host keep their link.
- **What is written:** a page's title and body, and its attachments. Labels, comments, permissions and moving a page are not.
- **Round trip:** what Markdown cannot hold — macros other than code, PlantUML, the info panels, the table of contents, single Jira issues and dates, layouts, merged table cells, mentions, inline comments' anchors — is lost when an edited page is published back; the dry run names what the page holds.
