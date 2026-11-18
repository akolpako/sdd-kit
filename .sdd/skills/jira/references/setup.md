# Jira — setup and limits

Part of the `jira` skill; `scripts/` paths are relative to the skill's directory, and the config (`--tokens`) is taken as `SKILL.md` says.

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
