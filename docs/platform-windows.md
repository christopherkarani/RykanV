# Windows Platform

Run:

```powershell
.\ryk.exe doctor
```

## Capability Matrix

| Feature | Status |
|---|---|
| Process supervision/cleanup | partial unless doctor reports active |
| Env filtering | active |
| Staged writes | active |
| PATH shims | wrapper-only |
| cmd and PowerShell wrappers | partial |
| MCP stdio proxy | active |
| Network decision engine | active |
| Transparent network enforcement | unavailable; wrapper/proxy-mediated only, routes not forced |
| Transparent file enforcement | limited |
| Strong sandbox | unavailable unless doctor reports otherwise |

## Path Normalization

Policy matching handles Windows drive, UNC, backslash, and case-normalization edges where implemented. Validate policies on Windows before relying on them in CI.

## Protected Paths

Use policy deny rules for `.env`, SSH keys, cloud credentials, browser credential stores, and project metadata directories.

## Limitations

Batch forwarding is not treated as a strong security boundary. Use ryk-managed sessions and check `doctor` for actual backend status.
