---
name: jira
description: 'Reads and writes Jira Server / Data Center issues. Reads an issue into a Markdown file — summary, type, status and the description — with the images and files the description shows downloaded beside it. Publishes from Markdown: creates an issue, replaces an issue''s description or summary, attaches files, always after a dry run the user has seen. Use whenever a Jira issue link (…/browse/<KEY>, …/projects/<P>/issues/<KEY>, ?selectedIssue=<KEY>) or issue key such as ABC-123 has to be read, or something has to be put into Jira, instead of WebFetch or curl, which cannot sign in.'
---

# Jira

A Jira issue sits behind a login, so WebFetch and plain curl get a login page instead of the content. This skill talks to the REST API with the user's personal access token, in Markdown both ways:

- **Read** — `scripts/jira-fetch.sh` writes an issue as Markdown. The description's wiki markup keeps its structure: headings, nested lists, tables, code blocks, quotes, links, mentions. The images and files the description shows or links are downloaded next to it.
- **Publish** — `scripts/jira-publish.sh` creates an issue, replaces a description, or attaches files. The description is written as Markdown and converted to wiki markup; the local images and files it shows or links are uploaded.

Scripts are relative to this skill's directory. They need `bash`, `curl` and `jq`.

Both take the config the same way. `--tokens <file>` names the file that holds `JIRA_URL` and `JIRA_TOKEN`. The scripts look for no file by themselves, so pass the one the user or the project's instructions (`CLAUDE.md`, `AGENTS.md`) name. It may be given more than once; a later file wins. What no file sets is taken from the environment. When no file is named and a call fails for want of a token, ask the user where the token is kept.

## Read

```bash
scripts/jira-fetch.sh '<issue link or key>' [--tokens <file>]... [--out <file>] [--no-attachments]
```

- Pass the link **as the user gave it**, quoted. Every issue link works: `/browse/<KEY>`, `/projects/<P>/issues/<KEY>`, a board link with `selectedIssue=<KEY>`. A bare key works too when `JIRA_URL` is set.
- One issue per call. To read several issues, make one call per link, and batch the calls in parallel.
- `--out <file>` writes the Markdown there and the attachments to `attachments/` beside it. Without it, the file goes to `$TMPDIR/jira-fetch/<KEY>/issue.md`. Pass `--out` when the issue should stay in the workspace, when it is to be edited and published back, or when the temp path cannot be read.
- `--no-attachments` keeps the links but downloads nothing. Use it when only the text matters.
- All options: `--help`.

The script prints a report. The issue itself is in the file named by `OUT=`, so read that file, in ranges when `LINES` is large.

```
JIRA=ok
KEY=ABC-123
SUMMARY=Send order confirmations by email
TYPE=Story
STATUS=In Progress
URL=https://jira.example.com/browse/ABC-123
OUT=/tmp/jira-fetch/ABC-123/issue.md
LINES=25

ATTACHMENTS:
/tmp/jira-fetch/ABC-123/attachments/flow diagram.png

NOTES:
1 attachment(s) on the issue are not referenced by the description and were not downloaded.
```

The file starts with `# <KEY> — <summary>`, the issue URL, and a line with the type, status, priority, assignee and the time of the last update (to the minute, with the zone — publishing compares it). Then comes the description:
- **Images and attached files:** `![name](attachments/name)` and `[name](attachments/name)`. Open the downloaded file when the picture matters (a diagram, a screenshot).
- **Links to other issues** stay links. To follow one, call the script again with that link.
- **Mentions** (`[~user]`) become `@user`. A literal `@` in front of a name — an annotation such as `@Version` — is written `\@Version`, so publishing the file back keeps it text. Colour and panel wrappers are dropped; their text stays.

## Publish

```bash
scripts/jira-publish.sh create --project <KEY|link> --type <name> [<file.md>] [--summary <text>] [--parent <issue>] [--label <label>]...
scripts/jira-publish.sh update '<issue link or key>' [<file.md>] [--summary <text>] [--base-updated <ts>]
scripts/jira-publish.sh attach '<issue link or key>' <file>...
# each takes [--tokens <file>]... and, to actually write, --yes
```

**Every publish is two calls.** The first, without `--yes`, sends nothing: it reads what it needs from Jira, checks it, and reports what would be done. Show the user that report — the action, the issue, what changes (`DIFF=`), the files to upload, the `NOTES:` — and ask. Only when the user says yes, make the same call again with `--yes`. Never pass `--yes` on a first call, never on your own judgement, and never again after something changed without showing the new dry run.

