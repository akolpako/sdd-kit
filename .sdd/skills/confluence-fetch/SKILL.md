---
name: confluence-fetch
description: 'Reads a Confluence Data Center page into a Markdown file, with the images and attachments it shows downloaded beside it. Use whenever a Confluence page link (…/spaces/<SPACE>/pages/<id>/…, viewpage.action?pageId=, /display/, /x/) or page id has to be read, instead of WebFetch or curl, which cannot sign in.'
---

# Confluence page

A Confluence page sits behind a login, so WebFetch and plain curl get a login page instead of the content. This skill reads the page through the REST API with the user's personal access token and writes it as Markdown. Headings, lists, tables, code blocks, info panels and links keep their structure. The images and files the page shows or links are downloaded next to it.

Script: `scripts/confluence-fetch.sh`, relative to this skill's directory. Needs `bash`, `curl` and `jq`.

## Call

```bash
scripts/confluence-fetch.sh '<page link or id>' [--tokens <file>]... [--out <file>] [--no-attachments]
```

- Pass the link **as the user gave it**, quoted. Every page link works: `/spaces/<SPACE>/pages/<id>/<Title>`, `/pages/viewpage.action?pageId=<id>`, `/display/<SPACE>/<Title>`, `/x/<code>`. A bare id works too when `CONFLUENCE_URL` is set.
- One page per call. To read several pages, make one call per link, and batch the calls in parallel.
- `--tokens <file>` names the file that holds `CONFLUENCE_URL` and `CONFLUENCE_TOKEN`. The script looks for no file by itself, so pass the one the user or the project's instructions (`CLAUDE.md`, `AGENTS.md`) name. It may be given more than once; a later file wins. What no file sets is taken from the environment. When no file is named and the call fails for want of a token, ask the user where the token is kept.
- `--out <file>` writes the Markdown there and the attachments to `attachments/` beside it. Without it, the file goes to `$TMPDIR/confluence-fetch/<id>/page.md`. Pass `--out` when the page should stay in the workspace, or when the temp path cannot be read.
- `--no-attachments` keeps the links but downloads nothing. Use it when only the text matters.
- All options: `--help`.

## Output

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
- **Info, tip, note and warning macros:** `> [!NOTE]`, `> [!TIP]`, `> [!WARNING]`, `> [!CAUTION]`.
- **Tables:** Markdown tables. A line break inside a cell is written as `<br>`, and a list inside a cell as `•` items.

`NOTES:` lists what was simplified or not downloaded. Pass it on when it affects the answer.

## Rules

- **Cite the page** by its `URL=` and `VERSION=`. The local path is a cache.
- **Don't pipe** the call through `head` or `grep`. The report is short; read the file instead.
- **A failure is reported, not worked around.** Don't retry with WebFetch or curl. Every failure prints `ERROR=` and a `hint:` line, so give both to the user.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| `0` | written | read `OUT` |
| `1` | no `curl`/`jq`, no token, or no `CONFLUENCE_URL` for a bare id | give the hint to the user: setup below |
| `2` | not a page link | ask for the page link as the browser shows it |
| `3` | page not readable: token rejected, no permission, not found, SSO redirect (VPN down) | give the error to the user |
| `4` | the answer was not Confluence JSON, or did not convert | give the error to the user |

## Setup (once, by the user)

1. In Confluence, open the profile menu → **Settings** → **Personal Access Tokens** (in Russian: «Личные маркеры доступа») → **Create token**.
2. Put it in a file of `KEY=value` lines, `chmod 600` that file, and tell the agent its path — in the request, or once in the project's `CLAUDE.md` / `AGENTS.md`:
   ```sh
   CONFLUENCE_URL=https://confluence.example.com   # needed only for bare page ids
   CONFLUENCE_TOKEN=<token>
   ```
   Other keys in the file are ignored, so an existing config file can hold these two. Exported `CONFLUENCE_URL` / `CONFLUENCE_TOKEN` work too, without any file.

The token is sent as `Authorization: Bearer` to the host in the link and nowhere else. Redirects are never followed.

## Limits

- **Data Center / Server only** (7.9+, the release that added personal access tokens). Confluence Cloud is not supported.
- **What is read:** the page as Confluence renders it for export. Macros come out as their rendered content. Dynamic ones (Jira queries, page trees) show what the server rendered at that moment.
- **Child pages are not read.** Call the script again with a child page's link.
- **Attachments:** only the ones the page body shows or links are downloaded. Files from another host keep their link.
