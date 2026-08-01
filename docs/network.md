# Network

Orca includes a network decision engine and wrapper/proxy-mediated hooks.

## Modes

- `off`: deny network decisions.
- `allowlist`: allow only configured destinations.
- `ask`: ask interactively where supported.
- `observe`: log decisions.
- `open`: allow decisions (and, for host aliases, **unrestricted OS egress**).

```sh
./zig-out/bin/ryk claude
./zig-out/bin/ryk codex
./zig-out/bin/ryk run --network allowlist --allow-network api.github.com -- <custom-command>
```

## Agent host defaults (Phase 1 honesty)

Host aliases (`ryk pi`, `ryk claude`, `ryk codex`, `ryk opencode`, `ryk openclaw`, `ryk hermes`) default to **mediated** network:

1. Policy mode **allowlist** (when `--network` is omitted)
2. Network **backend = proxy**
3. OS sandbox **route-force** (child outbound TCP only to the loopback proxy port)
4. If proxy bind or route-force cannot start → **fail closed** (session does not start)

Escape hatch (loud stderr + audit `network unrestricted; escape used`):

```sh
# Pass run flags before the host — aliases do not peel flags after the host name.
ryk run --network open -- pi
# or: ryk run --network open -- claude
```

One-release kill switch to restore pre-change agent net defaults (labels without forced mediation):

```sh
ORCA_AGENT_NETWORK_DEFAULT=legacy ryk pi
```

Custom `ryk run -- <command>` is **unchanged**: network mode still defaults to `ask`, backend stays policy/`decision_only` unless you pass `--network-backend proxy`. No silent lockdown on non-alias run.

**Honesty rule:** host aliases must not advertise `ORCA_NETWORK_MODE=ask|allowlist` plus a populated allowlist while `ORCA_BACKEND_NETWORK_ENFORCEMENT=unavailable` without either mediation (route-forced) or an explicit open/legacy escape.

## Policy

```yaml
network:
  mode: allowlist
  backend: proxy
  default: deny
  allow:
    - "api.github.com"
  ask:
    - "*.githubusercontent.com"
  deny:
    - "pastebin.com"
    - "*.ngrok.io"
    - "*.requestbin.net"
  detect_exfiltration:
    dns: true
    long_query_strings: true
    secret_patterns: true
```

Service-aware policy is additive to the flat host lists. Use it when a service needs method and path scope plus a credential reference name:

```yaml
services:
  github:
    hosts:
      - "api.github.com"
    methods:
      - "GET"
      - "POST"
    paths:
      allow:
        - "/repos/*/issues"
        - "/repos/*/pulls"
      deny:
        - "/user/keys"
        - "/orgs/*/secrets/*"
    credentials:
      use: github_pat
    unmatched: deny
```

The `credentials.use` value is a reference name for policy, audit, and external broker adapters. Orca does not store or inject the raw secret.

## Proxy Backend

`network.backend: proxy` starts an explicit loopback proxy for protected agent launches (`ryk <agent>` — default) and the advanced run engine. `ryk run --network-backend proxy` is still available for custom commands. The proxy path injects `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`, `ORCA_NETWORK_ENFORCEMENT=proxy-mediated`, and `ORCA_PROXY_ROUTE_FORCED`.

- HTTP requests are evaluated with host, port, method, and path visibility.
- HTTPS `CONNECT` requests are evaluated by host and port only.
- Proxy request attempts and allow/deny decisions are persisted as `network_connect_*` audit/replay events.
- The proxy accepts concurrent client connections and uses full-duplex forwarding after the first request bytes, which supports delayed request bodies, streaming bodies, and chunked-style uploads at the proxy layer.
- If proxy enforcement is required and the proxy fails while the child is running, Orca terminates the child and records a fail-closed proxy stop event.
- Orca does not perform HTTPS MITM.
- Proxy startup alone is not route forcing. `ORCA_PROXY_ROUTE_FORCED=false` means the child received proxy env only.
- With `network.backend: proxy` plus OS sandbox attach, Orca installs child OS network rules where supported and exports `ORCA_PROXY_ROUTE_FORCED=true`. Scope differs by mechanism:
  - **macOS Seatbelt:** outbound TCP only to the Orca **loopback** proxy port (`localhost:port` SBPL). Under default `--seatbelt-profile hardened` (and `compatible`), inbound/bind remain open (Landlock connect-only parity). Under `strict`, inbound/bind are denied. Residual mach-lookup / XPC isolation is still out of scope (see `docs/platform-macos.md` Seatbelt residual).
  - **Linux Landlock (ABI >= 4):** TCP **port-scoped only** (any remote IP on the proxy port; not address-scoped). **UDP/QUIC unrestricted.** Do **not** describe Landlock route force as loopback-only.
- Host aliases **require** route-force when mediation is on: `apply` fails closed if route-force cannot start (including sandbox `off` / soft-degrade), and `ryk run` refuses spawn when mediation is requested but `network_route_forced` is still false.
- `--require-backend network-proxy` is satisfied only when the explicit proxy backend starts successfully. `--require-backend network_enforce` is satisfied only by a route-forced OS sandbox session, not by proxy startup alone.

### Residuals (not claimed locked)

- **UDP / QUIC / WebRTC** are not day-one route-forced on either platform (Landlock leaves UDP unrestricted; Seatbelt proxy-port rules are TCP-oriented).
- Pre-existing connections outside the child process are out of scope.
- Tools that ignore `HTTP(S)_PROXY` still cannot dial arbitrary TCP hosts when route-force is active; absolute `/usr/bin/curl` is covered by OS rules, not shim theater.

## Exfiltration Heuristics

Orca flags long query strings, base64-like URL parts, high-entropy DNS labels, paste sites, request bins, tunneling services, direct IP destinations, secret-like values, and repeated unknown domains.

## Enforcement Levels

Policy decision is not the same as transparent network enforcement. `orca doctor` distinguishes decision engine, observation, proxy-mediated enforcement, and transparent enforcement.

## Redaction

URLs are redacted before audit persistence when they contain secret-like material.
