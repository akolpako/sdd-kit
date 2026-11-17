# Confluence — setup and limits

Part of the `confluence` skill; `scripts/` paths are relative to the skill's directory, and the config (`--tokens`) is taken as `SKILL.md` says.

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
