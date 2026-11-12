---
name: jira-fetch
description: 'Reads a Jira Server / Data Center issue into a Markdown file — summary, type, status and the description — with the images and files the description shows downloaded beside it. Use whenever a Jira issue link (…/browse/<KEY>, …/projects/<P>/issues/<KEY>, ?selectedIssue=<KEY>) or issue key such as ABC-123 has to be read, instead of WebFetch or curl, which cannot sign in.'
---

# Jira issue

A Jira issue sits behind a login, so WebFetch and plain curl get a login page instead of the content. This skill reads the issue through the REST API with the user's personal access token and writes it as Markdown. The description's wiki markup keeps its structure: headings, nested lists, tables, code blocks, quotes, links, mentions. The images and files the description shows or links are downloaded next to it.

Script: `scripts/jira-fetch.sh`, relative to this skill's directory. Needs `bash`, `curl` and `jq`.

## Call

```bash
scripts/jira-fetch.sh '<issue link or key>' [--tokens <file>]... [--out <file>] [--no-attachments]
```

- Pass the link **as the user gave it**, quoted. Every issue link works: `/browse/<KEY>`, `/projects/<P>/issues/<KEY>`, a board link with `selectedIssue=<KEY>`. A bare key works too when `JIRA_URL` is set.
- One issue per call. To read several issues, make one call per link, and batch the calls in parallel.
- `--tokens <file>` names the file that holds `JIRA_URL` and `JIRA_TOKEN`. The script looks for no file by itself, so pass the one the user or the project's instructions (`CLAUDE.md`, `AGENTS.md`) name. It may be given more than once; a later file wins. What no file sets is taken from the environment. When no file is named and the call fails for want of a token, ask the user where the token is kept.
- `--out <file>` writes the Markdown there and the attachments to `attachments/` beside it. Without it, the file goes to `$TMPDIR/jira-fetch/<KEY>/issue.md`. Pass `--out` when the issue should stay in the workspace, or when the temp path cannot be read.
- `--no-attachments` keeps the links but downloads nothing. Use it when only the text matters.
- All options: `--help`.

## Output

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

The file starts with `# <KEY> — <summary>`, the issue URL, and a line with the type, status, priority, assignee and the date of the last update. Then comes the description:
- **Images and attached files:** `![name](attachments/name)` and `[name](attachments/name)`. Open the downloaded file when the picture matters (a diagram, a screenshot).
- **Links to other issues** stay links. To follow one, call the script again with that link.
- **Mentions** (`[~user]`) become `@user`. Colour and panel wrappers are dropped; their text stays.

`NOTES:` lists what was not downloaded and why. Pass it on when it affects the answer.

## Rules

- **Cite the issue** by its `URL=`. The local path is a cache.
- **Don't pipe** the call through `head` or `grep`. The report is short; read the file instead.
- **A failure is reported, not worked around.** Don't retry with WebFetch or curl. Every failure prints `ERROR=` and, where there is something to do, a `hint:` line; give both to the user.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| `0` | written | read `OUT` |
| `1` | no `curl`/`jq`, no token, or no `JIRA_URL` for a bare key | give the hint to the user: setup below |
| `2` | not an issue key or link | ask for the issue link as the browser shows it |
| `3` | issue not readable: token rejected, no permission, not found, SSO redirect (VPN down) | give the error to the user |
| `4` | the answer was not a Jira issue in JSON, or did not convert | give the error to the user |

## Setup (once, by the user)

1. In Jira, open the profile menu → **Profile** → **Personal Access Tokens** (in Russian: «Личные маркеры доступа») → **Create token**.
2. Put it in a file of `KEY=value` lines, `chmod 600` that file, and tell the agent its path — in the request, or once in the project's `CLAUDE.md` / `AGENTS.md`:
   ```sh
   JIRA_URL=https://jira.example.com   # needed only for bare issue keys
   JIRA_TOKEN=<token>
   ```
   Other keys in the file are ignored, so an existing config file can hold these two. Exported `JIRA_URL` / `JIRA_TOKEN` work too, without any file.

The token is sent as `Authorization: Bearer` to the host in the link and nowhere else. Redirects are never followed.

## Limits

- **Server / Data Center only** (8.14+, the release that added personal access tokens). Jira Cloud is not supported.
- **What is read:** summary, type, status, priority, assignee, last update and the description. Comments, the change history, sub-tasks, issue links and custom fields are not.
- **Attachments:** only the ones the description shows or links are downloaded, from the same host as the issue. The rest are counted under `NOTES:` and left in Jira.
