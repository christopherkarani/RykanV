# macOS Platform

Run:

```sh
./zig-out/bin/orca doctor
```

Current macOS local output reports process supervision, env filtering, staged writes, MCP stdio proxy, network decision engine, and audit/replay as active.

## Capability Matrix

| Feature | Status |
|---|---|
| Process supervision | active |
| Env filtering | active |
| Staged writes | active |
| Shell/PATH shims | wrapper-only |
| MCP stdio proxy | active |
| Network decision engine | active |
| Network observation | observe-only |
| Transparent network enforcement | per-session when proxy backend + OS sandbox attach route-forces the child; otherwise unavailable/wrapper-proxy only |
| Transparent file enforcement | limited; Seatbelt session-attach when available |
| Strong sandbox | session-attach via Seatbelt on product majors 14–26 (capability gate); otherwise unavailable |

## OS filesystem sandbox

Protected agent launches (`orca <agent>`) use the run engine and can attach a custom Seatbelt (SBPL) filesystem boundary to the agent child. Advanced users can force the same path with `orca run --os-sandbox auto|on|off` (default `auto`):

- **Probe ≠ session-attach.** Doctor strong-sandbox / API-presence reports are capability evidence only. Doctor never reports a live session as `active` from a probe alone.
- **Session-attach** is claimable only after apply-before-exec child attach succeeds for that run (with a profile hash). The pre-exec status handshake (`status_ok`) does not prove `execve`; an `active` session can still fail at exec (e.g. exit 127).
- **FS scope (Seatbelt):** full workspace subpath RW minus control-root carve-outs (create-at-root allowed); Landlock (Linux) keeps workspace-root RO with child RW only.
- **Launch binary grant:** the resolved agent executable (and its realpath target when it is a symlink) is granted as a narrow read+exec **literal** path so tools installed outside the workspace — typical `~/.local/bin` / `~/.local/share/...` installs — can pass child preflight after attach. When the launch file is a shebang script, the shebang interpreter (absolute path, or PATH-resolved name from `#!/usr/bin/env NAME` / `env -S` / flag forms) is granted the same way as a single regular file. Seatbelt uses `literal` (not `subpath`) for `.exec` so a mistaken directory path cannot tree-open. This is **not** a broad `$HOME` grant; sibling home secrets stay denied.
- **`auto`** attaches when the running product major is in the advertised matrix and the sandbox apply symbol resolves; otherwise degrades loudly.
- **`on`** fails closed when attach cannot complete.
- **`off`** disables OS apply.

## Network route forcing

When the proxy backend is active and OS sandbox attach succeeds, Orca renders the child Seatbelt profile without broad `(allow network*)` and permits outbound TCP only to the Orca loopback proxy port. Inbound TCP and bind remain allowed so agents can still start listeners (dev servers, test databases, ephemeral binds); route forcing is outbound connect mediation, not a listener lockdown (same product intent as Landlock connect-only rules). The runtime banner reports `network: proxy route-forced...`, and the child env exports `ORCA_PROXY_ROUTE_FORCED=true` plus `ORCA_TRANSPARENT_NETWORK_ENFORCEMENT=tcp-port-route-forced` (TCP route-force honesty label; Seatbelt still does not claim full XPC/mach isolation).

Proxy startup alone is not enough: without a route-forced OS sandbox session, the child env reports `ORCA_PROXY_ROUTE_FORCED=false`, and `--require-backend network_enforce` fails closed.

**Version gate vs CI evidence:** Seatbelt **capability** remains product majors **14–26** inclusive (version-gated). Outside the matrix → unavailable. **CI attach evidence** is currently collected on **macos-14** only (plus Linux amd64 for Landlock); other matrix majors are local/capability until freeze CI jobs cover them — not silently CI-proven for 14–26. Nested re-apply is not supported; children inherit the first successful apply.

## Protected Paths

Policies deny common secret paths such as `.env`, `~/.ssh/**`, cloud credential directories, keychains, and browser credential stores.

## Limitations

Orca does not install an Endpoint Security extension, kernel extension, or admin-only network filter by default. Seatbelt attach is limited to protected agent child paths under the OS sandbox setting and the version matrix above. Wrapper-level protections alone are not transparent OS enforcement.

## Seatbelt residual (intentional non-goals)

Seatbelt session attach enforces filesystem path scope for the agent child and, when proxy route forcing is requested, child outbound TCP scope to the Orca proxy port. It does **not** provide general process isolation or IPC isolation.

Baseline SBPL intentionally allows (product residual, not a claim of confinement):

| Grant | Role | Residual |
|---|---|---|
| `(allow process*)` / `(allow signal)` | Child lifecycle, exec, signals | Not process isolation between agent and host |
| `(allow mach-lookup)` | dyld / system mach services (unfiltered) | Unrestricted mach service lookup; not a service allowlist |
| `(allow network*)` | Agent network use when route forcing is not requested | Network is unconstrained by the FS-only profile |

When route forcing is requested, the broad network grant is omitted and replaced with: unrestricted `(allow network-inbound)` / `(allow network-bind)`, plus a single `network-outbound` TCP rule for the local proxy port.

**FS claims that remain accurate** when session-attach succeeds: workspace RW (minus control-root write carve-outs), system RO prefixes, no broad `$HOME` grant, and deny of the `/System/Volumes/Data` firmlink home surface (with workspace grants emitted as `/Users/…` form so Seatbelt path filters match live).

Do not treat Seatbelt attach as process confinement, XPC/mach isolation, or credential isolation.
