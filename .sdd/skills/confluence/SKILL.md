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

⛔ **Read [references/publish.md](references/publish.md) before the first `confluence-publish.sh` call** — how a publish is two calls, what the dry run reports, and how Markdown is converted. Nothing of it is summarized here.

## Rules

- **Cite the page** by its `URL=` and `VERSION=`. The local path is a cache.
- **Don't pipe** a call through `head` or `grep`. The report is short; read the file instead.
- **A failure is reported, not worked around.** Don't retry with WebFetch or curl. Every failure prints `ERROR=` and a `hint:` line, so give both to the user. `NOTES:` lists what was simplified, not downloaded, or skipped; pass it on when it affects the answer.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| `0` | read; searched (`TOTAL=0` included); published; or the dry run found nothing in the way | read `OUT`; use `RESULTS:`; report `URL`; show the dry run and ask |
| `1` | no `curl`/`jq`, no token, or no `CONFLUENCE_URL` for a bare id, a key or a search without a space link | give the hint to the user: [setup](references/setup.md) |
| `2` | not a page link; a wrong argument or query option; a file that cannot be uploaded | fix the call, or ask the user |
| `3` | Confluence refused: token rejected, no permission, not found, SSO redirect (VPN down), a body or CQL it would not take | give the error to the user |
| `4` | the answer was not Confluence JSON, or the text did not convert | give the error to the user |
| `5` | publish: the page moved on since `--base-version`, or the title is taken | read it again and carry the edit over, or pick another title |
| `6` | publish: partly written | give the report and the error to the user |

Setting up the token, and what this skill cannot do: [references/setup.md](references/setup.md).
