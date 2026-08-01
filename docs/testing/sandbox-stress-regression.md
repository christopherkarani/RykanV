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

Probes: curl example.com deny, raw TCP deny, `.git`/`.orca` write deny, workspace write allow, ssh home list deny, `ORCA_SESSION_SANDBOX_GRADE` / PATH labels, optional `--network open` escape grade.

Not a substitute for `ryk redteam --ci` fixture engine.
