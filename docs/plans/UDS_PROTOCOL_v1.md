# ryk UDS IPC Protocol v1

> Phase 0.5 — NDJSON over Unix Domain Sockets between the Zig `ryk` CLI and the Rust `ryk-daemon`.

## Socket Path

- **Default:** `$HOME/.ryk/daemon.sock`
- **PID file:** `$HOME/.ryk/daemon.pid` (written by the daemon on startup)
- The daemon creates the parent directory `$HOME/.ryk/` if it does not exist.
- On graceful shutdown the daemon removes both the socket and the PID file.

## Wire Format

Newline-delimited JSON (NDJSON). Each request is a single JSON object terminated by `\n`. Each response is a single JSON object terminated by `\n`.

The protocol is **synchronous**: one response per request, in order.

## Request Envelope

```json
{"id": 1, "method": "Ping"}
```

| Field    | Type             | Description                                           |
|----------|------------------|-------------------------------------------------------|
| `id`     | `u64`            | Caller-chosen correlation id. Mirrored in response.   |
| `method` | `string`         | Discriminant: `Ping`, `Evaluate`, or `Shutdown`.      |
| `params` | `object | null`  | Method-specific payload (omitted or `null` if none).  |

### Methods

#### `Ping`
No parameters.

```json
{"id": 1, "method": "Ping"}
```

#### `Evaluate`
Parameters:
- `command` (`string`): The shell command line to evaluate.
- `cwd` (`string | null`): Optional working directory for context.

```json
{"id": 2, "method": "Evaluate", "params": {"command": "ls -la", "cwd": "/tmp"}}
```

> Phase 0.5 note: the daemon uses a hardcoded placeholder evaluator (`rm -rf` → Deny, everything else → Allow). Full policy evaluation is Phase 5 work.

#### `Shutdown`
No parameters. Signals the daemon to initiate graceful shutdown.

```json
{"id": 3, "method": "Shutdown"}
```

## Response Envelope

```json
{"id": 1, "result": {"status": "Pong"}}
```

| Field    | Type    | Description                                           |
|----------|---------|-------------------------------------------------------|
| `id`     | `u64`   | Mirrors the request `id`.                             |
| `result` | `object`| Tagged union via `status` field.                      |

### Result Payloads

| `status`   | Extra fields            | Meaning                                                |
|------------|-------------------------|--------------------------------------------------------|
| `Pong`     | —                       | Response to `Ping`.                                    |
| `Allow`    | `reason: string`        | The evaluated command is permitted.                    |
| `Deny`     | `reason: string`        | The evaluated command is blocked.                      |
| `Error`    | `message: string`       | Something went wrong (parse error, internal error, …). |

## Error Handling Rules

1. **Parse errors:** If a request line cannot be parsed as valid JSON or is missing required fields, the daemon responds with a JSON `Error` payload with `id: 0` (the correlation id is unavailable until parsing succeeds) and keeps the connection open for the next line.
2. **Unknown methods:** Treated as an `Error` response with a descriptive `message`.
3. **Connection errors:** If the client disconnects mid-request, the daemon drops the connection and continues accepting new ones.
4. **Daemon unavailable:** If the socket does not exist or the daemon is not listening, the Zig client must treat this as a hard failure (fail-closed). No fallback to Zig-native evaluation is permitted.

## Shutdown Behaviour

When the daemon receives `Shutdown` (or `SIGTERM` / `SIGINT`):
1. Stop accepting new connections.
2. Remove `$HOME/.ryk/daemon.sock` and `$HOME/.ryk/daemon.pid`.
3. Exit with code `0`.

> **Phase 0.5 note:** In-flight requests are not drained with a timeout; the runtime shuts down immediately after closing the accept loop. Full graceful draining is planned for a later phase.

## Security Notes

- No authentication, TLS, or multiplexing in Phase 0.5. UDS file permissions are the boundary.
- The socket lives in the user’s home directory; other users on the same machine cannot connect unless they have filesystem access.
- Future phases may add capability tokens or peer-credential checks.

## File Locations

| File                              | Purpose                          |
|-----------------------------------|----------------------------------|
| `orca-rs/src/daemon_protocol.rs`  | Rust request/response types      |
| `orca-rs/src/daemon.rs`           | Rust UDS listener + dispatcher   |
| `src/cli/daemon.zig`              | Zig UDS client (`sendRequest`)   |
