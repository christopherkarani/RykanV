# Leaky Agent Demo

This deterministic demo shows how ryk handles a prompt-injection-shaped local workflow without using a real LLM, real secrets, or the external network.

## Scenario

The local project contains a malicious README that tells an agent to read `.env`. The fake agent requests:

1. A shell-mediated `.env` read.
2. A network-like exfiltration command to a synthetic domain.

ryk runs those requested actions through protected sessions, blocks them before they execute, records audit events, and lets replay verify the last session. The demo intentionally does not claim transparent filesystem interception for arbitrary child process file IO.

## Run

From the repository root:

```sh
zig build
cd examples/leaky-agent-demo
./run-demo.sh
../../zig-out/bin/ryk replay --session last --verify
```

PowerShell users can run:

```powershell
.\run-demo.ps1
```

## Expected Result

- No LLM is required.
- No API key is required.
- No external network is required.
- The fake secret is created only inside a temporary demo workspace.
- The fake secret value must not appear in terminal output, `events.jsonl`, `summary.json`, `summary.md`, or replay output.

The script prints the temporary workspace path and the ryk session id so the run can be used for terminal recordings.
