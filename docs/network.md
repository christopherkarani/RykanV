# Network

Orca includes a network decision engine and wrapper/proxy-mediated hooks.

## Modes

- `off`: deny network decisions.
- `allowlist`: allow only configured destinations.
- `ask`: ask interactively where supported.
- `observe`: log decisions.
- `open`: allow decisions.

```sh
./zig-out/bin/orca claude
./zig-out/bin/orca codex
./zig-out/bin/orca run --network allowlist --allow-network api.github.com -- <custom-command>
```

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

`network.backend: proxy` starts an explicit loopback proxy for protected agent launches (`orca <agent>`) and the advanced run engine. `orca run --network-backend proxy` is still available for custom commands. The proxy path injects `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`, `ORCA_NETWORK_ENFORCEMENT=proxy-mediated`, and `ORCA_PROXY_ROUTE_FORCED`.

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
- `--require-backend network-proxy` is satisfied only when the explicit proxy backend starts successfully. `--require-backend network_enforce` is satisfied only by a route-forced OS sandbox session, not by proxy startup alone.

## Exfiltration Heuristics

Orca flags long query strings, base64-like URL parts, high-entropy DNS labels, paste sites, request bins, tunneling services, direct IP destinations, secret-like values, and repeated unknown domains.

## Enforcement Levels

Policy decision is not the same as transparent network enforcement. `orca doctor` distinguishes decision engine, observation, proxy-mediated enforcement, and transparent enforcement.

## Redaction

URLs are redacted before audit persistence when they contain secret-like material.
