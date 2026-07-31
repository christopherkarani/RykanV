# Security Policy

## Supported Versions

The v1.1.x line receives security fixes once a v1.1.0 tag is published. Do not treat older pre-release snapshots as supported security releases.

## Reporting a Vulnerability

Report suspected vulnerabilities privately to the project owner. Include the affected version or commit, operating system, reproduction steps, and any generated ryk audit directory if it contains only synthetic data.

Do not include real credentials, API keys, access tokens, private keys, customer data, or proprietary logs. Replace secrets with synthetic values such as `sk-fakeSyntheticOpenAIKey1234567890`.

## Safe Handling

ryk security reports are handled as private by default. The project will avoid publishing exploit details until a fix or documented limitation is available. If the issue is a design limitation rather than a bug, the fix may be documentation, capability reporting, or a failing red-team fixture.

## Current Security Scope

ryk protects local agent runs that go through ryk-managed wrappers, shims, staging, policy checks, audit logging, and the stdio MCP proxy. It reduces blast radius and improves reviewability.

ryk does not make arbitrary malicious code safe. It does not claim universal transparent filesystem or network enforcement on every operating system. Use `ryk doctor` for actual local capability status.

## Security Regression Commands

Run:

```sh
zig build
zig build test
zig build fuzz
./zig-out/bin/ryk redteam --ci
./zig-out/bin/ryk doctor
```

Raw secrets must not appear in `events.jsonl`, `summary.json`, `summary.md`, replay output, red-team output, doctor output, generated policies, or release/install files.
