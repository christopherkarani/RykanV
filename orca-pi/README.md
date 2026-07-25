# ryk for Pi

The official Pi integration for ryk protects Pi tool calls before they run.
It is installed automatically by `ryk` onboarding; no npm command or additional
Pi setup is required.

## Protection coverage

| Tool | Enforcement |
|------|-------------|
| `bash` | `ryk evaluate --json --stdin`; failures block by default |
| `write` / `edit` | `ryk decide file` with `operation: write` |
| `read` | `ryk decide file` with `operation: read` |
| `grep` / `find` / `ls` | Root preflight plus explicit approval |
| Other tool names | `ryk decide tool` name gate |

The extension also detects secret-like values in interactive prompts. With user
consent it stores them in the compatibility credential broker path
`.orca/dev-secrets.env` using mode `0600`, then replaces the raw value with an
environment-variable reference before the model sees the message.

## Runtime behavior

- The generated Pi wrapper contains the absolute path of the installed `ryk`
  executable. Pi protection does not depend on PATH or shell profile activation.
- The bundled runtime fails closed when `ryk` is unavailable, returns malformed
  output, or times out.
- `/ryk-setup`, `/ryk-start`, `/ryk-stop`, `/ryk-doctor`, and `/ryk-mode`
  manage the current Pi integration.
- `RYK_PI_MODE=auto` is the default: interactive sessions ask; noninteractive
  sessions block. Use `RYK_PI_MODE=strict` for the strongest fail-closed posture.
- Process-level environment, network, and secretless controls require launching
  Pi through `ryk run -- pi`.

## Security properties

- Child processes use argv arrays with `shell: false`.
- Evaluation requests are sent through stdin.
- Child output is bounded before parsing.
- Malformed tool payloads block.
- Credential files are written atomically and symlinked paths are rejected.
- Session bypass is not persisted and requires an explicit user choice.
- Tool hooks do not claim process-level network or environment isolation.
