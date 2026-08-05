# Sandbox stress regression pack

Safe, non-exploit probes for Phases 1–4 host-alias mediation after sandbox changes.

```sh
./scripts/zig build
./scripts/sandbox-stress-regression.sh
./scripts/sandbox-stress-regression.sh --binary ./zig-out/bin/ryk --skip-open-escape
```

| Exit | Meaning |
|------|---------|
| 0 | All applicable probes passed, or clean **SKIP** (no OS attach) |
| 1 | Unexpected allow / suite failure |
| 2 | Usage error |

Probes: curl example.com deny, raw TCP deny, `.git`/`.ryk` write deny, workspace write allow, ssh home list deny, `RYK_SESSION_SANDBOX_GRADE` / PATH labels, optional `--network open` escape grade.

Missing tools: if `curl` or `python3` is not on PATH, the matching network probe **SKIP**s (exit 0 overall) instead of counting a missing binary as a mediation deny pass.

Not a substitute for `ryk redteam --ci` fixture engine.
