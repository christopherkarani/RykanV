# Phase 17 MCP Support Status

Phase 17 extends the stdio MCP proxy into the v1.0 firewall surface.

## Supported

- Stdio MCP proxy remains the production path.
- Server manifests can be checked and generated with `ryk mcp manifest`.
- Manifest defaults can influence tool/resource/prompt/sampling decisions.
- Manifest defaults are applied only after the proxy binds the manifest to the launched stdio server command, args, optional expected SHA-256 hash, and environment allowlist.
- Explicit policy deny still wins over manifest allow.
- `resources/list` and `prompts/list` are logged.
- `resources/read` and `prompts/get` are policy/manifest mediated.
- Sensitive resource URIs such as `file://`, home-directory paths, credential-looking paths, and secret-looking URIs are treated as sensitive by default.
- `sampling/createMessage` is mediated and defaults to deny.
- Server-originated `sampling/createMessage` requests are mediated before reaching the client. Denied requests are answered to the server with JSON-RPC errors.
- CI mode converts ask decisions to deny and never prompts.
- MCP audit targets are bounded and redacted before persistence.
- `ryk mcp list` discovers local manifests from `.ryk/mcp/*.yaml`.
- `ryk mcp trust <server> --tool <tool>` prints a policy snippet instead of mutating config silently.

## Limited Or Deferred

- Remote/HTTP MCP is represented by an explicit transport descriptor and deferred HTTP transport stub. ryk does not claim a hosted MCP gateway or production remote MCP proxy in Phase 17.
- OAuth, hosted gateways, enterprise dashboards, SaaS policy sync, and monetization are out of scope.
- Prompt and resource response bodies are not persisted by default. Audit logs record bounded, redacted decision targets and event types.
- MCP policy syntax remains compatible with the existing selector model. Resource, prompt, and sampling decisions use selectors such as `server.uri`, `server.prompt`, or `server.model`.
