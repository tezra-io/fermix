# Lessons

## API plugin architecture — 2026-09-07

For an OAuth REST integration, start from the existing GitHub, Notion, and X HTTP plugins and their shared authentication/execution path. A hosted MCP integration such as Eden is not the default template for an API plugin. Keep any provider-specific requirement that needs a helper, such as Tesla vehicle-command signing, separate from ordinary REST methods; do not move those methods into a new MCP server unnecessarily.
