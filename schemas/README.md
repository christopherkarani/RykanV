# Schemas

The repository contains versioned JSON Schemas for the local ryk runtime:

- `policy-v1.json`: policy files and their rule sections.
- `event-v1.json`: audit event records.
- `mcp-manifest-v1.json`: stdio MCP server manifests.

The runtime rejects unknown keys in these v1 formats. A breaking schema change requires a new version and migration notes.
