# Linux Platform

Run:

```sh
./zig-out/bin/orca doctor
```

## Capability Matrix

| Feature | Status |
|---|---|
| Process supervision | active or partial, host-dependent |
| Env filtering | active |
| Staged writes | active |
| Shell/PATH shims | wrapper-only |
| MCP stdio proxy | active |
| Network decision engine | active |
| Transparent network enforcement | per-session when proxy backend + Landlock ABI >= 4 route-forces TCP; otherwise observe-only |
| Transparent filesystem enforcement | staged writes always; Landlock session-attach when available |
| Strong sandbox | session-attach via Landlock when ABI ≥ 1 (kernel 5.13+); otherwise unavailable |

## OS filesystem sandbox

Protected agent launches (`orca <agent>`) use the run engine and can attach a Landlock filesystem boundary to the agent child. Advanced users can force the same path with `orca run --os-sandbox auto|on|off` (default `auto`):

- **Probe ≠ session-attach.** Doctor Landlock / strong-sandbox reports are capability evidence only. Doctor never reports a live session as `active` from a probe alone.
- **Session-attach** is claimable only after apply-before-exec child attach succeeds for that run (with a profile hash). The pre-exec status handshake (`status_ok`) does not prove `execve`; an `active` session can still fail at exec (e.g. exit 127).
- **FS scope (Landlock):** workspace child RW with workspace-root RO — create/write at the workspace root is denied; Seatbelt (macOS) allows full workspace subpath RW including create-at-root.
- **Launch binary grant:** the resolved agent executable (and realpath target when a symlink), plus the launch file’s shebang interpreter when present, are granted as narrow read+exec **files** so installs outside the workspace (e.g. `~/.local/bin`) can pass child preflight/exec after attach. This is **not** a broad `$HOME` grant.
- **`auto`** attaches when the host supports Landlock ABI ≥ 1 and degrades loudly when it does not.
- **`on`** fails closed when attach cannot complete.
- **`off`** disables OS apply.

Requirements: Linux kernel **5.13+** with Landlock **ABI ≥ 1**. Containers and host policy can still make Landlock unavailable.

## Network route forcing

When the proxy backend is active and Landlock ABI **>= 4** is available, Orca adds Landlock TCP network rules to the same child `restrict_self` call as the filesystem profile. The child env exports `ORCA_PROXY_ROUTE_FORCED=true` and `ORCA_TRANSPARENT_NETWORK_ENFORCEMENT=tcp-port-route-forced` (TCP port-scoped residual; not unqualified transparent-active).

**Honest Landlock network residual (do not describe as loopback-only):**

| Claim | Landlock reality |
|---|---|
| TCP connect | **Port-scoped only** — allowed TCP connects to the proxy **port** from the child, to **any remote IP** on that port (not address-scoped to 127.0.0.1) |
| Other TCP ports | Denied (ordinary proxy-bypass to :80/:443 etc.) |
| TCP bind / listen | **Unrestricted** — `handled_access_net` is CONNECT-only so agents can still bind dev servers; route forcing does not claim inbound TCP control |
| UDP / QUIC | **Unrestricted** under Landlock route force — no Landlock UDP net rules |
| vs macOS Seatbelt | Seatbelt can express localhost:port outbound TCP; Landlock cannot |

This blocks ordinary proxy-ignoring TCP clients that dial normal ports, but it is **not** "outbound TCP to Orca loopback proxy only." Linux matrix evidence must include the Landlock route-forcing canary and keep this residual visible.

## Backend Features

Doctor may report user namespaces, mount namespaces, seccomp, Landlock, cgroups, network observation, audit/replay, and strong sandbox capability. Kernel feature probes are not a live session claim. Landlock restrictions are installed only on protected agent child paths when OS sandbox attach is enabled and the host supports it.

## Fallback

If kernel features are unavailable, Orca falls back to wrapper/proxy, staged-write, policy, and audit controls. Required backend features fail closed when requested with `--require-backend` or `--os-sandbox on`.

## Limitations

Linux capability varies by distro, kernel, container, and sysctl configuration. Do not treat doctor probes as transparent filesystem enforcement for an arbitrary process; trust OS-enforced FS isolation only for sessions that completed child attach.

## Hardlink residual

Landlock grant expansion skips symlinks (`DT_LNK`) and install opens use `O_NOFOLLOW`. Non-directory expand leaves with `st_nlink > 1` are also skipped so a pre-planted hardlink to an outside same-FS inode does not become an RW `PATH_BENEATH` surface. Directories are never skipped on nlink (normal dir nlink ≥ 2).

**Residual after the nlink filter:** hardlinks created *after* plan build (Landlock is path-based; the expand snapshot does not re-check nlink at install), plus expand-plan → child-open path TOCTOU (workspace write between parent plan and child `O_PATH` open can still replace a grant leaf). Legitimate multi-linked files under the workspace also lose leaf RW (write via another single-link name, or parent dir grant when expand does not apply).
