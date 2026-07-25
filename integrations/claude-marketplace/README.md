# ryk Claude Marketplace (Local Example)

This directory contains a local marketplace catalog example for the ryk Claude Code plugin.

## What this file is

The `marketplace.json` file is a documented example of how a Claude Code marketplace catalog might reference the ryk plugin. It is not an official marketplace listing.

## How to use locally

If your Claude Code version supports local marketplace catalogs:

1. Point Claude Code to the marketplace file:
   ```text
   integrations/claude-marketplace/.claude-plugin/marketplace.json
   ```

2. The catalog references the plugin source at `../claude-code-plugin` (relative to this directory).

3. Install the plugin through your Claude Code plugin management UI.

## How to verify installation

After loading the marketplace catalog, run:

```bash
ryk plugin doctor claude
```

This checks that the plugin directory is detected and that the ryk CLI is available.

## Known limitations

- This is an example catalog only.
- Official marketplace availability is not yet implemented.
- The relative path behavior depends on your Claude Code version.
- The marketplace schema may vary between Claude Code versions.

## Security note

- No credentials or tokens are stored in the marketplace file.
- No telemetry is collected.
- This catalog does not claim official marketplace approval.
