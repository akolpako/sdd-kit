# Jira — publishing

Part of the `jira` skill; `scripts/` paths are relative to the skill's directory, and the config (`--tokens`) is taken as `SKILL.md` says.

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