- **The Markdown file.** A leading `# Title` is the title, not part of the description: `create` takes the summary from it unless `--summary` is given; `update` changes the summary only with `--summary`. A file `jira-fetch.sh` wrote can be edited and published back as it is — its header (the title, the issue link, the line of type and status) is recognised and left out. HTML comments are dropped.
- **Images and files** the Markdown shows or links by a relative path — `![diagram](attachments/flow.png)`, `[spec](spec.pdf)` — are uploaded and referred to by name. They must lie in the Markdown file's folder or below it: an absolute path, `~` or `..` is refused. A file whose name and size match an attachment already on the issue is not uploaded again.
- **`update`** replaces the description with the file, and/or the summary with `--summary`. With `--yes` it needs `--base-updated` set to the `UPDATED=` value the dry run printed: if anyone changed the issue in between, the update is refused (exit 5). Then read the issue again with `jira-fetch.sh`, carry the edit over, and start over with a dry run.
- **An issue edited meanwhile.** The user may change the issue between turns. When the file names an older update than the issue has now (`FILE_UPDATED=` against `UPDATED=`), the first note says so: publishing the file would take that change back. Tell the user, read the issue again, carry the edit over, and dry-run again — there is no need to re-read the issue before every edit, the dry run checks.
- **What changes.** The dry run of an `update` with a file writes `DIFF=`: a unified diff of the description as the issue has it now, read as Markdown the way `jira-fetch.sh` reads it, against the file. On a file `jira-fetch.sh` wrote, it is exactly the edit — plus anything someone else changed on the issue since, which publishing would take back. Read it and show the user the change from it, rather than diffing by hand. No `DIFF=` and a note saying so: the file changes no text.
- **Mentions.** Every `@name` is looked up in Jira first. A name that is a user becomes a mention, and `NOTES:` names whom Jira notifies; a name no user has — `@Version`, `@Override` — is published as text, and `NOTES:` says so. To keep an `@` text without a lookup, write `` `@Version` `` (inline code) or `\@Version`.
- **`create`** needs the project (key or link) and the issue type by name; the dry run lists the types the project has when the name is wrong. `--parent` makes a sub-task and needs a sub-task type.
- **`attach`** uploads the files as they are, from any path the user named.
- `--convert-only` converts the file and stops, with no config and no request: `PREVIEW=` names the wiki markup.

The report of a dry run:

```
JIRA=dry-run
ACTION=update
KEY=ABC-123
SUMMARY=Send order confirmations by email
URL=https://jira.example.com/browse/ABC-123
UPDATED=2026-11-01T10:00:00.000+0100
FILE_UPDATED=2026-11-01 10:00 +0100
PREVIEW=/tmp/jira-publish/ABC-123/description.wiki
DIFF=/tmp/jira-publish/ABC-123/description.diff

ATTACHMENTS:
/work/docs/attachments/flow.png

NOTES:
No Jira user is called @Version: published as text, not as a mention. In the file, \@name or `@name` says so.
The description mentions [~jdoe] (John Doe); Jira notifies them.
The current description uses {color}, {panel}, which Markdown cannot hold; publishing replaces them with the file's text.
Publishing changes the description: 3 line(s) in, 1 out. DIFF= shows them against the description the issue has now.
```

After `--yes`, `JIRA=published`, `KEY=` and `URL=` name the issue, and `ATTACHMENTS:` lists what was uploaded. `JIRA=partial` (exit 6) means something was written before a later step failed: the report says what — pass it on, and do not simply run the call again.

How Markdown becomes wiki markup: headings, nested and mixed lists, tables, fenced code with its language, quotes (`{quote}`), GitHub alerts (`> [!NOTE]` → `{info}`, `[!TIP]` → `{tip}`, `[!WARNING]` → `{note}`, `[!CAUTION]` → `{warning}`), links, bold, italic, strikethrough, inline code. `@user` becomes a mention when Jira has that user (see above); `\@user` and `` `@user` `` stay text. A line break inside a paragraph stays a line break, as Jira shows one. Characters Jira reads as markup are escaped.

## Rules

- **Cite the issue** by its `URL=`. The local path is a cache.
- **Don't pipe** a call through `head` or `grep`. The report is short; read the file instead.
- **A failure is reported, not worked around.** Don't retry with WebFetch or curl. Every failure prints `ERROR=` and, where there is something to do, a `hint:` line; give both to the user. `NOTES:` lists what was not downloaded, simplified or skipped, and why; pass it on when it affects the answer.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| `0` | read; published; or the dry run found nothing in the way | read `OUT`; report `URL`; show the dry run and ask |
| `1` | no `curl`/`jq`, no token, or no `JIRA_URL` for a bare key | give the hint to the user: setup below |
| `2` | not an issue key or link; a wrong argument; a file that cannot be uploaded | fix the call, or ask the user |
| `3` | Jira refused: token rejected, no permission, not found, SSO redirect (VPN down), a field it would not take | give the error to the user |
| `4` | the answer was not Jira JSON, or the text did not convert | give the error to the user |
| `5` | publish: the issue changed since `--base-updated` | read it again, carry the edit over, dry run again |
| `6` | publish: partly written | give the report and the error to the user |

## Setup (once, by the user)

1. In Jira, open the profile menu → **Profile** → **Personal Access Tokens** (in Russian: «Личные маркеры доступа») → **Create token**.
2. Put it in a file of `KEY=value` lines, `chmod 600` that file, and tell the agent its path — in the request, or once in the project's `CLAUDE.md` / `AGENTS.md`:
   ```sh
   JIRA_URL=https://jira.example.com   # needed only for bare issue and project keys
   JIRA_TOKEN=<token>
   ```
   Other keys in the file are ignored, so an existing config file can hold these two. Exported `JIRA_URL` / `JIRA_TOKEN` work too, without any file.

The token is sent as `Authorization: Bearer` to the host in the link and nowhere else. Redirects are never followed. Publishing needs a token whose owner may edit the issue or create in the project.

## Limits

- **Server / Data Center only** (8.14+, the release that added personal access tokens). Jira Cloud is not supported.
- **What is read:** summary, type, status, priority, assignee, last update and the description. Comments, the change history, sub-tasks, issue links and custom fields are not.
- **What is written:** a new issue's project, type, summary, description, parent and labels; an issue's description and summary; attachments. Comments, transitions, assignees, epics and custom fields are not.
- **Attachments read:** only the ones the description shows or links, from the same host as the issue. The rest are counted under `NOTES:` and left in Jira.
- **Round trip:** what Markdown cannot hold — colours, panels, other macros — is lost when an edited description is published back; the dry run names it.
- **Inside a list item** Jira has no room for a code block, table or quote: one is placed after the item, and a numbered list starts counting again after it. `NOTES:` says so.
