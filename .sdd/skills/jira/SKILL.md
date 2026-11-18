---
name: jira
description: 'Reads and publishes Jira Server / Data Center issues — an issue into Markdown with the files its description shows, Markdown out to a new issue, a description, a summary or an attachment after a dry run the user has seen. Use whenever a Jira issue link (…/browse/<KEY>, …/projects/<P>/issues/<KEY>, ?selectedIssue=<KEY>) or a key such as ABC-123 is to be read or written, instead of WebFetch or curl, which cannot sign in.'
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

⛔ **Read [references/publish.md](references/publish.md) before the first `jira-publish.sh` call** — how a publish is two calls, what the dry run reports, and how Markdown is converted. Nothing of it is summarized here.

## Rules

- **Cite the issue** by its `URL=`. The local path is a cache.
- **Don't pipe** a call through `head` or `grep`. The report is short; read the file instead.
- **A failure is reported, not worked around.** Don't retry with WebFetch or curl. Every failure prints `ERROR=` and, where there is something to do, a `hint:` line; give both to the user. `NOTES:` lists what was not downloaded, simplified or skipped, and why; pass it on when it affects the answer.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| `0` | read; published; or the dry run found nothing in the way | read `OUT`; report `URL`; show the dry run and ask |
| `1` | no `curl`/`jq`, no token, or no `JIRA_URL` for a bare key | give the hint to the user: [setup](references/setup.md) |
| `2` | not an issue key or link; a wrong argument; a file that cannot be uploaded | fix the call, or ask the user |
| `3` | Jira refused: token rejected, no permission, not found, SSO redirect (VPN down), a field it would not take | give the error to the user |
| `4` | the answer was not Jira JSON, or the text did not convert | give the error to the user |
| `5` | publish: the issue changed since `--base-updated` | read it again, carry the edit over, dry run again |
| `6` | publish: partly written | give the report and the error to the user |

Setting up the token, and what this skill cannot do: [references/setup.md](references/setup.md).
