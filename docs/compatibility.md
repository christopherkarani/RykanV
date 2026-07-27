# Compatibility Matrix

Use `orca doctor` for the authoritative report on a specific machine. This matrix uses Orca capability vocabulary: `active`, `partial`, `wrapper-only`, `observe-only`, `limited`, `unavailable`, and `unsupported`.

## Protection grades (canonical)

Orca is **graded mediation**, not a universal OS sandbox. Public product language uses these grades:

| Grade | Meaning | Typical Orca surface |
| --- | --- | --- |
| `hook` | Host invokes Orca and honors veto | Native plugin / host hook that actually fires |
| `wrapper` | Public host launch aliases (`orca <agent>`) / PATH shims / advanced run engine mediation | Finite executable list; absolute paths may bypass |
| `proxy` | Traffic must traverse an Orca proxy | MCP / optional network proxies |
| `OS-enforced` | Kernel/sandbox backend actually enforcing for that session | Only after child session-attach succeeds; doctor probes alone are not enough |

**Default public launch posture (`orca <agent>`):** typically **`wrapper`**, plus optional OS filesystem session-attach through the run engine. Host **`hook`** applies only when hooks fire and honor veto. **`proxy`** applies only to traffic that traverses an Orca proxy. **`OS-enforced`** FS isolation requires a successful Landlock (Linux) or Seatbelt (macOS) attach for that child — not a doctor capability probe.

**What can still bypass `wrapper` mediation:** absolute-path binaries outside the shim list, non-shimmed tools, agents started outside `orca <agent>` / advanced run / hooks, non-proxy HTTP clients, non-firing host hooks, and direct syscalls.

### Vocabulary map

Doctor / platform reports are **not** a second taxonomy. Map them to grades:

| Other surface | Maps to grade(s) | Notes |
| --- | --- | --- |
| doctor `wrapper-only` (command guard / PATH shims) | `wrapper` | Not transparent OS enforcement |
| doctor sandbox / strong sandbox `partial` (API present) | probe only | Capability evidence; **not** a live session claim |
| doctor sandbox / transparent FS or network `active` | `OS-enforced` | Rare; doctor never marks session active from probe alone |
| Protected agent launch + successful child attach | `OS-enforced` (FS, that session) | `orca <agent>` uses the run engine; advanced `orca run --os-sandbox` exposes explicit attach flags. Landlock ABI ≥ 1 (kernel 5.13+) or Seatbelt majors 14–26 (capability gate; CI attach evidence: linux amd64 + macos-14) |
| doctor `observe-only` / `limited` / `unavailable` | no enforcement claim | Decision or partial path only |
| MCP stdio proxy `active` | `proxy` (MCP path) | Only for mediated MCP traffic |
| `orca start` default (**Ask on risk**) | multi-grade aspirational (`hook` + `wrapper` when available) | Public path has no `--protection` flag; wires host hooks + policy; not `OS-enforced` from doctor probes alone |
| Host hooks that fire and honor veto | primarily `hook` (+ daemon for shell eval) | Depends on host install path; hooks alone are not process wrap |
| Host aliases / advanced run engine / PATH shims | primarily `wrapper` | Not kernel firewall; absolute paths may bypass |

Reserve marketing “firewall” / “maximum protection” for a **verified** multi-grade or **`OS-enforced`** posture. See also [threat-model.md](threat-model.md).

---

## Platform feature matrix

| Feature | Linux | macOS | Windows |
|---|---|---|---|
| Launch arbitrary command | active | active | active |
| Env filtering | active | active | active |
| Secret redaction | active | active | active |
| Audit/replay | active | active | active |
| Staged writes | active | active | active |
| Command guard | wrapper-only | wrapper-only | wrapper-only |
| Shell/PATH shims | wrapper-only | wrapper-only | wrapper-only |
| MCP stdio proxy | active | active | active |
| MCP manifests | active | active | active |
| MCP sampling controls | active | active | active |
| Network decision engine | active | active | active |
| Proxy-mediated network enforcement | limited; explicit loopback proxy when requested; route forcing when OS sandbox supports it | limited; explicit loopback proxy when requested; route forcing when OS sandbox supports it | limited; explicit loopback proxy when requested, routes not forced |
| Transparent network enforcement | per-session Landlock TCP route forcing with ABI >= 4; otherwise observe-only | per-session Seatbelt TCP route forcing with proxy backend + OS sandbox; otherwise unavailable | unavailable; wrapper/proxy-mediated only, routes not forced |
| Transparent filesystem enforcement | staged writes; Landlock attach when available | limited; Seatbelt attach when available | limited |
| Strong sandbox (session-attach) | Landlock when ABI ≥ 1 (kernel 5.13+); else unavailable | Seatbelt capability majors 14–26; else unavailable | unavailable |
| Advanced `--os-sandbox` flag | auto \| on \| off (default auto) | auto \| on \| off (default auto) | off / unavailable |
| Advanced `--seatbelt-profile` / `ORCA_SEATBELT_PROFILE` | n/a (Landlock) | compatible \| hardened \| strict (default **hardened**) | n/a |
| Process cleanup | active or partial | active | partial |
| Red-team suite | active | active | active |

`wrapper-only` means Orca-mediated command paths are protected by shims or wrappers (grade **`wrapper`**). It is not transparent OS enforcement.

**Probe vs session-attach:** Doctor and platform matrices may report sandbox **capability** (`partial` / API present). That is not a live session `active` claim. Trust **`OS-enforced`** filesystem isolation only for a protected agent session that completed child apply-before-exec attach (profile hash present). Use advanced `orca run --os-sandbox on` to fail closed when attach cannot complete.

**Capability matrix vs CI attach evidence:** Landlock/Seatbelt version gates (Linux ABI ≥ 1; macOS product majors 14–26) describe **where attach may run**. Continuous **CI attach evidence** today is **linux amd64** and **macos-14** only; other OS/arch/major cells are local until freeze jobs exist — do not treat every gated major as CI-proven.
